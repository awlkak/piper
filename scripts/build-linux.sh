#!/usr/bin/env bash
# build-linux.sh — create Linux distributions
#
# Two artifacts:
#   1. AppImage (x86_64, self-contained, no install needed)
#      Technique: cat love.AppImage + piper.love → piper.AppImage
#      The AppImage ELF reads appended .love data (same as Windows exe technique).
#
#   2. .love zip (any architecture — requires love2d from distro package manager)
#
# Note: AppImage may require FUSE on the target system. If FUSE is unavailable:
#   ./piper-VERSION-linux-x86_64.AppImage --appimage-extract-and-run
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ -f "$LOVE_FILE" ] || die "piper.love not found — run 'make love' first"

APPIMAGE_URL="$LOVE_BASE_URL/love-${LOVE_VERSION}-x86_64.AppImage"
WORK_DIR="$DIST_DIR/tmp-linux"
OUT_APPIMAGE="$DIST_DIR/piper-${VERSION}-linux-x86_64.AppImage"
OUT_LOVE_ZIP="$DIST_DIR/piper-${VERSION}-linux-love.zip"

log "Building Linux distributions..."

# ── Artifact 1: .love zip ─────────────────────────────────────────────────────

log "Packaging .love zip..."
LOVE_ZIP_DIR="$WORK_DIR/piper-${VERSION}-linux-love"
rm -rf "$LOVE_ZIP_DIR"
mkdir -p "$LOVE_ZIP_DIR"
cp "$LOVE_FILE" "$LOVE_ZIP_DIR/piper.love"

cat > "$LOVE_ZIP_DIR/README.txt" <<EOF
Piper $VERSION — Music Tracker
https://github.com/awlkak/piper

Requirements: Love2D 11.5
  Ubuntu/Debian:  sudo apt-get install love
  Fedora:         sudo dnf install love
  Arch Linux:     sudo pacman -S love
  openSUSE:       sudo zypper install love
  Flatpak:        flatpak install flathub org.love2d.love
  Homebrew:       brew install love

Run:
  love piper.love
EOF

rm -f "$OUT_LOVE_ZIP"
(cd "$WORK_DIR" && zip -r "$OUT_LOVE_ZIP" "piper-${VERSION}-linux-love" \
    --exclude "*.DS_Store")

SIZE="$(du -sh "$OUT_LOVE_ZIP" | cut -f1)"
ok "Created: dist/piper-${VERSION}-linux-love.zip (${SIZE})"

# ── Artifact 2: AppImage ──────────────────────────────────────────────────────

log "Building AppImage..."
local_appimage="$(download_cached "$APPIMAGE_URL")"
chmod +x "$local_appimage"

# Fuse: cat love.AppImage + piper.love → piper.AppImage
cat "$local_appimage" "$LOVE_FILE" > "$OUT_APPIMAGE"
chmod +x "$OUT_APPIMAGE"

rm -rf "$WORK_DIR"

SIZE="$(du -sh "$OUT_APPIMAGE" | cut -f1)"
ok "Created: dist/piper-${VERSION}-linux-x86_64.AppImage (${SIZE})"
log "Run with: ./piper-${VERSION}-linux-x86_64.AppImage"
log "No FUSE? Use: ./piper-${VERSION}-linux-x86_64.AppImage --appimage-extract-and-run"
