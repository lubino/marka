#!/usr/bin/env bash
# Package Marka locally and publish a GitHub Release with DMG, ZIP, and checksums.
# GitHub Actions currently fail on UI tests (Swift 6 isolation on the runner),
# so this is the reliable way to ship binaries.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPO="${GITHUB_REPOSITORY:-lubino/marka}"
API="https://api.github.com/repos/${REPO}"
UPLOADS="https://uploads.github.com/repos/${REPO}"
SKIP_TESTS=0
SKIP_PACKAGE=0
ALLOW_DIRTY=0
TAG="${TAG:-}"

usage() {
    cat <<EOF
Publish a GitHub Release from this Mac.

Usage:
  ./scripts/publish-release.sh [--tag vX.Y.Z] [--skip-tests] [--skip-package] [--allow-dirty]

Defaults to VERSION in the tree (or the tag's VERSION when --tag is set).
Builds universal DMG/ZIP locally, then creates or updates the GitHub Release.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            TAG="$2"
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=1
            shift
            ;;
        --skip-package)
            SKIP_PACKAGE=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

github_token() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        printf '%s' "$GITHUB_TOKEN"
        return
    fi
    if [[ -n "${GH_TOKEN:-}" ]]; then
        printf '%s' "$GH_TOKEN"
        return
    fi
    local filled
    filled="$(printf "protocol=https\nhost=github.com\n\n" | git credential fill)"
    local password=""
    while IFS= read -r line; do
        case "$line" in
            password=*) password="${line#password=}" ;;
        esac
    done <<<"$filled"
    if [[ -z "$password" ]]; then
        echo "Error: no GitHub token. Set GITHUB_TOKEN or store git credentials for github.com." >&2
        exit 1
    fi
    printf '%s' "$password"
}

json_field() {
    python3 -c 'import json,sys; print(json.load(sys.stdin)'"$1"')'
}

WORKTREE=""
cleanup() {
    if [[ -n "$WORKTREE" && -d "$WORKTREE" ]]; then
        git -C "$ROOT_DIR" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
    fi
}
trap cleanup EXIT

PACKAGE_ROOT="$ROOT_DIR"
if [[ -n "$TAG" ]]; then
    TAG="${TAG#v}"
    TAG="v$TAG"
    if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        echo "Error: tag $TAG does not exist locally." >&2
        exit 1
    fi
    WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/marka-release.XXXXXX")"
    git worktree add --detach "$WORKTREE" "$TAG" >/dev/null
    PACKAGE_ROOT="$WORKTREE"
fi

VERSION="$(tr -d '[:space:]' < "$PACKAGE_ROOT/VERSION")"
if [[ -z "$TAG" ]]; then
    TAG="v$VERSION"
fi
if [[ "$TAG" != "v$VERSION" ]]; then
    echo "Error: tag $TAG does not match VERSION $VERSION." >&2
    exit 1
fi

