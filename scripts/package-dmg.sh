#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

UNIVERSAL="${UNIVERSAL:-1}" "$ROOT_DIR/scripts/build-app.sh" release

OUT_DIR="$ROOT_DIR/build"
APP_BUNDLE="$OUT_DIR/Marka.app"
ZIP_PATH="$OUT_DIR/Marka-macos.zip"
DMG_PATH="$OUT_DIR/Marka.dmg"
SUMS_PATH="$OUT_DIR/SHA256SUMS.txt"

rm -f "$ZIP_PATH" "$DMG_PATH" "$SUMS_PATH"

echo "==> Creating archive ${ZIP_PATH}…"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Creating disk image ${DMG_PATH}…"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

ditto "$APP_BUNDLE" "$STAGE_DIR/Marka.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "Marka" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

echo "==> Generating SHA-256 checksums…"
(
    cd "$OUT_DIR"
    shasum -a 256 "Marka.dmg" "Marka-macos.zip" > "SHA256SUMS.txt"
)

cat "$SUMS_PATH"
echo "==> Release artifacts ready in ${OUT_DIR}:"
echo "    - ${DMG_PATH}"
echo "    - ${ZIP_PATH}"
echo "    - ${SUMS_PATH}"
