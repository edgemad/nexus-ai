@echo off
setlocal EnableDelayedExpansion
rem ============================================================
rem  Nexus AI backend installer - Windows
rem  Installs the research/memory/brain services into
rem  %USERPROFILE%\NexusAI Workspace\app\research-backend
rem  Requires: Python 3.9+ on PATH (or the 'py' launcher)
rem ============================================================
set "WS=%NEXIE_WS%"
if "%WS%"=="" set "WS=%USERPROFILE%\NexusAI Workspace"
set "DEST=%WS%\app\research-backend"

echo ==^> Nexus AI backend installer ^(Windows^)
python --version >nul 2>&1 || py -3 --version >nul 2>&1 || (
    echo ERROR: Python 3.9+ is required but was not found on PATH.
    echo        Install from https://www.python.org/downloads/ and re-run.
    exit /b 1
)

mkdir "%DEST%" 2>nul
for %%f in (nexie_research.py nexie_memory.py nexie_brain.py start_backend.py) do (
    if exist "%~dp0%%f" (
        copy /Y "%~dp0%%f" "%DEST%\%%f" >nul
        echo     installed %%f
    ) else (
        echo     MISSING %%~nxf& exit /b 1
    )
)

echo ==^> Installed to %DEST%
echo     Run with:   %DEST%\start_backend.cmd
echo     Or:         python %DEST%\start_backend.py

choice /C YN /M "Add a 'NexusAI Backend' shortcut to the Desktop"
if not errorlevel 2 (
    powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\NexusAI Backend.lnk'); $s.TargetPath='%DEST%\start_backend.cmd'; $s.WorkingDirectory='%DEST%'; $s.Save()"
    echo     Shortcut created.
)

echo ==^> Done. Open %DEST%\start_backend.cmd (or schedule it) to run the backend.
endlocal