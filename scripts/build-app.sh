#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="${1:-release}"
UNIVERSAL="${UNIVERSAL:-0}"
APP_NAME="Marka"
BUNDLE_ID="sk.lubino.marka"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
OUT_DIR="$ROOT_DIR/build"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

ARCH_FLAGS=()
if [[ "$UNIVERSAL" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    echo "==> Building $APP_NAME $VERSION ($CONFIG, universal arm64+x86_64)…"
else
    echo "==> Building $APP_NAME $VERSION ($CONFIG)…"
fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product "$APP_NAME"

BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Help → Marka Help / Keyboard Shortcuts / Marka Tutorial open these in Marka.
cp "$ROOT_DIR/documents/Help.md" "$ROOT_DIR/documents/Shortcuts.md" "$APP_BUNDLE/Contents/Resources/"
mkdir -p "$APP_BUNDLE/Contents/Resources/Tutorial"
cp "$ROOT_DIR/documents/Marka.md" "$APP_BUNDLE/Contents/Resources/Tutorial/"
# No Finder metadata in the bundle: codesign rejects extended attributes and .DS_Store files.
ditto --norsrc --noextattr --noqtn "$ROOT_DIR/documents/assets" "$APP_BUNDLE/Contents/Resources/Tutorial/assets"
find "$APP_BUNDLE" -name .DS_Store -delete
xattr -cr "$APP_BUNDLE"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# SwiftPM's default (Swift Build) backend stamps LC_BUILD_VERSION with "sdk 14.0" (the deployment
# target) instead of the real SDK. macOS then runs Marka in its pre-Tahoe compatibility appearance:
# no Liquid Glass sidebar/toolbar, classic flat tab bar. Re-stamp with the SDK we actually built
# against (before codesigning below).
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_VERSION="$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' "$ROOT_DIR/Package.swift" | head -1)"
MIN_VERSION="${MIN_VERSION:-14.0}"
xcrun vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace \
    -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if ! xcrun vtool -show-build "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "sdk $SDK_VERSION"; then
    echo "error: $APP_NAME binary is not stamped with SDK $SDK_VERSION" >&2
    exit 1
fi

# App icon. One vector source (scripts/generate-icon.swift):
#  * AppIcon.icns — flat fallback for macOS 14/15 (CFBundleIconFile), rendered from the vectors.
#  * Assets.car   — Liquid Glass icon for macOS 26+ (CFBundleIconName), compiled from the committed
#                   Icon Composer bundle Resources/AppIcon.icon. Needs Xcode 26+'s actool (CI has it;
#                   Command Line Tools do not), so CLT-only builds ship just the .icns.
ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT_DIR/scripts/generate-icon.swift" "$ICONSET_TMP"
iconutil -c icns "$ICONSET_TMP" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_TMP")"

ICON_NAME_PLIST=""
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icon"
# actool ships only with Xcode. Use the active toolchain's, else any installed Xcode's (via
# DEVELOPER_DIR) — the Swift build itself keeps using the Command Line Tools.
ACTOOL="$(xcrun --find actool 2>/dev/null || true)"
if [[ -z "$ACTOOL" ]]; then
    for XCODE in $(ls -d /Applications/Xcode*.app 2>/dev/null | sort -r); do
        if CANDIDATE="$(DEVELOPER_DIR="$XCODE/Contents/Developer" xcrun --find actool 2>/dev/null)"; then
            ACTOOL="$CANDIDATE"
            export DEVELOPER_DIR="$XCODE/Contents/Developer"
            break
        fi
    done
fi
if [[ -n "$ACTOOL" ]] && [[ -d "$ICON_SOURCE" ]]; then
    ACTOOL_MAJOR="$("$ACTOOL" --version 2>/dev/null | sed -n 's/.*<string>\([0-9][0-9]*\)\..*/\1/p' | head -1)"
    if [[ "${ACTOOL_MAJOR:-0}" -ge 26 ]]; then
        echo "==> Compiling Liquid Glass icon with actool ${ACTOOL_MAJOR}…"
        ACTOOL_OUT="$(mktemp -d)"
        if "$ACTOOL" "$ICON_SOURCE" --compile "$ACTOOL_OUT" --app-icon AppIcon \
            --enable-on-demand-resources NO --development-region en --target-device mac \
            --platform macosx --include-all-app-icons --minimum-deployment-target "$MIN_VERSION" \
            --output-partial-info-plist "$ACTOOL_OUT/partial.plist" >/dev/null \
            && [[ -f "$ACTOOL_OUT/Assets.car" ]]; then
            cp "$ACTOOL_OUT/Assets.car" "$APP_BUNDLE/Contents/Resources/Assets.car"
            ICON_NAME_PLIST="    <key>CFBundleIconName</key>
    <string>AppIcon</string>"
        else
            echo "warning: actool failed; shipping the flat AppIcon.icns only" >&2
        fi
        rm -rf "$ACTOOL_OUT"
    else
        echo "==> actool ${ACTOOL_MAJOR:-?} < 26: shipping the flat AppIcon.icns only"
    fi
else
    echo "==> No actool (Command Line Tools only): shipping the flat AppIcon.icns only"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
${ICON_NAME_PLIST}
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Markdown Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.markdown</string>
                <string>public.plain-text</string>
                <string>public.utf8-plain-text</string>
                <string>public.text</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>md</string>
                <string>markdown</string>
                <string>txt</string>
            </array>
            <key>NSDocumentClass</key>
            <string>MarkdownDocument</string>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key>
            <string>Markdown</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>md</string>
                    <string>markdown</string>
                </array>
            </dict>
        </dict>
    </array>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing ${APP_BUNDLE}…"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> Built: ${APP_BUNDLE}"
echo "==> Size: $(du -sh "$APP_BUNDLE" | awk '{print $1}')"
