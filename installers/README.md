# Nexus AI Installers

Two independently distributable pieces:

| Package | Target | Where it goes | Minimum |
|---|---|---|---|
| `NexusAI-macOS-universal.dmg` / `.zip` | macOS (Intel + Apple Silicon) | `/Applications` | macOS 13.0 (see note) |
| `NexusAI-backend-macOS-Linux-Windows.zip` | macOS / Linux / Windows | `~/NexusAI Workspace/app/research-backend` (or `NEXIE_WS`) | Python 3.9+, stdlib only |

## About "minimum OS version"

There is no true "no minimum" for a framework-based native app. The SwiftUI
client is built against AppKit/SwiftUI APIs (e.g. `Gauge`), which have a floor
of **macOS 13.0**; the binary is universal (x86_64 + arm64) so it runs on every
Mac that still supports Ventura or newer. The installer does **not** hard-gate on
versions — if the host is older it warns and still offers a record override
(`--force`), so nothing silently refuses to run where it could.

The **research/memory/brain Python backend has no OS or third-party
dependencies** (pure standard library), so it has no minimum platform version
beyond Python 3.9 — it is the portable half of the stack and can be pointed at
any macOS/Linux/Windows host, or any OpenAI-compatible LLM endpoint.

## macOS app

From the DMG: double-click `install.applescript`/run `install.sh`, or drag
`NexusAI.app` into the Applications symlink (the DMG includes one). The
command-line install order:

```
hdiutil attach dist/NexusAI-macOS-universal.dmg
cd /Volumes/NexusAI
./install.sh            # or ./install.sh --force
```

`install.sh`:
1. resolves the app bundle (DMG mount or adjacent folder),
2. re-signs it ad-hoc and strips Xcode's debug `get-task-allow` entitlement,
3. copies it into `/Applications` (prompts for the password once),
4. provisions `~/NexusAI Workspace/app/research-backend/` with the portable
   sidecars so research/memory/brain features are ready,
5. opens the app and prints status (models are downloaded on first use).

## Portable backend (any OS)

```
unzip NexusAI-backend-macOS-Linux-Windows.zip -d backend
cd backend && ./install.sh          # macOS / Linux
./install.ps1                       # Windows (PowerShell)
# then, to run all three services on this host:
python3 start_backend.py            # macOS / Linux
python.exe start_backend.py         # Windows
```

`start_backend.py` starts `nexie_research` (:8765), `nexie_memory` (:8766) and
`nexie_brain` (:8767) on localhost under one shared auto-generated auth token,
and forwards SIGINT/SIGTERM/CTRL-C to stop them. Set `NEXIE_LLM_BASE` to any
OpenAI-compatible endpoint (default `http://127.0.0.1:8080/v1`) so research
synthesis works:

```
NEXIE_LLM_BASE=https://api.example.com/v1 python3 start_backend.py
```

Each service also reads `NEXIE_AUTH_TOKEN` directly if you want to run them
individually:

```
NEXIE_AUTH_TOKEN=mytoken python3 app/research-backend/nexie_research.py
```

## Verifying what you got

```
lipo -info NexusAI.app/Contents/MacOS/NexusAI     # universal (x86_64 arm64)
codesign -dvv NexusAI.app                         # Signature=adhoc, no get-task-allow
curl -s http://127.0.0.1:8765/version             # {"name":"nexie-research","service_version":"1.1.0",...}
shasum -a 256 NexusAI-macOS-universal.dmg
```