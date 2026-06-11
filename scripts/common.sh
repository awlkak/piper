#!/usr/bin/env bash
# common.sh — shared functions, constants, and version detection
# Sourced by all build scripts.

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
CACHE_DIR="$REPO_ROOT/scripts/cache"

# ── Love2D version and URLs ───────────────────────────────────────────────────

LOVE_VERSION="11.5"
LOVE_BASE_URL="https://github.com/love2d/love/releases/download/${LOVE_VERSION}"

# ── Version detection ─────────────────────────────────────────────────────────

get_version() {
    local tag
    # Exact tag match (clean release build)
    tag=$(git -C "$REPO_ROOT" describe --tags --exact-match 2>/dev/null || true)
    if [ -n "$tag" ]; then
        echo "${tag#v}"
        return
    fi
    # Long describe (dev build: v0.1.0-3-gabcdef[-dirty])
    tag=$(git -C "$REPO_ROOT" describe --tags --long --dirty 2>/dev/null || true)
    if [ -n "$tag" ]; then
        echo "${tag#v}"
        return
    fi
    # No tags at all
    local sha
    sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo "0.0.0-dev-${sha}"
}

VERSION="$(get_version)"
LOVE_FILE="$DIST_DIR/piper-${VERSION}.love"

# ── Output helpers ────────────────────────────────────────────────────────────

log()  { printf '\033[0;34m[piper]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[0;32m[ok]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ── Download helper (with caching) ───────────────────────────────────────────

download_cached() {
    local url="$1"
    local filename
    filename="$(basename "$url")"
    local dest="$CACHE_DIR/$filename"
    mkdir -p "$CACHE_DIR"
    if [ -f "$dest" ]; then
        log "Using cached: $filename"
    else
        log "Downloading: $url"
        curl -fL --progress-bar -o "$dest.tmp" "$url" \
            || { rm -f "$dest.tmp"; die "Download failed: $url"; }
        mv "$dest.tmp" "$dest"
    fi
    echo "$dest"
}
