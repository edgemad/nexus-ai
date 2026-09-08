#!/usr/bin/env bash
# Nexus AI - Linux build. Produces a portable backend zip and (optionally) a
# self-contained AppImage from the matching OS's toolchain.
#
# Run on Ubuntu 22.04+ (or any modern distro). No Mac-only step.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VER="${VERSION:-1.1}"

echo "==> Nexus AI Linux build ($(uname -sm))"
mkdir -p "$DIST/backend"

echo "==> Staging portable backend"
for f in nexie_research.py nexie_memory.py nexie_brain.py start_backend.py install.sh requirements.txt README.md; do
    cp "$ROOT/installers/backend/$f" "$DIST/backend/" 2>/dev/null || echo "    (skip missing $f)"
done
chmod +x "$DIST/backend/start_backend.py" "$DIST/backend/install.sh"

echo "==> Zipping backend"
( cd "$DIST/backend" && zip -qry "$DIST/NexusAI-backend-Linux-$VER.zip" . )

# Optional AppImage: only if the user supplied an app image build dir.
# The SwiftUI macOS client cannot be ported to Linux (AppKit); the portable
# backend is the Linux deliverable. If you have a native Linux GUI, drop a
# build and uncomment below.
# APPIMAGETOOL="${APPIMAGETOOL:-$ROOT/scripts/appimagetool}"
# if [ -x "$APPIMAGETOOL" ] && [ -d "$ROOT/dist/linuxgui" ]; then
#     ARCH=x86_64 "$APPIMAGETOOL" "$ROOT/dist/linuxgui" "$DIST/NexusAI-Linux.AppImage"
# fi

echo "==> Done: $DIST/NexusAI-backend-Linux-$VER.zip"
ls -la "$DIST"