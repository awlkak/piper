#!/usr/bin/env bash
# check-deps.sh — validate that all required tools are present
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

REQUIRED=(zip unzip curl git)
MISSING=()

for tool in "${REQUIRED[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING+=("$tool")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    die "Missing required tools: ${MISSING[*]}"
fi

# PlistBuddy is needed for macOS builds
if [ ! -x /usr/libexec/PlistBuddy ]; then
    die "PlistBuddy not found at /usr/libexec/PlistBuddy (required for macOS builds)"
fi

# Must be running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    die "This build system must run on macOS (OSTYPE=$OSTYPE)"
fi

# Git repo sanity check
if ! git -C "$REPO_ROOT" rev-parse --git-dir &>/dev/null; then
    die "Not inside a git repository — version detection requires git"
fi

ok "All dependencies satisfied (version: $VERSION)"
