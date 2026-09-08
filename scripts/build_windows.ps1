# Nexus AI - Windows build
# Run on a Windows runner (GitHub Actions windows-latest) or any Windows PC
# with Python 3.9+ and the repo checked out. Produces:
#   dist\NexusAI-backend-Windows.zip
#
# Note: the SwiftUI macOS client is AppKit-only and cannot be built for
# Windows. The Windows deliverable is the portable Python backend plus (for a
# native launcher) the option to bundle the three .py services as a .exe
# via PyInstaller - see the commented-out block below.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Dist = Join-Path $Root "dist"
$Ver = if ($env:VERSION) { $env:VERSION } else { "1.1" }

Write-Host "==> Nexus AI Windows build"
New-Item -ItemType Directory -Force -Path (Join-Path $Dist "backend") | Out-Null
$Backend = Join-Path $Root "installers\backend"

foreach ($f in @("nexie_research.py","nexie_memory.py","nexie_brain.py","start_backend.py","install.ps1","requirements.txt","README.md")) {
    $src = Join-Path $Backend $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $Dist "backend\$f") }
}

Compress-Archive -Force -Path (Join-Path $Dist "backend\*") -DestinationPath (Join-Path $Dist "NexusAI-backend-Windows-$Ver.zip")
Write-Host "==> Done: $(Join-Path $Dist "NexusAI-backend-Windows-$Ver.zip")"

<#
# Optional: bundle the three services + launcher into a single native .exe.
# Requires: pip install pyinstaller. Then uncomment:
#
#   pyinstaller --onefile --name nexusai-backend `
#     --paths (Join-Path $Backend ".") `
#     (Join-Path $Backend "start_backend.py")
#   Copy-Item ".\dist\nexusai-backend.exe" (Join-Path $Dist "nexusai-backend.exe")
#>
