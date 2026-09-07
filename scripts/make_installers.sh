#!/usr/bin/env bash
# Builds distributable installers for Nexus AI:
#   dist/NexusAI.app                       (universal, ad-hoc signed, no debug entitlements)
#   dist/NexusAI-macOS-universal.dmg       (app + installer + backend, for Finder installs)
#   dist/NexusAI-macOS-universal.zip       (same content, zip)
#   dist/NexusAI-backend-macOS-Linux-Windows.zip
#
# Prereqs: Xcode (with the toolchain set in DEVELOPER_DIR if you use a beta),
# and the portable sidecars at the workspace path below.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Users/edge/Downloads/Xcode-beta.app/Contents/Developer}"

WS_RESEARCH="${WS_RESEARCH:-$HOME/NexusAI Workspace/app/research-backend}"
DIST="$ROOT/dist"
STAGE="$ROOT/dist/.stage"
ENT="$ROOT/NexusAI/NexusAI.entitlements"

echo "==> Building Release (universal)"

BUILD_DIR="$(xcodebuild -project "$ROOT/NexusAI.xcodeproj" -scheme NexusAI -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR/{print $2; exit}')"
xcodebuild -project "$ROOT/NexusAI.xcodeproj" -scheme NexusAI -configuration Release \
    -destination 'platform=macOS' build >/dev/null

SRC_APP="$BUILD_DIR/NexusAI.app"
[ -d "$SRC_APP" ] || { echo "app not found at $SRC_APP" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/Install NEXUS AI" "$DIST"

echo "==> Preparing app bundle"
ditto "$SRC_APP" "$STAGE/Install NEXUS AI/NexusAI.app"

echo "==> Re-signing (ad-hoc, stripping get-task-allow)"
codesign --force --deep --sign - --entitlements "$ENT" "$STAGE/Install NEXUS AI/NexusAI.app"
codesign --verify --deep --strict "$STAGE/Install NEXUS AI/NexusAI.app" \
    || echo "--verify warned (ad-hoc, expected)"

echo "==> Staging backend (portable sidecars)"
BACKEND_STAGE="$STAGE/Install NEXUS AI/backend"
mkdir -p "$BACKEND_STAGE"
for f in nexie_research.py nexie_memory.py nexie_brain.py; do
    cp "$WS_RESEARCH/$f" "$BACKEND_STAGE/$f"
done
cp "$ROOT"/installers/backend/*.{sh,ps1,py,txt,md} "$BACKEND_STAGE/" 2>/dev/null || true
cp "$ENT" "$STAGE/Install NEXUS AI/NexusAI.entitlements"
cp "$ROOT/installers/README.md" "$STAGE/Install NEXUS AI/README.txt"
cp "$ROOT/installers/macos/install.sh" "$STAGE/Install NEXUS AI/install.sh"
chmod +x "$STAGE/Install NEXUS AI/install.sh" "$BACKEND_STAGE/install.sh"
ln -sf /Applications "$STAGE/Install NEXUS AI/Applications"

echo "==> Creating DMG"
hdiutil create -volname "NexusAI" -srcfolder "$STAGE/Install NEXUS AI" \
    -ov -format UDZO "$DIST/NexusAI-macOS-universal.dmg" >/dev/null

echo "==> Creating app zip"
( cd "$STAGE/Install NEXUS AI" && zip -qry "$DIST/NexusAI-macOS-universal.zip" NexusAI.app backend install.sh README.txt )

echo "==> Creating cross-OS backend zip"
( cd "$ROOT/installers/backend" &&
  rm -rf "$DIST/.backend" && mkdir -p "$DIST/.backend" &&
  cp "$WS_RESEARCH/nexie_research.py" "$WS_RESEARCH/nexie_memory.py" "$WS_RESEARCH/nexie_brain.py" "$DIST/.backend/" &&
  cp install.sh install.ps1 start_backend.py requirements.txt README.md "$DIST/.backend/" &&
  cd "$DIST/.backend" && zip -qry "$DIST/NexusAI-backend-macOS-Linux-Windows.zip" . )

echo "==> Verifying"
DIST_APP="$DIST/NexusAI.app"
rm -rf "$DIST_APP"
ditto "$STAGE/Install NEXUS AI/NexusAI.app" "$DIST_APP"   # keep a plain .app for scripting
lipo -info "$DIST_APP/Contents/MacOS/NexusAI"
codesign -dvv "$DIST_APP" 2>&1 | grep -E "Signature|TeamIdentifier" \
    || true
codesign -d --entitlements - "$DIST_APP" 2>/dev/null | grep -q get-task-allow \
    && { echo "ERROR: get-task-allow still present" >&2; exit 1; } \
    || echo "get-task-allow: absent (good)"

echo "==> Hashes"
shasum -a 256 \
    "$DIST/NexusAI-macOS-universal.dmg" \
    "$DIST/NexusAI-macOS-universal.zip" \
    "$DIST/NexusAI-backend-macOS-Linux-Windows.zip"

rm -rf "$DIST/.backend"
echo "==> Done. Distributables in $DIST"