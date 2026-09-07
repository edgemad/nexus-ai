#!/bin/sh
# Nexus AI portable backend installer - POSIX (macOS / Linux / BSD)
#
# Copies the three Python sidecars into the app workspace and prints how to
# run them. Pure-standard-library Python 3.9+; no third-party dependencies.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WS="${NEXIE_WS:-$HOME/NexusAI Workspace}"
DEST="$WS/app/research-backend"

echo "==> Nexus AI backend installer"
echo "    Python: $(python3 --version 2>&1 || echo 'missing')"

mkdir -p "$DEST"
for f in nexie_research.py nexie_memory.py nexie_brain.py; do
    if [ -f "$HERE/$f" ]; then
        cp "$HERE/$f" "$DEST/$f"
        echo "    installed $f"
    else
        echo "    MISSING $f (expected next to this script)" >&2
    fi
done

cat <<EOF

==> Installed to $DEST
    Run all three services:
        $HERE/start_backend.py

    Or point research summary at any OpenAI-compatible endpoint:
        NEXIE_LLM_BASE=https://api.example.com/v1 $HERE/start_backend.py

    Launch at boot (systemd example):
        # ~/.config/systemd/user/nexie-backend.service
        [Unit]
        Description=Nexus AI backend
        [Service]
        ExecStart=$HERE/start_backend.py
        Restart=on-failure
EOF