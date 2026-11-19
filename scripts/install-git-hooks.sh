#!/usr/bin/env bash
# Point this clone at committed hooks in .githooks (version-tag push → local GitHub Release).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$ROOT_DIR" config core.hooksPath .githooks
chmod +x "$ROOT_DIR/.githooks/"* "$ROOT_DIR/scripts/publish-release.sh"
echo "Installed git hooksPath=$ROOT_DIR/.githooks"