if [[ "$ALLOW_DIRTY" != "1" && "$PACKAGE_ROOT" == "$ROOT_DIR" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Error: working tree is dirty. Commit, use --tag vX.Y.Z, or pass --allow-dirty." >&2
        exit 1
    fi
fi

if [[ "$SKIP_TESTS" != "1" ]]; then
    echo "==> Tests..."
    (cd "$PACKAGE_ROOT" && swift run MarkaTests && swift run MarkaUITests)
fi

if [[ "$SKIP_PACKAGE" != "1" ]]; then
    echo "==> Packaging $TAG..."
    (cd "$PACKAGE_ROOT" && UNIVERSAL=1 ./scripts/package-dmg.sh)
fi

DMG="$PACKAGE_ROOT/build/Marka.dmg"
ZIP="$PACKAGE_ROOT/build/Marka-macos.zip"
SUMS="$PACKAGE_ROOT/build/SHA256SUMS.txt"
for f in "$DMG" "$ZIP" "$SUMS"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: missing artifact $f" >&2
        exit 1
    fi
done

TOKEN="$(github_token)"
AUTH_HEADER="Authorization: Bearer ${TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"

NOTES="$(cat <<EOF
### Quick install
\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash
\`\`\`

### Direct DMG download
Download **\`Marka.dmg\`**, open it, and drag **\`Marka.app\`** into **Applications**.

Builds are ad-hoc signed. If macOS Gatekeeper blocks a browser-downloaded copy, run \`xattr -cr /Applications/Marka.app\` or click **Open Anyway** in **System Settings → Privacy & Security**.
EOF
)"

BODY_FILE="$(mktemp)"
python3 - "$TAG" "$VERSION" "$NOTES" "$BODY_FILE" <<'PY'
import json, sys
tag, version, notes, path = sys.argv[1:]
payload = {
    "tag_name": tag,
    "name": f"Marka {version}",
    "body": notes,
    "draft": False,
    "prerelease": False,
    "generate_release_notes": True,
}
with open(path, "w") as fh:
    json.dump(payload, fh)
PY

echo "==> Publishing GitHub Release ${TAG}..."
HTTP="$(mktemp)"
STATUS="$(curl -sS -o "$HTTP" -w "%{http_code}" \
    -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
    "$API/releases/tags/${TAG}")"
if [[ "$STATUS" == "200" ]]; then
    RELEASE_ID="$(json_field '["id"]' < "$HTTP")"
    echo "==> Release already exists (id ${RELEASE_ID}); updating assets..."
    curl -sS -X PATCH \
        -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
        -H "Content-Type: application/json" \
        --data-binary @"$BODY_FILE" \
        "$API/releases/${RELEASE_ID}" >/dev/null
else
    STATUS="$(curl -sS -o "$HTTP" -w "%{http_code}" \
        -X POST \
        -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
        -H "Content-Type: application/json" \
        --data-binary @"$BODY_FILE" \
        "$API/releases")"
    if [[ "$STATUS" != "201" ]]; then
        echo "Error: creating release failed (HTTP ${STATUS}):" >&2
        cat "$HTTP" >&2
        exit 1
    fi
    RELEASE_ID="$(json_field '["id"]' < "$HTTP")"
fi
HTML_URL="$(curl -sS -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" "$API/releases/${RELEASE_ID}" | json_field '["html_url"]')"

EXISTING="$(curl -sS -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" "$API/releases/${RELEASE_ID}/assets")"
python3 - "$EXISTING" <<'PY' | while read -r asset_id; do
import json, sys
assets = json.loads(sys.argv[1])
wanted = {"Marka.dmg", "Marka-macos.zip", "SHA256SUMS.txt"}
for asset in assets:
    if asset.get("name") in wanted:
        print(asset["id"])
PY
    echo "==> Replacing asset id ${asset_id}..."
    curl -sS -X DELETE -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
        "$API/releases/assets/${asset_id}" >/dev/null
done

upload_asset() {
    local path="$1"
    local name
    name="$(basename "$path")"
    local mime="application/octet-stream"
    case "$name" in
        *.zip) mime="application/zip" ;;
        *.dmg) mime="application/x-apple-diskimage" ;;
        *.txt) mime="text/plain" ;;
    esac
    echo "==> Uploading ${name}..."
    local out status
    out="$(mktemp)"
    status="$(curl -sS -o "$out" -w "%{http_code}" \
        -X POST \
        -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
        -H "Content-Type: ${mime}" \
        --data-binary @"$path" \
        "${UPLOADS}/releases/${RELEASE_ID}/assets?name=${name}")"
    if [[ "$status" != "201" ]]; then
        echo "Error: upload of ${name} failed (HTTP ${status}):" >&2
        cat "$out" >&2
        exit 1
    fi
}

upload_asset "$DMG"
upload_asset "$ZIP"
upload_asset "$SUMS"

echo "==> GitHub Release published:"
echo "    ${HTML_URL}"
