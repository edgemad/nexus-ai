#!/bin/bash
# Nexie sidecar integration checks.
#
# Two sections:
#   A) Live sidecars (research :8765, memory :8766, brain :8767) — public
#      liveness (/health) + loopback-only CORS policy. Works with or without a
#      running app.
#   B) Auth + contract + control checks on throwaway ports with a KNOWN token:
#      data/control endpoints reject missing/bad tokens (401), accept the good
#      token, report version/capabilities/metrics, and /shutdown terminates the
#      process. Uses a dedicated instance per service so the live app's sidecars
#      are never disturbed.
#
# Usage:  ./Tests/integration_sidecars.sh
set -uo pipefail

BACKEND="$HOME/NexusAI Workspace/app/research-backend"
PY="/usr/bin/python3"
TOKEN="integrationtoken"
failures=0

vcheck() { # vcheck desc expected actual  (pass when actual == expected)
    if [ "$3" = "$2" ]; then echo "PASS $1"; else echo "FAIL $1 (got '$3', want '$2')"; failures=$((failures + 1)); fi
}

hdr() { curl -s -i -m 3 "$@"; }
has_acao() { hdr "$@" | tr -d '\r' | grep -qi '^Access-Control-Allow-Origin:'; echo $?; }
acao_value() { hdr "$@" | tr -d '\r' | grep -i '^Access-Control-Allow-Origin:' | awk '{print $2}' | tail -1; }

ensure() { # ensure port script envname [extra_env=value...]
    local port="$1" script="$2" envname="$3"; shift 3
    if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health")" = "200" ]; then
        return 0
    fi
    echo "starting sidecar on :$port..."
    env "$envname=$port" "$@" "$PY" "$script" >"/tmp/nexie-integration-$port.log" 2>&1 &
    disown
    for _ in $(seq 1 20); do
        if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health")" = "200" ]; then return 0; fi
        sleep 0.5
    done
    echo "sidecar on :$port did not come up"; failures=$((failures + 1)); return 1
}

# ---------------------------------------------------------------------------
# Section A: live sidecars (public endpoints only)
# ---------------------------------------------------------------------------
ensure 8765 "$BACKEND/nexie_research.py" NEXIE_RESEARCH_PORT
ensure 8766 "$BACKEND/nexie_memory.py" NEXIE_MEMORY_PORT "NEXIE_WORKSPACE_ROOT=$HOME/NexusAI Workspace"
ensure 8767 "$BACKEND/nexie_brain.py" NEXIE_BRAIN_PORT

echo "== A. health (liveness is unauthenticated) =="
vcheck "research health" 200 "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/health)"
vcheck "memory health" 200 "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8766/health)"
vcheck "brain health" 200 "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8767/health)"

echo "== A. CORS policy (loopback-only origins) =="
vcheck "foreign origin blocked" blocked "$([ "$(has_acao -H 'Origin: https://evil.example' http://127.0.0.1:8765/health)" = "1" ] && echo blocked || echo leaked)"
vcheck "loopback origin echoed" "http://localhost:5173" "$(acao_value -H 'Origin: http://localhost:5173' http://127.0.0.1:8765/health)"
vcheck "loopback 127.0.0.1 echoed" "http://127.0.0.1:5173" "$(acao_value -H 'Origin: http://127.0.0.1:5173' http://127.0.0.1:8766/health)"
vcheck "native (no Origin) unaffected" blocked "$([ "$(has_acao http://127.0.0.1:8767/health)" = "1" ] && echo blocked || echo leaked)"
vcheck "OPTIONS foreign blocked" blocked "$([ "$(has_acao -X OPTIONS -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: POST' http://127.0.0.1:8766/health)" = "1" ] && echo blocked || echo leaked)"

echo "== A. data endpoints of a live (app-owned) sidecar reject anonymous calls =="
if [ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' http://127.0.0.1:8767/version)" = "401" ]; then
    vcheck "anonymous brain intent rejected" 401 "$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"query":"what time is it?"}' http://127.0.0.1:8767/intent)"
else
    echo "SKIP anonymous brain intent rejected (live sidecar is a test-started unauthenticated instance; auth covered in section B)"
fi

# ---------------------------------------------------------------------------
# Section B: auth + contracts + control on throwaway ports (known token)
# ---------------------------------------------------------------------------
auth_round() { # auth_round name envname script data_path port
    local name="$1" envname="$2" script="$3" path="$4" port="$5"
    local pid
    env NEXIE_AUTH_TOKEN="$TOKEN" "$envname=$port" "$PY" "$script" >"/tmp/nexie-auth-$port.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 30); do
        if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health")" = "200" ]; then break; fi
        sleep 0.5
    done
    echo "== B. $name (auth + version + control on :$port) =="
    vcheck "$name health public" 200 "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health")"
    vcheck "$name no-token data rejected" 401 "$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"query":"anything"}' "http://127.0.0.1:$port/$path")"
    vcheck "$name bad-token data rejected" 401 "$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer wrong' -H 'Content-Type: application/json' -d '{"query":"anything"}' "http://127.0.0.1:$port/$path")"
    vcheck "$name version" ok "$(curl -s -m 3 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$port/version" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("ok") and d.get("version") else "bad")' 2>/dev/null || echo bad)"
    vcheck "$name capabilities authed" ok "$(curl -s -m 3 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$port/capabilities" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("capabilities", {}).get("auth") else "bad")' 2>/dev/null || echo bad)"
    vcheck "$name metrics authed" ok "$(curl -s -m 3 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$port/metrics" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print("ok" if "requests" in d and "uptime_seconds" in d else "bad")' 2>/dev/null || echo bad)"
    if kill -0 "$pid" 2>/dev/null; then
        curl -s -m 3 -o /dev/null -w '' -X POST -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$port/shutdown" || true
        for _ in $(seq 1 20); do
            if ! kill -0 "$pid" 2>/dev/null; then status=stopped; break; fi
            status=still-running
            sleep 0.25
        done
        vcheck "$name shutdown stops process" stopped "${status:-stopped}"
    else
        vcheck "$name shutdown stops process" stopped "process-already-gone"
    fi
}

auth_round research NEXIE_RESEARCH_PORT "$BACKEND/nexie_research.py" research 14665
auth_round memory NEXIE_MEMORY_PORT "$BACKEND/nexie_memory.py" context 14666
auth_round brain NEXIE_BRAIN_PORT "$BACKEND/nexie_brain.py" intent 14667

echo
if [ "$failures" -eq 0 ]; then
    echo "ALL SIDECAR INTEGRATION CHECKS PASSED"; exit 0
else
    echo "$failures SIDECAR CHECK(S) FAILED"; exit 1
fi