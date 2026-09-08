# Nexus AI

Local-first AI companion for macOS. SwiftUI client with an on-device LLM,
research with evidence and confidence scoring, typed `/commands`, a golden
eval suite, memory, brain/intent, speech, image/audio/video generation, task
graph automation, hacking harnesses and a portable Python backend.

- **Client:** macOS 13+ (universal: Apple Silicon + Intel)
- **Backend:** pure-standard-library Python 3.9+ — portable to macOS, Linux,
  Windows

## Layout

```
NexusAI/              SwiftUI app (Models, Services, Views)
NexusAI.xcodeproj/    Xcode project (deployment target macOS 13.0)
Tests/                unit-test harnesses (15) + runner
installers/           per-OS installers + portable backend package
scripts/              local build scripts (macOS + Linux + Windows)
.github/workflows/    GitHub Actions: mac/Linux/Windows builds + releases
dist/                 build output (gitignored)
```

## Build

```sh
scripts/make_installers.sh        # macOS: universal app + DMG + ZIP + backend zip
scripts/build_linux.sh            # Linux: portable backend zip   (run on a Linux box/CI)
scripts/build_windows.ps1         # Windows: portable backend zip (run on Windows/CI)
./Tests/run_unit_tests.sh         # 15 harnesses
xcodebuild -project NexusAI.xcodeproj -scheme NexusAI -destination 'platform=macOS' test
```

## Verify

```sh
./Tests/run_unit_tests.sh                                   # all harnesses pass
xcodebuild -project NexusAI.xcodeproj -scheme NexusAI -destination 'platform=macOS' test
file dist/NexusAI.app/Contents/MacOS/NexusAI                # universal binary
codesign -d --entitlements - dist/NexusAI.app               # no get-task-allow
python3 installers/backend/start_backend.py                 # boots 3 sidecars on :8765-8767
NEXIE_LLM_BASE=http://127.0.0.1:8080/v1 \
    python3 installers/backend/start_backend.py             # point at any OpenAI-compatible LLM
```

## GitHub Releases

Tag a release (`git tag v1.1 && git push --tags`); the `build` workflow compiles
on macOS, Ubuntu and Windows runners and publishes a GitHub Release with:

- `NexusAI-macOS-universal.dmg` / `.zip` / `.pkg`
- `NexusAI-backend-Linux.zip`, `NexusAI-backend-Windows.zip`

The SwiftUI client is AppKit-bound and therefore macOS-only; the backend is the
cross-platform half and runs anywhere with stock Python 3.9+.