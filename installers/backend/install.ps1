# Nexus AI portable backend installer - Windows (PowerShell 5+)
#
# Copies the three Python sidecars into the app workspace and prints how to
# run them. Requires only a Python 3.9+ interpreter on PATH.
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Ws = if ($env:NEXIE_WS) { $env:NEXIE_WS } else { Join-Path $env:USERPROFILE "NexusAI Workspace" }
$Dest = Join-Path $Ws "app\research-backend"

Write-Host "==> Nexus AI backend installer"
python --version

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($f in @("nexie_research.py", "nexie_memory.py", "nexie_brain.py")) {
    $src = Join-Path $Here $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $Dest $f)
        Write-Host "    installed $f"
    } else {
        Write-Error "MISSING $f (expected next to this script)"
    }
}

Write-Host @"
==> Installed to $Dest
    Run all three services:
        python $Here\start_backend.py

    Or point research summary at any OpenAI-compatible endpoint:
        `$env:NEXIE_LLM_BASE="https://api.example.com/v1"

    To auto-start at logon (Task Scheduler):
        schtasks /Create /TN "NexusAI Backend" /TR "$Here\start_backend.py" /SC ONLOGON /RL HIGHEST
"@