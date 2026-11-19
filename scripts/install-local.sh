#!/usr/bin/env bash
# Build Marka.app from this checkout and install it into /Applications (or
# ~/Applications if /Applications is not writable). Replaces a running copy.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Marka"
SRC_APP="$ROOT_DIR/build/${APP_NAME}.app"

if [[ "${MARKA_PER_USER:-0}" == "1" ]] || [[ ! -w "/Applications" ]]; then
    mkdir -p "$HOME/Applications"
    DEST_DIR="$HOME/Applications"
else
    DEST_DIR="/Applications"
fi
DEST_APP="${DEST_DIR}/${APP_NAME}.app"

"$ROOT_DIR/scripts/build-app.sh" "${1:-release}"

xattr -cr "$SRC_APP" 2>/dev/null || true
codesign --verify --deep --strict "$SRC_APP"

echo "==> Installing to ${DEST_APP}…"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3
rm -rf "$DEST_APP"
ditto "$SRC_APP" "$DEST_APP"
xattr -cr "$DEST_APP" 2>/dev/null || true

echo "==> Launching ${APP_NAME}…"
open "$DEST_APP"
echo "✅ ${APP_NAME} installed at ${DEST_APP}"
