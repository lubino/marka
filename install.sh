#!/usr/bin/env bash
set -euo pipefail

REPO="lubino/marka"
APP_NAME="Marka"
RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"
ZIP_NAME="Marka-macos.zip"
SUMS_NAME="SHA256SUMS.txt"

MODE="release"
PURGE_CONFIG="0"

for arg in "$@"; do
    case "$arg" in
        --uninstall)
            MODE="uninstall"
            ;;
        --purge)
            PURGE_CONFIG="1"
            ;;
        --from-source)
            MODE="source"
            ;;
        -h|--help)
            cat <<EOF
Marka installer for macOS

Usage:
  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s -- --from-source
  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s -- --uninstall
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: Marka requires macOS 14 (Sonoma) or newer." >&2
    exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$MACOS_MAJOR" -lt 14 ]]; then
    echo "Error: macOS 14+ is required (detected $(sw_vers -productVersion))." >&2
    exit 1
fi

resolve_install_dir() {
    if [[ "${MARKA_PER_USER:-0}" == "1" ]] || [[ ! -w "/Applications" ]]; then
        mkdir -p "$HOME/Applications"
        echo "$HOME/Applications"
    else
        echo "/Applications"
    fi
}

if [[ "$MODE" == "uninstall" ]]; then
    echo "==> Stopping ${APP_NAME}…"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app" "$HOME/Applications/${APP_NAME}.app"
    if [[ "$PURGE_CONFIG" == "1" ]]; then
        defaults delete sk.lubino.marka 2>/dev/null || true
        echo "==> Removed ${APP_NAME}.app and preferences."
    else
        echo "==> Removed ${APP_NAME}.app."
    fi
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

install_bundle() {
    local src_app="$1"
    local dest_dir
    dest_dir="$(resolve_install_dir)"
    local dest_app="${dest_dir}/${APP_NAME}.app"

    xattr -cr "$src_app" 2>/dev/null || true
    codesign --verify --deep --strict "$src_app"

    echo "==> Installing to ${dest_app}…"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.3
    rm -rf "$dest_app"
    ditto "$src_app" "$dest_app"
    xattr -cr "$dest_app" 2>/dev/null || true

    echo "==> Launching ${APP_NAME}…"
    open "$dest_app"
    echo "✅ ${APP_NAME} is installed at ${dest_app}."
}

build_from_source() {
    if ! command -v swift >/dev/null 2>&1; then
        echo "Error: Swift toolchain not found. Install Command Line Tools with: xcode-select --install" >&2
        exit 1
    fi
    echo "==> Building ${APP_NAME} from source…"
    git clone --depth 1 "https://github.com/${REPO}.git" "$WORK_DIR/src"
    (
        cd "$WORK_DIR/src"
        ./scripts/build-app.sh release
    )
    install_bundle "$WORK_DIR/src/build/${APP_NAME}.app"
}

if [[ "$MODE" == "source" ]]; then
    build_from_source
    exit 0
fi

echo "==> Downloading latest ${APP_NAME} release from GitHub…"
if curl -fsSL "${RELEASE_BASE}/${ZIP_NAME}" -o "$WORK_DIR/${ZIP_NAME}" \
   && curl -fsSL "${RELEASE_BASE}/${SUMS_NAME}" -o "$WORK_DIR/${SUMS_NAME}"; then
    echo "==> Verifying SHA-256 checksum…"
    EXPECTED_SHA="$(awk -v f="$ZIP_NAME" '$2 == f { print $1 }' "$WORK_DIR/${SUMS_NAME}")"
    ACTUAL_SHA="$(shasum -a 256 "$WORK_DIR/${ZIP_NAME}" | awk '{ print $1 }')"

    if [[ -z "$EXPECTED_SHA" ]] || [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
        echo "Error: SHA-256 checksum mismatch! Expected ${EXPECTED_SHA:-<missing>}, got ${ACTUAL_SHA}." >&2
        exit 1
    fi

    ditto -x -k "$WORK_DIR/${ZIP_NAME}" "$WORK_DIR/unpacked"
    install_bundle "$WORK_DIR/unpacked/${APP_NAME}.app"
else
    echo "==> Prebuilt release archive not available yet; falling back to local source build…"
    build_from_source
fi
