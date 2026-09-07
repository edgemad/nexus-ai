# Nexus AI backend - portable package.
#
# Pure-standard-library Python 3.9+. Runs on macOS, Linux and Windows with no
# third-party packages. The three services speak HTTP on localhost and are
# consumed by the Nexus AI macOS app (-> CapabilitiesCard) or any HTTP client.

## Files
#
#   nexie_research.py  research + deep-research with evidence & confidence
#   nexie_memory.py    long-term memory store
#   nexie_brain.py     intent/brain service
#   start_backend.py   launches all three; shares an auth token; Ctrl-C stops
#   requirements.txt   (note only - no deps)
#   install.sh         macOS / Linux installer
#   install.ps1        Windows installer

## Install
#
#   macOS / Linux:  ./install.sh
#   Windows:        powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# installs into `~/NexusAI Workspace/app/research-backend` (override with
# $env:NEXIE_WS), matching the location the macOS app expects.

## Run
#
#   python3 start_backend.py        # or: python.exe start_backend.py
#
# Starts:
#   nexie-research  http://127.0.0.1:8765
#   nexie-memory    http://127.0.0.1:8766
#   nexie-brain     http://127.0.0.1:8767
#
# All three require the shared token (printed at start, or set
# NEXIE_AUTH_TOKEN yourself). Endpoints require:
#   Authorization: Bearer <token>

## LLM endpoint for synthesis
#
# Research summary writing calls an OpenAI-compatible endpoint. Default:
# http://127.0.0.1:8080/v1 (the app's local llama server). For a remote or
# different service:
#
#   NEXIE_LLM_BASE=https://api.example.com/v1 python3 start_backend.py

## Individual services
#
#   NEXIE_AUTH_TOKEN=.. python3 nexie_research.py   (port: NEXIE_RESEARCH_PORT / 8765)
#   NEXIE_AUTH_TOKEN=.. python3 nexie_memory.py     (port: NEXIE_MEMORY_PORT   / 8766)
#   NEXIE_AUTH_TOKEN=.. python3 nexie_brain.py      (port: NEXIE_BRAIN_PORT    / 8767)

## Compatibility
#
# No OS minimum: the sidecars bind 127.0.0.1 explicitly, use only the stdlib,
# and need nothing but a stock Python 3.9+ interpreter.