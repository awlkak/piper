#!/usr/bin/env bash
# build-macos.sh — create macOS universal (x86_64 + arm64) distribution
#
# Downloads the official love2d macOS app bundle (already a universal binary),
# injects piper.love into the bundle, patches Info.plist, and zips the result.
#
# Note: the resulting piper.app is NOT code-signed. On first launch, users
# must right-click → Open, or run: xattr -cr piper.app
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ -f "$LOVE_FILE" ] || die "piper.love not found — run 'make love' first"

MAC_ZIP_URL="$LOVE_BASE_URL/love-${LOVE_VERSION}-macos.zip"
WORK_DIR="$DIST_DIR/tmp-mac"
OUT_NAME="piper-${VERSION}-macos-universal"
OUT_ZIP="$DIST_DIR/${OUT_NAME}.zip"

log "Building macOS universal distribution..."

local_zip="$(download_cached "$MAC_ZIP_URL")"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
unzip -q "$local_zip" -d "$WORK_DIR"

LOVE_APP="$WORK_DIR/love.app"
[ -d "$LOVE_APP" ] || die "love.app not found in macOS archive (expected: $LOVE_APP)"

# Copy bundle and rename
PIPER_APP="$WORK_DIR/Piper.app"
cp -R "$LOVE_APP" "$PIPER_APP"

# Inject piper.love into the bundle resources
log "Injecting piper.love..."
cp "$LOVE_FILE" "$PIPER_APP/Contents/Resources/piper.love"

# Patch Info.plist
PLIST="$PIPER_APP/Contents/Info.plist"
log "Patching Info.plist..."

plist_set() {
    local key="$1" type="$2" value="$3"
    if /usr/libexec/PlistBuddy -c "Print :${key}" "$PLIST" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$PLIST"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} ${type} ${value}" "$PLIST"
    fi
}

plist_set CFBundleName           string "Piper"
plist_set CFBundleDisplayName    string "Piper"
plist_set CFBundleIdentifier     string "com.awlkak.piper"
plist_set CFBundleShortVersionString string "${VERSION}"
plist_set CFBundleVersion        string "${VERSION}"
plist_set NSHumanReadableCopyright string "© awl"

# Remove the love.app icon (use love's default for now; replace with a
# custom Piper.icns by placing it at assets/Piper.icns and uncommenting:)
# if [ -f "$REPO_ROOT/assets/Piper.icns" ]; then
#     cp "$REPO_ROOT/assets/Piper.icns" "$PIPER_APP/Contents/Resources/GameIcon.icns"
#     /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile GameIcon" "$PLIST"
# fi

# Strip quarantine xattrs from the bundle before zipping so they don't
# propagate into the archive (macOS stamps these on downloaded files).
xattr -cr "$PIPER_APP" 2>/dev/null || true

# Add a README explaining how to open an unsigned app
cat > "$WORK_DIR/README.txt" <<'EOF'
Piper — Music Tracker
https://github.com/awlkak/piper

FIRST LAUNCH
  Piper.app is not code-signed. macOS will block it by default.

  Option A (easiest):
    Right-click Piper.app → Open → Open

  Option B (Terminal):
    xattr -cr Piper.app
    open Piper.app

  Option C (System Settings):
    System Settings → Privacy & Security → scroll down → "Open Anyway"
EOF

# Package as zip (standard for unsigned love2d macOS distribution)
rm -f "$OUT_ZIP"
(cd "$WORK_DIR" && zip -qr "$OUT_ZIP" "Piper.app" "README.txt" \
    --exclude "*.DS_Store" --exclude "__MACOSX/*")

rm -rf "$WORK_DIR"

SIZE="$(du -sh "$OUT_ZIP" | cut -f1)"
ok "Created: dist/${OUT_NAME}.zip (${SIZE})"
warn "Piper.app is unsigned — first launch: right-click → Open, or: xattr -cr Piper.app"
