import os
import tempfile
import asyncio
import uuid
import shutil
import re
from typing import Dict, List, Optional
from datetime import datetime, timedelta
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import yt_dlp


TEMP_DIR = tempfile.mkdtemp(prefix="video_downloader_")
MAX_CONCURRENT_DOWNLOADS = 2
DOWNLOAD_TIMEOUT = 600
FILE_EXPIRY_HOURS = 2
BACKEND_DIR = Path(__file__).resolve().parent
LOCAL_COOKIE_FILE = BACKEND_DIR / "cookies.txt"
RENDER_COOKIE_FILE = Path("/etc/secrets/cookies.txt")
DEFAULT_COOKIE_FILE = RENDER_COOKIE_FILE if RENDER_COOKIE_FILE.is_file() else LOCAL_COOKIE_FILE
COOKIE_FILE = Path(os.getenv("YTDLP_COOKIES_FILE", str(DEFAULT_COOKIE_FILE)))
WRITABLE_COOKIE_FILE = Path(TEMP_DIR) / "cookies.txt"

download_tasks: Dict[str, dict] = {}
download_semaphore = asyncio.Semaphore(MAX_CONCURRENT_DOWNLOADS)


class DownloadRequest(BaseModel):
    url: str


class MultiDownloadRequest(BaseModel):
    text: str


class DownloadStatus(BaseModel):
    task_id: str
    status: str
    progress: float
    filename: Optional[str] = None
    error: Optional[str] = None
    url: str
    created_at: str


def extract_urls(text: str) -> List[str]:
    url_pattern = re.compile(
        r'https?://[^\s<>"\'()]+|www\.[^\s<>"\'()]+',
        re.IGNORECASE
    )
    urls = url_pattern.findall(text)
    normalized = []
    for url in urls:
        if url.startswith("www."):
            url = "https://" + url
        normalized.append(url.rstrip(".,;:!?)("))
    seen = set()
    unique = []
    for url in normalized:
        if url not in seen:
            seen.add(url)
            unique.append(url)
    return unique


def _is_facebook_short_url(url: str) -> bool:
    """Return whether *url* is a Facebook URL that needs redirect resolution."""
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    return (
        host == "fb.watch"
        or host == "fb.me"
        or host == "facebook.com"
        or host.endswith(".facebook.com")
    ) and ("/share" in parsed.path or host in {"fb.watch", "fb.me"})


def expand_url(url: str) -> str:
    """Resolve Facebook share URLs before passing them to yt-dlp."""
    if not _is_facebook_short_url(url):
        return url

    try:
        request = Request(url, method="HEAD", headers={"User-Agent": "Mozilla/5.0"})
        with urlopen(request, timeout=10) as response:
            return response.geturl()
    except Exception:
        # Some Facebook endpoints reject HEAD. A small GET still follows redirects.
        try:
            request = Request(
                url,
                headers={"User-Agent": "Mozilla/5.0", "Range": "bytes=0-0"},
            )
            with urlopen(request, timeout=10) as response:
                return response.geturl()
        except Exception:
            return url


def _cookie_file_for_yt_dlp() -> Optional[Path]:
    """Return a writable cookie file for yt-dlp.

    Render mounts secret files under /etc/secrets as read-only. yt-dlp updates
    its cookie jar while extracting metadata, so it must use a temporary copy.
    """
    if not COOKIE_FILE.is_file():
        return None
    if COOKIE_FILE != RENDER_COOKIE_FILE:
        return COOKIE_FILE

    if not WRITABLE_COOKIE_FILE.is_file():
        shutil.copyfile(COOKIE_FILE, WRITABLE_COOKIE_FILE)
        os.chmod(WRITABLE_COOKIE_FILE, 0o600)
    return WRITABLE_COOKIE_FILE


def _requires_auth_cookies(url: str) -> bool:
    """Cookies are only needed for platforms that require an authenticated session."""
    host = (urlparse(url).hostname or "").lower()
    return (
        host == "youtu.be"
        or host == "youtube.com"
        or host.endswith(".youtube.com")
        or host == "instagram.com"
        or host.endswith(".instagram.com")
    )


def add_cookie_file(ydl_opts: dict, url: str) -> dict:
    """Use cookies only for YouTube and Instagram, never for TikTok."""
    if not _requires_auth_cookies(url):
        return ydl_opts
    cookie_file = _cookie_file_for_yt_dlp()
    if cookie_file is not None:
        ydl_opts["cookiefile"] = str(cookie_file)
    return ydl_opts


ANSI_ESCAPE = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

def clean_error_message(msg: str) -> str:
    msg = ANSI_ESCAPE.sub('', msg)
    msg = msg.strip()
    if len(msg) > 500:
        msg = msg[:497] + "..."
    return msg


