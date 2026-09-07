#!/usr/bin/env python3
"""Cross-platform launcher for the Nexus AI portable backend.

Starts nexie_research (:8765), nexie_memory (:8766) and nexie_brain (:8767)
on localhost under one shared auth token, and stops them on Ctrl-C/SIGTERM.

Environment:
    NEXIE_LLM_BASE   OpenAI-compatible endpoint for research synthesis
                     (default http://127.0.0.1:8080/v1)
    NEXIE_AUTH_TOKEN shared bearer token (auto-generated when unset)

Pure standard library; Python 3.9+.
"""
import os
import signal
import subprocess
import sys
import threading
import time
import uuid

SERVICES = [
    ("nexie_research.py", "NEXIE_RESEARCH_PORT", "8765"),
    ("nexie_memory.py", "NEXIE_MEMORY_PORT", "8766"),
    ("nexie_brain.py", "NEXIE_BRAIN_PORT", "8767"),
]


def here():
    return os.path.dirname(os.path.abspath(__file__))


def main():
    token = os.environ.get("NEXIE_AUTH_TOKEN") or uuid.uuid4().hex
    llm_base = os.environ.get("NEXIE_LLM_BASE", "http://127.0.0.1:8080/v1")
    if os.environ.get("NEXIE_LLM_BASE") is None:
        print(f"NOTE: NEXIE_LLM_BASE unset; defaulting to {llm_base} "
              "(set it if your model serves elsewhere)")

    procs = []
    for script, port_var, default_port in SERVICES:
        path = os.path.join(here(), script)
        if not os.path.exists(path):
            print(f"ERROR: missing {path} (run install.sh / install.ps1 first)")
            return 2
        env = dict(os.environ)
        env["NEXIE_AUTH_TOKEN"] = token
        port = os.environ.get(port_var, default_port)
        proc = subprocess.Popen(
            [sys.executable, path],
            env=env,
            stdout=subprocess.DEVNULL if not sys.stdout.isatty() else None,
            stderr=None,
        )
        procs.append((script, port, proc))

    print(f"==> backend running (shared token set). Ports: " +
          ", ".join(f"{s}:{p}" for s, p, _ in procs))
    print("    tok = " + token)

    def stop(_signum=None, _frame=None):
        print("\n==> stopping backend...")
        for _, _, proc in procs:
            try:
                proc.terminate()
            except OSError:
                pass
        for _, _, proc in procs:
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.kill()
        raise SystemExit(0)

    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)

    try:
        while True:
            time.sleep(3600)
            if any(proc.poll() is not None for _, _, proc in procs):
                print("==> a service exited; shutting down the group")
                stop()
    except KeyboardInterrupt:
        stop()


if __name__ == "__main__":
    sys.exit(main())