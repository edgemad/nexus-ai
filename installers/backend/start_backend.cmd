@echo off
rem ============================================================
rem  Nexus AI backend launcher - Windows
rem  Starts all three services on 127.0.0.1:8765/8766/8767 with a
rem  shared auto-generated token. Prefer the 'py' launcher when
rem  python.exe is not on PATH.
rem ============================================================
cd /d "%~dp0"
py -3 start_backend.py 2>nul
if errorlevel 1 python start_backend.py