def cleanup_old_files():
    now = datetime.now()
    cutoff = now - timedelta(hours=FILE_EXPIRY_HOURS)
    if not os.path.exists(TEMP_DIR):
        return
    for filename in os.listdir(TEMP_DIR):
        filepath = os.path.join(TEMP_DIR, filename)
        try:
            if os.path.isfile(filepath):
                mtime = datetime.fromtimestamp(os.path.getmtime(filepath))
                if mtime < cutoff:
                    os.remove(filepath)
        except Exception:
            pass


@asynccontextmanager
async def lifespan(app: FastAPI):
    os.makedirs(TEMP_DIR, exist_ok=True)
    cleanup_task = asyncio.create_task(periodic_cleanup())
    yield
    cleanup_task.cancel()
    try:
        shutil.rmtree(TEMP_DIR, ignore_errors=True)
    except Exception:
        pass


async def periodic_cleanup():
    while True:
        try:
            cleanup_old_files()
        except Exception:
            pass
        await asyncio.sleep(600)


app = FastAPI(
    title="TudoBaixa API",
    description="Backend do TudoBaixa - Download de videos com yt-dlp",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class YtDlpLogger:
    def __init__(self, task_id: str):
        self.task_id = task_id

    def debug(self, msg):
        pass

    def info(self, msg):
        pass

    def warning(self, msg):
        pass

    def error(self, msg):
        task = download_tasks.get(self.task_id)
        if task:
            task["logs"].append(msg)


def progress_hook(d, task_id: str):
    task = download_tasks.get(task_id)
    if not task:
        return
    if d["status"] == "downloading":
        downloaded = d.get("downloaded_bytes", 0)
        total = d.get("total_bytes") or d.get("total_bytes_estimate", 0)
        if total > 0:
            task["progress"] = round((downloaded / total) * 100, 1)
        task["speed"] = d.get("speed")
        task["eta"] = d.get("eta")
    elif d["status"] == "finished":
        task["progress"] = 100.0


async def run_download(task_id: str, url: str):
    async with download_semaphore:
        task = download_tasks.get(task_id)
        if not task:
            return
        task["status"] = "downloading"
        output_template = os.path.join(TEMP_DIR, f"{task_id}_%(title).100B.%(ext)s")
        ydl_opts = add_cookie_file({
            "outtmpl": output_template,
            "format": "bestvideo*+bestaudio/best",
            "merge_output_format": "mp4",
            "logger": YtDlpLogger(task_id),
            "progress_hooks": [lambda d: progress_hook(d, task_id)],
            "quiet": True,
            "no_warnings": True,
            "ignoreerrors": False,
            "noprogress": True,
            "no_color": True,
            "extractor_retries": 2,
            "retries": 2,
        }, url)
        try:
            loop = asyncio.get_event_loop()
            info = await loop.run_in_executor(
                None,
                lambda: _do_download(ydl_opts, url)
            )
            if info.get("filepath"):
                task["filename"] = os.path.basename(info["filepath"])
                task["filepath"] = info["filepath"]
                task["status"] = "completed"
                task["progress"] = 100.0
            else:
                task["status"] = "error"
                task["error"] = clean_error_message("Download concluído mas arquivo não encontrado")
        except Exception as e:
            task["status"] = "error"
            task["error"] = clean_error_message(str(e))


def _do_download(ydl_opts, url):
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=True)
        filepath = ydl.prepare_filename(info)
        if info.get("requested_downloads"):
            fp = info["requested_downloads"][0].get("filepath")
            if fp:
                filepath = fp
        return {"info": info, "filepath": filepath}


def _create_task(url: str) -> str:
    task_id = str(uuid.uuid4())
    download_tasks[task_id] = {
        "task_id": task_id,
        "url": url,
        "status": "queued",
        "progress": 0.0,
        "filename": None,
        "filepath": None,
        "error": None,
        "created_at": datetime.now().isoformat(),
        "logs": [],
    }
    return task_id


@app.get("/")
async def root():
    return {
        "service": "TudoBaixa API",
        "version": "1.0.0",
        "status": "online",
        "temp_dir": TEMP_DIR,
        "active_tasks": len(download_tasks),
    }


@app.post("/api/download")
async def start_download(request: DownloadRequest, background_tasks: BackgroundTasks):
    url = request.url.strip()
    if not url:
        raise HTTPException(status_code=400, detail="URL vazia")
    url = expand_url(url)
    task_id = _create_task(url)
    background_tasks.add_task(run_download, task_id, url)
    return {"task_id": task_id, "status": "queued", "url": url}


