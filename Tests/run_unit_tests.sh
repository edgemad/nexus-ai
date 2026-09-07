#!/bin/bash
# Nexie unit-test harness runner.
#
# Verifies Phase 1 reliability & safety behavior against the REAL app sources
# (not a fixture copy): durable stores, event-driven approvals, and hardened
# shell execution. Compiled with the system swiftc (Command Line Tools), so it
# runs anywhere without Xcode provisioning.
#
# Usage:  ./Tests/run_unit_tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/NexusAI"
HARNESS="$ROOT/Tests/harness"
BUILD="$ROOT/Tests/build"
SWIFTC="/usr/bin/swiftc"
mkdir -p "$BUILD"

failures=0

# harness_name source_file [extra_sources...]
run_harness() {
    local name="$1"; shift
    local bin="$BUILD/$name.bin"
    echo "== $name =="
    if ! "$SWIFTC" -O -o "$bin" "$HARNESS/$name.swift" "$@" 2>"$BUILD/$name.compile.log"; then
        echo "compile failed (see $BUILD/$name.compile.log)"
        failures=$((failures + 1))
        return
    fi
    if ! "$bin"; then
        failures=$((failures + 1))
    fi
}

# Persistence: atomic writes, corrupt/future-schema/missing handling,
# per-file migrations, legacy (v0) recovery.
run_harness PersistenceHarness \
    "$HARNESS/WorkspaceManagerStub.swift" \
    "$SRC/Services/PersistenceController.swift" \
    "$SRC/Services/ModelMigrations.swift" \
    "$SRC/Services/NexusError.swift" \
    "$SRC/Services/Diagnostics.swift"

# Stores + event-driven approvals: add/decide/expiry streams keyed by approval
# ID, status persistence, AgentAction Codable round trip, tasks/activity/automation.
run_harness StoreHarness \
    "$HARNESS/WorkspaceManagerStub.swift" \
    "$SRC/Services/PersistenceController.swift" \
    "$SRC/Services/ModelMigrations.swift" \
    "$SRC/Services/NexusError.swift" \
    "$SRC/Services/Diagnostics.swift" \
    "$SRC/Services/AssistantSettings.swift" \
    "$SRC/Models/AgentAction.swift" \
    "$SRC/Models/ApprovalStore.swift" \
    "$SRC/Models/ActivityStore.swift" \
    "$SRC/Models/AutomationStore.swift" \
    "$SRC/Models/TaskStore.swift"

# Shell: capture, stderr, fixed cwd, env scrubbing, blocklist + curated bypass,
# output cap, timeout, cancellation, pre-start cancel, PATH functionality.
run_harness ShellHarness \
    "$SRC/Services/NexusError.swift" \
    "$SRC/Services/ShellRunner.swift"

# Backups: rolling snapshots, checksum verify, tamper detection, restore +
# rollback, retention pruning, deletion, restore-then-migrate.
run_harness BackupHarness \
    "$HARNESS/WorkspaceManagerStub.swift" \
    "$SRC/Services/PersistenceController.swift" \
    "$SRC/Services/ModelMigrations.swift" \
    "$SRC/Services/NexusError.swift" \
    "$SRC/Services/Diagnostics.swift" \
    "$SRC/Services/AssistantSettings.swift" \
    "$SRC/Models/ActivityStore.swift" \
    "$SRC/Services/BackupManager.swift"

# Diagnostics: ring log + rotation, persisted reliability stats + crash
# detection, notification counters, export, concurrent logging from threads.
run_harness DiagnosticsHarness \
    "$SRC/Services/NexusError.swift" \
    "$SRC/Services/Diagnostics.swift"

# UpdateManager: version comparison, manifest decode/availability, upgrade
# detection ritual (backup + snapshot verify + What's New), no-repeat launches.
run_harness UpdateHarness \
    "$SRC/Services/NexusError.swift" \
    "$SRC/Services/Diagnostics.swift" \
    "$SRC/Services/UpdateManager.swift"

# Security: persistent command allowlist (+ ShellRunner blocklist bypass),
# secret redaction for exports, output retention + quota trimming.
run_harness SecurityHarness \
    "$SRC/Services/NexusError.swift" \
    "$SRC/Services/ShellRunner.swift" \
    "$SRC/Services/CommandAllowlist.swift" \
    "$SRC/Services/SecretRedactor.swift" \
    "$SRC/Services/DataTrim.swift"

# Secrets: Keychain-backed storage + legacy UserDefaults migration (in-memory
# backend so the CLI harness needs no Keychain session).
run_harness SecretHarness \
    "$SRC/Services/SecretStore.swift"

# Music: zero-model fast generator (WAV synthesis across moods/complexities),
# procedural cover art, and the full Ken Burns video pipeline (audio+cover).
run_harness MusicHarness \
    "$SRC/Services/AudioMixer.swift" \
    "$SRC/Services/TempMediaCache.swift" \
    "$SRC/Services/FastMusicGenerator.swift" \
    "$SRC/Services/MusicPackCoordinator.swift"

# Tools: typed read-only tools (validation, native list/read/search) — no shell.
run_harness ToolsHarness \
    "$SRC/Services/NexusError.swift" \
    "$SRC/Services/ShellRunner.swift" \
    "$SRC/Services/ReadOnlyTools.swift"

# TaskGraph: pure DAG scheduler (cycle detection, dep resolution, readiness
# ordering, edge sketches) — engine execution is exercised via the app build.
run_harness TaskGraphHarness \
    "$SRC/Models/TaskGraph.swift"

# Evidence (Phase 9): citation parsing/tracing, the deterministic confidence
# formula, evidence Codable round-trips, and old-chat backward compatibility.
run_harness EvidenceHarness \
    "$SRC/Models/ResearchEvidence.swift" \
    "$SRC/Services/ChatEngine.swift"

# Capability (Phase 10): feature-flag scoring table, routing/thresholding,
# fallback order, and sidecar version/capability negotiation.
run_harness CapabilityHarness \
    "$SRC/Services/CapabilityRouter.swift"

# Command (Phase 11): typed chat command parser, arg validation, usage errors,
# and the safe arithmetic evaluator powering /compute.
run_harness CommandHarness \
    "$SRC/Models/ChatCommand.swift"

# Eval (Phase 11): deterministic scorer, golden-suite integrity, board
# aggregation, and a fake-completion eval loop.
run_harness EvalHarness \
    "$SRC/Models/Eval.swift"

echo
if [ "$failures" -eq 0 ]; then
    echo "ALL UNIT HARNESSES PASSED"
    exit 0
else
    echo "$failures HARNESS RUN(S) FAILED"
    exit 1
fi