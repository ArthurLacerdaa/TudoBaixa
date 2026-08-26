#!/bin/bash
set -e
echo "========================================"
echo "  VIDEO DOWNLOADER - BACKEND LOCAL"
echo "========================================"
echo ""

cd "$(dirname "$0")"

if [ ! -d venv ]; then
    echo "[1/4] Creating virtual environment..."
    python3 -m venv venv
fi

echo "[2/4] Activating virtual environment..."
source venv/bin/activate

echo "[3/4] Installing dependencies..."
pip install -r requirements.txt

echo ""
echo "[4/4] Starting FastAPI server..."
echo ""
echo "   Access:  http://localhost:8000"
echo "   Swagger: http://localhost:8000/docs"
echo ""
echo "   Android Emulator:  http://10.0.2.2:8000"
echo "   Real device:       http://YOUR-IP:8000"
echo ""
echo "   Press CTRL+C to stop"
echo "========================================"

uvicorn main:app --reload --host 0.0.0.0 --port 8000
