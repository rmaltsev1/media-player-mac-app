#!/usr/bin/env bash
# Freeze the Python sidecar into a self-contained onedir bundle with PyInstaller.
# Output: sidecar/dist/rezka-sidecar/  (rezka-sidecar executable + _internal/)
set -euo pipefail

cd "$(dirname "$0")/../sidecar"

if [ ! -x .venv/bin/python3 ]; then
  echo "==> creating venv"
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

echo "==> installing deps + pyinstaller"
pip install -q -r requirements.txt
pip install -q pyinstaller

echo "==> freezing sidecar (onedir)"
rm -rf build dist ./*.spec
pyinstaller --onedir --name rezka-sidecar --paths . \
  --hidden-import socks --hidden-import urllib3.contrib.socks \
  --collect-submodules hdrezka \
  --noconfirm server.py >/dev/null

echo "==> frozen: $(pwd)/dist/rezka-sidecar/rezka-sidecar"
