#!/usr/bin/env bash
# Builds distributable installers for Nexus AI:
#   dist/NexusAI.app                       (universal, ad-hoc signed, no debug entitlements)
#   dist/NexusAI-macOS-universal.dmg       (app + installer + backend, for Finder installs)
#   dist/NexusAI-macOS-universal.zip       (same content, zip)
#   dist/NexusAI-backend-macOS-Linux-Windows.zip
#
# Prereqs: Xcode (with the toolchain set in DEVELOPER_DIR if you use a beta).
# The portable sidecars are vendored in installers/backend/, so the build is
# fully self-contained.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve a usable Xcode developer dir: env override, then known locations,
# then xcode-select. Falls back gracefully so the script works across machines.
pick_developer_dir() {
    for d in "${DEVELOPER_DIR:-}" \
        /Volumes/1TBex/DeveloperTools-Xcode/Contents/Developer \
        /Applications/Xcode.app/Contents/Developer \
        "$HOME/Downloads/Xcode-beta.app/Contents/Developer"; do
        [ -n "$d" ] && [ -x "$d/usr/bin/xcrun" -o -d "$d/Platforms" ] && { printf '%s' "$d"; return; }
    done
    xcode-select -p 2>/dev/null
}
export DEVELOPER_DIR="$(pick_developer_dir)"

BKEND="$ROOT/installers/backend"
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
    cp "$BKEND/$f" "$BACKEND_STAGE/$f"
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
( cd "$BKEND" &&
  rm -rf "$DIST/.backend" && mkdir -p "$DIST/.backend" &&
  cp "$BKEND/nexie_research.py" "$BKEND/nexie_memory.py" "$BKEND/nexie_brain.py" "$DIST/.backend/" &&
  cp "$BKEND/install.sh" "$BKEND/install.ps1" "$BKEND/start_backend.py" "$BKEND/requirements.txt" "$BKEND/README.md" "$DIST/.backend/" &&
  cd "$DIST/.backend" && zip -qry "$DIST/NexusAI-backend-macOS-Linux-Windows.zip" . )

echo "==> Verifying"
DIST_APP="$DIST/NexusAI.app"
rm -rf "$DIST_APP"
ditto "$STAGE/Install NEXUS AI/NexusAI.app" "$DIST_APP"   # keep a plain .app for scripting
file "$DIST_APP/Contents/MacOS/NexusAI"
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