@app.post("/api/download/multi")
async def start_multi_download(request: MultiDownloadRequest, background_tasks: BackgroundTasks):
    urls = extract_urls(request.text)
    if not urls:
        raise HTTPException(status_code=400, detail="Nenhuma URL encontrada no texto")
    tasks = []
    for url in urls:
        url = expand_url(url)
        task_id = _create_task(url)
        background_tasks.add_task(run_download, task_id, url)
        tasks.append({"task_id": task_id, "url": url, "status": "queued"})
    return {
        "total": len(tasks),
        "tasks": tasks,
    }


@app.get("/api/status/{task_id}")
async def get_status(task_id: str):
    task = download_tasks.get(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Tarefa não encontrada")
    return {
        "task_id": task["task_id"],
        "status": task["status"],
        "progress": task["progress"],
        "filename": task["filename"],
        "error": task["error"],
        "url": task["url"],
        "created_at": task["created_at"],
    }


@app.get("/api/status")
async def list_statuses():
    result = []
    for task in download_tasks.values():
        result.append({
            "task_id": task["task_id"],
            "status": task["status"],
            "progress": task["progress"],
            "filename": task["filename"],
            "error": task["error"],
            "url": task["url"],
            "created_at": task["created_at"],
        })
    return {"total": len(result), "tasks": result}


@app.get("/api/download/{task_id}/file")
async def download_file(task_id: str):
    task = download_tasks.get(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Tarefa não encontrada")
    if task["status"] != "completed":
        raise HTTPException(status_code=400, detail=f"Download ainda não concluído. Status: {task['status']}")
    filepath = task.get("filepath")
    if not filepath or not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail="Arquivo não encontrado no servidor")
    filename = task.get("filename") or os.path.basename(filepath)
    return FileResponse(
        path=filepath,
        filename=filename,
        media_type="application/octet-stream",
    )


@app.get("/api/health")
async def health():
    return {"status": "healthy", "temp_dir": TEMP_DIR}


@app.post("/api/info")
async def get_video_info(request: DownloadRequest):
    url = request.url.strip()
    if not url:
        raise HTTPException(status_code=400, detail="URL vazia")
    url = expand_url(url)

    info_ydl_opts = add_cookie_file({
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "format": "bestvideo*+bestaudio/best",
        "ignoreerrors": False,
        "no_color": True,
        "extractor_retries": 2,
        "retries": 2,
    }, url)

    try:
        loop = asyncio.get_event_loop()
        info = await loop.run_in_executor(
            None,
            lambda: _extract_info(info_ydl_opts, url)
        )
        return info
    except Exception as e:
        raise HTTPException(
            status_code=400,
            detail=clean_error_message(f"Não foi possível extrair informações: {str(e)}")
        )


def _extract_info(ydl_opts, url):
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)
        formats = info.get("formats", [])

        video_formats = []
        for f in formats:
            if f.get("vcodec") and f["vcodec"] != "none":
                height = f.get("height") or 0
                video_format = {
                    "format_id": f.get("format_id"),
                    "ext": f.get("ext", "mp4"),
                    "resolution": f.get("resolution") or f"{height}p",
                    "height": height,
                    "filesize": f.get("filesize") or f.get("filesize_approx"),
                    "fps": f.get("fps"),
                }
                video_formats.append(video_format)

        video_formats = sorted(video_formats, key=lambda x: x["height"], reverse=True)
        seen = set()
        unique_formats = []
        for vf in video_formats:
            key = (vf["height"], vf["ext"])
            if key not in seen:
                seen.add(key)
                unique_formats.append(vf)

        best_thumbnail = ""
        thumbnails = info.get("thumbnails", [])
        if thumbnails:
            priority = ["0", "1", "2", "3", "4", "maxres", "high", "medium", "default"]
            thumbnails_sorted = sorted(
                thumbnails,
                key=lambda t: priority.index(t.get("id", "")) if t.get("id") in priority else 99,
                reverse=True
            )
            best_thumbnail = thumbnails_sorted[0].get("url", "")

        uploader = info.get("uploader") or info.get("channel") or info.get("author") or ""
        title = info.get("title") or "Vídeo sem título"
        duration = info.get("duration")
        webpage_url = info.get("webpage_url") or info.get("original_url") or url
        platform = info.get("extractor_key") or info.get("extractor") or "Desconhecida"

        total_size = (
            info.get("filesize")
            or info.get("filesize_approx")
        )

        return {
            "title": title,
            "uploader": uploader,
            "duration": duration,
            "thumbnail": best_thumbnail,
            "url": webpage_url,
            "platform": platform,
            "filesize": total_size,
            "formats": unique_formats[:8],
        }
