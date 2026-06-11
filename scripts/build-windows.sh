#!/usr/bin/env bash
# build-windows.sh — create Windows x64 distribution
#
# Technique: binary-append love.exe + piper.love → piper.exe
# The PE format is self-delimiting; love.exe reads appended .love data.
# All required DLLs from the official love2d zip are included.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ -f "$LOVE_FILE" ] || die "piper.love not found — run 'make love' first"

WIN_ZIP_URL="$LOVE_BASE_URL/love-${LOVE_VERSION}-win64.zip"
WORK_DIR="$DIST_DIR/tmp-win"
OUT_NAME="piper-${VERSION}-windows-x64"
OUT_ZIP="$DIST_DIR/${OUT_NAME}.zip"

log "Building Windows x64 distribution..."

local_zip="$(download_cached "$WIN_ZIP_URL")"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
unzip -q "$local_zip" -d "$WORK_DIR"

LOVE_WIN_DIR="$WORK_DIR/love-${LOVE_VERSION}-win64"
[ -d "$LOVE_WIN_DIR" ] || die "Expected directory not found: $LOVE_WIN_DIR"

# Fuse: cat love.exe + piper.love → piper.exe
log "Fusing piper.exe..."
cat "$LOVE_WIN_DIR/love.exe" "$LOVE_FILE" > "$LOVE_WIN_DIR/piper.exe"
rm "$LOVE_WIN_DIR/love.exe"

# Remove files users don't need
rm -f "$LOVE_WIN_DIR/lovec.exe" "$LOVE_WIN_DIR/love.ico" \
      "$LOVE_WIN_DIR/changes.txt" "$LOVE_WIN_DIR/readme.txt"

# Add a README
cat > "$LOVE_WIN_DIR/README.txt" <<EOF
Piper $VERSION — Music Tracker
https://github.com/awlkak/piper

Run piper.exe to launch.

Keep all files in this folder together — piper.exe requires the
DLLs alongside it.
EOF

# Rename directory and zip
FINAL_DIR="$WORK_DIR/$OUT_NAME"
mv "$LOVE_WIN_DIR" "$FINAL_DIR"

rm -f "$OUT_ZIP"
(cd "$WORK_DIR" && zip -r "$OUT_ZIP" "$OUT_NAME" --exclude "*.DS_Store")

rm -rf "$WORK_DIR"

SIZE="$(du -sh "$OUT_ZIP" | cut -f1)"
ok "Created: dist/${OUT_NAME}.zip (${SIZE})"
