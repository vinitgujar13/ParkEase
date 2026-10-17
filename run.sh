#!/bin/bash
# ============================================================
# ParkEase - Vehicle Parking Management System
# Startup Script
# ============================================================

set -e

echo "=============================================="
echo "  ParkEase - Vehicle Parking Management"
echo "=============================================="

# Load .env if present
if [ -f .env ]; then
    echo "[*] Loading environment from .env"
    export $(grep -v '^#' .env | xargs)
fi

# Default values
HOST=${APP_HOST:-0.0.0.0}
PORT=${APP_PORT:-8000}
RELOAD=${APP_DEBUG:-true}

# Check Python virtual environment
if [ ! -d "venv" ]; then
    echo "[*] Creating virtual environment..."
    python3 -m venv venv
fi

echo "[*] Activating virtual environment..."
source venv/bin/activate

echo "[*] Installing/checking dependencies..."
pip install -r requirements.txt -q

echo ""
echo "Starting FastAPI server..."
echo "  Host:           http://${HOST}:${PORT}"
echo "  Super Admin:    admin@parking.local / Admin@123"
echo "  Facility Owner: owner1@parking.com / Owner@123"
echo "  Customer:       demo@parking.local / Customer@123"
echo ""

if [ "$RELOAD" = "true" ]; then
    uvicorn app.main:app --host "$HOST" --port "$PORT" --reload
else
    uvicorn app.main:app --host "$HOST" --port "$PORT"
fi
