#!/usr/bin/env bash
# build-love.sh — create piper.love from the current HEAD commit
#
# Uses `git archive` so only tracked files are included.
# Uncommitted changes are intentionally excluded for release builds.
# For a dev build including uncommitted changes, use `love .` directly.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

mkdir -p "$DIST_DIR"

log "Building piper.love (version: $VERSION)"

git -C "$REPO_ROOT" archive --format=zip HEAD -o "$LOVE_FILE" \
    || die "git archive failed"

SIZE="$(du -sh "$LOVE_FILE" | cut -f1)"
ok "Created: dist/piper-${VERSION}.love (${SIZE})"
