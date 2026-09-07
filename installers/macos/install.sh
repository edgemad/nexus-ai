#!/bin/sh
# Nexus AI - macOS universal installer
#
# Installs the universal NexusAI.app into /Applications and provisions the
# portable research/memory/brain backend under ~/NexusAI Workspace.
#
# It does not hard-gate on macOS version: on hosts older than the app's
# macOS 13.0 floor it warns, then offers a --force override. Nothing silently
# refuses where the app could still run.
set -u

APP_NAME="NexusAI"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

echo "==> Nexus AI macOS installer =="
echo "    (host: $(uname -sm) / $(sw_vers -productVersion 2>/dev/null || echo 'unknown'))"

# 1) Locate the app bundle (DMG root, adjacent folder, or dist/).
find_app() {
    for c in \
        "$HERE/$APP_NAME.app" \
        "$HERE/../$APP_NAME.app" \
        "$HERE/dist/$APP_NAME.app" \
        "/Volumes/$APP_NAME/$APP_NAME.app"
    do
        if [ -d "$c" ]; then APP="$c"; return 0; fi
    done
    echo "ERROR: could not find $APP_NAME.app" >&2
    exit 1
}
find_app
echo "==> Using app bundle: $APP"

# 2) macOS floor check (informational; --force overrides, never hard-gates).
if [ "$(sw_vers -productVersion 2>/dev/null | awk -F. '{print $1$2}')" != "" ]; then
    MAJOR="$(sw_vers -productVersion | awk -F. '{print $1}')"
    MINOR="$(sw_vers -productVersion | awk -F. '{print $2}')"
    FLOOR=$((MAJOR * 100 + MINOR))
    if [ "$FLOOR" -lt 1300 ]; then
        echo "WARNING: this app was built for macOS 13.0+ (you are on $MAJOR.$MINOR)."
        if [ "$FORCE" -ne 1 ]; then
            echo "         It may not launch on this OS. Re-run with --force to install anyway."
            exit 1
        fi
        echo "         Installing anyway (--force)."
    fi
fi

# 3) Quit a running copy so /Applications is not locked.
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1
sleep 1

# 4) Ad-hoc re-sign with the project entitlements, dropping the get-task-allow
#    debug entitlement Xcode injects into unsigned Release builds.
if command -v codesign >/dev/null 2>&1; then
    ENT="$HERE/NexusAI.entitlements"
    if [ ! -f "$ENT" ] && [ -f "$HERE/NexusAI/NexusAI.entitlements" ]; then
        ENT="$HERE/NexusAI/NexusAI.entitlements"
    fi
    if [ -f "$ENT" ]; then
        codesign --force --deep --sign - --entitlements "$ENT" "$APP" >/dev/null 2>&1 \
            && echo "==> Re-signed ad-hoc; debug entitlement removed."
    fi
fi

# 5) Install into /Applications (privileged copy; one password prompt).
if [ "$(id -u)" = "0" ]; then
    ditto --rsrc "$APP" "/Applications/$APP_NAME.app" || exit 1
elif [ -x /usr/bin/osascript ]; then
    APP_ESC="$(printf '%s' "$APP" | sed 's/"/\\"/g')"
    osascript -e "do shell script \"ditto --rsrc '$APP_ESC' '/Applications/$APP_NAME.app'\" with administrator privileges" >/dev/null || exit 1
else
    if ! sudo -n ditto --rsrc "$APP" "/Applications/$APP_NAME.app" 2>/dev/null; then
        sudo ditto --rsrc "$APP" "/Applications/$APP_NAME.app" || exit 1
    fi
fi
echo "==> Installed to /Applications/$APP_NAME.app"

# 6) Provision the portable backend under the app's workspace.
WS="${NEXIE_WS:-$HOME/NexusAI Workspace}"
RESEARCH_DIR="$WS/app/research-backend"
if [ -d "$HERE/backend" ]; then
    mkdir -p "$RESEARCH_DIR"
    for f in nexie_research.py nexie_memory.py nexie_brain.py; do
        if [ -f "$HERE/backend/$f" ]; then
            cp "$HERE/backend/$f" "$RESEARCH_DIR/$f"
        fi
    done
    echo "==> Backend provisioned at $RESEARCH_DIR"
else
    echo "==> No bundled backend/ folder found; skipping backend provisioning."
fi

# 7) Launch and report.
open "/Applications/$APP_NAME.app" 2>/dev/null && echo "==> $APP_NAME launched."
cat <<'EOF'
==> Done.
    - First launch downloads any requested models into the workspace.
    - Research/memory/brain sidecars run from ~/NexusAI Workspace/app/research-backend.
    - To uninstall: rm -rf /Applications/NexusAI.app
EOF