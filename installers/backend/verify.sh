#!/bin/sh
# Nexus AI backend verify - POSIX (macOS / Linux)
# Pings /version on each service port. A reply of any kind (including an
# {"ok":false,...unauthorized} response) proves the service is listening.
set -u
up=1
for p in 8765 8766 8767; do
    echo "-- probing :$p"
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 3 "http://127.0.0.1:$p/version" || up=0
    else
        # curl-less fallback (Python is guaranteed present for the backend)
        python3 - "$p" <<'PY' || up=0
import sys, urllib.request
p = sys.argv[1]
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{p}/version", timeout=3) as r:
        print(r.read().decode())
except Exception as e:
    print(f"failed on :{p}: {e}", file=sys.stderr)
    sys.exit(1)
PY
    fi
    echo
done
[ "$up" -eq 1 ] && echo "==> All three services respond." || echo "==> At least one service did not respond - is it running?"