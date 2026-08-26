@echo off
chcp 65001 >nul
echo ========================================
echo   VIDEO DOWNLOADER - BACKEND LOCAL
echo ========================================
echo.

cd /d "%~dp0"

if not exist venv (
    echo [1/4] Criando ambiente virtual...
    python -m venv venv || goto :error
)

echo [2/4] Ativando ambiente virtual...
call venv\Scripts\activate.bat

echo [3/4] Instalando dependencias...
pip install -r requirements.txt || goto :error

echo.
echo [4/4] Iniciando servidor FastAPI...
echo.
echo    Acesse:  http://localhost:8000
echo    Swagger: http://localhost:8000/docs
echo.
echo    Para emulador Android use: http://10.0.2.2:8000
echo    Para dispositivo fisico use IP da rede: http://SEU-IP:8000
echo.
echo    Pressione CTRL+C para parar
echo ========================================

uvicorn main:app --reload --host 0.0.0.0 --port 8000

goto :eof

:error
echo.
echo [ERRO] Ocorreu um problema durante a inicializacao!
echo Verifique se Python esta instalado: python --version
echo Verifique se FFmpeg esta no PATH: ffmpeg -version
pause
exit /b 1
