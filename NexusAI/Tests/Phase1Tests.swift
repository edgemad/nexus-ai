import XCTest

/// Phase 1/2 reliability & safety behavior, exercised against the real sources
/// compiled directly into this test bundle (a throwaway temp data dir).
/// Mirrors the CLI harnesses in Tests/run_unit_tests.sh.

@MainActor
final class PersistenceTests: XCTestCase {
    private var ctrl: PersistenceController { PersistenceController.shared }

    override func setUp() async throws {
        // Isolate every test from prior runs.
        let url = ctrl.dataURL
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func testRoundTrip() {
        struct Sample: Codable, Equatable { var id = UUID(); var name: String; var count: Int }
        let v = [Sample(name: "one", count: 1), Sample(name: "two", count: 2)]
        ctrl.save(v, file: "t_rt")
        XCTAssertEqual(ctrl.load([Sample].self, file: "t_rt"), v)
    }

    func testOverwrite() {
        struct Sample: Codable, Equatable { var id = UUID(); var name: String }
        ctrl.save([Sample(name: "a")], file: "t_ow")
        ctrl.save([Sample(name: "b")], file: "t_ow")
        XCTAssertEqual(ctrl.load([Sample].self, file: "t_ow")?.first?.name, "b")
    }

    func testCorruptIsNil() throws {
        struct Sample: Codable { var name: String }
        try Data("not json".utf8).write(to: ctrl.url(for: "t_c"))
        XCTAssertNil(ctrl.load([Sample].self, file: "t_c"))
    }

    func testFutureSchemaIgnored() throws {
        struct Sample: Codable { var name: String }
        let env = PersistenceEnvelope(schemaVersion: 999, savedAt: Date(), payload: [Sample(name: "x")])
        try JSONEncoder().encode(env).write(to: ctrl.url(for: "t_f"))
        XCTAssertNil(ctrl.load([Sample].self, file: "t_f"))
    }

    func testMissingIsNil() {
        struct Sample: Codable { var name: String }
        XCTAssertNil(ctrl.load([Sample].self, file: "t_missing"))
    }

    func testMigrationFramework() throws {
        struct Migrated: Codable, Equatable { var id = UUID(); var name: String }
        let v0Envelope: [String: Any] = [
            "schemaVersion": 0,
            "savedAt": Date().timeIntervalSince1970,
            "payload": ["id": UUID().uuidString, "oldKey": "legacy"]
        ]
        try JSONSerialization.data(withJSONObject: v0Envelope).write(to: ctrl.url(for: "t_mig"))
        ctrl.registerMigration(fromVersion: 0, for: "t_mig") { payloadData in
            guard var obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }
            obj["name"] = obj.removeValue(forKey: "oldKey")
            return try? JSONSerialization.data(withJSONObject: obj)
        }
        ctrl.registerMigration(fromVersion: 1, for: "t_mig") { $0 }
        let migrated = ctrl.loadOrMigrate(Migrated.self, file: "t_mig")
        XCTAssertEqual(migrated?.name, "legacy")
        // Rewritten at current schema: a plain load now reads it.
        XCTAssertEqual(ctrl.load(Migrated.self, file: "t_mig"), migrated)
    }

    func testLegacyV0Recovery() throws {
        struct Legacy: Codable, Equatable { let name: String }
        let raw: [[String: Any]] = [["name": "pre-envelope"]]
        try JSONSerialization.data(withJSONObject: raw).write(to: ctrl.url(for: "t_legacy"))
        ctrl.registerMigration(fromVersion: 0, for: "t_legacy") { $0 }
        ctrl.registerMigration(fromVersion: 1, for: "t_legacy") { $0 }
        XCTAssertEqual(ctrl.loadOrMigrate([Legacy].self, file: "t_legacy"),
                       [Legacy(name: "pre-envelope")])
        let back = try JSONSerialization.jsonObject(with: Data(contentsOf: ctrl.url(for: "t_legacy")))
        XCTAssertEqual((back as? [String: Any])?["schemaVersion"] as? Int,
                       PersistenceController.currentSchemaVersion)
    }

    func testPerFileMigrationsAreIsolated() throws {
        struct Tagged: Codable, Equatable { var tag: String }
        ctrl.registerMigration(fromVersion: 1, for: "t_iso_a") { data in
            try? JSONSerialization.data(withJSONObject: Self.stamped(data, "A"))
        }
        ctrl.registerMigration(fromVersion: 1, for: "t_iso_b") { data in
            try? JSONSerialization.data(withJSONObject: Self.stamped(data, "B"))
        }
        for fn in ["t_iso_a", "t_iso_b"] {
            let v1: [String: Any] = ["schemaVersion": 1, "savedAt": Date().timeIntervalSince1970,
                                     "payload": [["tag": "plain"]]]
            try JSONSerialization.data(withJSONObject: v1).write(to: ctrl.url(for: fn))
        }
        XCTAssertEqual(ctrl.loadOrMigrate([Tagged].self, file: "t_iso_a")?.first?.tag, "A")
        XCTAssertEqual(ctrl.loadOrMigrate([Tagged].self, file: "t_iso_b")?.first?.tag, "B")
    }

    private static func stamped(_ data: Data, _ mark: String) -> Any {
        guard var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return data }
        for i in arr.indices { arr[i]["tag"] = mark }
        return arr
    }

    func testMissingMigrationIsNil() throws {
        struct Migrated: Codable { var name: String }
        let v5Envelope: [String: Any] = ["schemaVersion": 5, "savedAt": Date().timeIntervalSince1970,
                                         "payload": ["oldKey": "legacy"]]
        try JSONSerialization.data(withJSONObject: v5Envelope).write(to: ctrl.url(for: "t_mig2"))
        XCTAssertNil(ctrl.loadOrMigrate(Migrated.self, file: "t_mig2")) // no migration registered for v5
    }
}

@MainActor
final class StoreTests: XCTestCase {
    private var ctrl: PersistenceController { PersistenceController.shared }

    override func setUp() async throws {
        let url = ctrl.dataURL
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func testActivityRestoresColor() {
        let a = ActivityStore()
        a.log(icon: "test", title: "t", detail: "d", color: .purple)
        let a2 = ActivityStore()
        XCTAssertEqual(a2.events.count, 1)
        XCTAssertEqual(a2.events[0].colorName, "purple")
    }

    func testApprovalRestoreKeepsNoClosures() throws {
        let ap = ApprovalStore()
        let apID = ap.add(title: "t", detail: "d")
        let raw = try String(contentsOf: ctrl.url(for: "approvals"), encoding: .utf8)
        XCTAssertFalse(raw.contains("onDecision"))
        let ap2 = ApprovalStore()
        XCTAssertEqual(ap2.items.first?.id, apID)
    }

    func testDecisionEventFiresByID() {
        let ap = ApprovalStore()
        let apID = ap.add(title: "t", detail: "d")
        var events: [(UUID, Bool)] = []
        let token = ap.subscribe { id, allow in events.append((id, allow)) }
        ap.decide(approvalID: apID, allow: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, apID)
        XCTAssertTrue(events[0].1)
        withExtendedLifetime(token, {})
    }

    func testDecisionStatusPersists() {
        let ap = ApprovalStore()
        let id = ap.add(title: "t", detail: "d")
        ap.decide(approvalID: id, allow: true)
        let ap2 = ApprovalStore()
        XCTAssertEqual(ap2.items.first?.status, .approved)
    }

    func testStreamIsIDKeyed() {
        let ap = ApprovalStore()
        let ev: [(UUID, Bool)] = []
        let token = ap.subscribe { _, _ in }
        _ = ev
        _ = token
        let id = ap.add(title: "t", detail: "d")
        ap.decide(approvalID: id, allow: false)
        XCTAssertEqual(ap.items.first?.status, .denied)
    }

    func testHistoryRecordsAndRestores() {
        let ap = ApprovalStore()
        let id = ap.add(title: "t", detail: "d")
        ap.decide(approvalID: id, allow: true)
        XCTAssertEqual(ap.history.first?.verdict, .approved)
        let ap2 = ApprovalStore()
        XCTAssertEqual(ap2.history.count, 1)
        XCTAssertEqual(ap2.history.first?.approvalID, id)
    }

    func testExpiryDeniesAndRecords() {
        let ap = ApprovalStore()
        var fired = false
        let token = ap.subscribe { _, allow in fired = !allow }
        let expired = ApprovalItem(title: "e", detail: "d", icon: "gear",
                                   requestedAt: Date().addingTimeInterval(-700),
                                   status: .pending,
                                   expiresAt: Date().addingTimeInterval(-60))
        ap.items.insert(expired, at: 0)
        ap.sweepExpired()
        XCTAssertEqual(ap.items[0].status, .denied)
        XCTAssertTrue(fired)
        XCTAssertEqual(ap.history.first?.verdict, .expired)
        withExtendedLifetime(token, {})
    }

    func testAutomationRoundTrip() {
        let au = AutomationStore()
        au.add(name: "x", schedule: "Every 1 hour")
        let au2 = AutomationStore()
        XCTAssertEqual(au2.automations.count, 1)
        XCTAssertEqual(au2.automations[0].name, "x")
    }

    func testTaskMidFlightRestore() {
        let t = TaskStore()
        let task = t.create(title: "task", steps: ["a", "b"], requiresApproval: true)
        XCTAssertEqual(task.status, .waitingForApproval)
        t.start(task.id)
        let t2 = TaskStore()
        XCTAssertEqual(t2.tasks.count, 1)
        XCTAssertEqual(t2.tasks[0].status, .running)
    }

    func testAgentActionCodableRoundTrip() {
        let a1 = AgentAction(kind: .runCommand, command: "ls", fromMessageID: UUID(),
                             approvalID: UUID(), result: nil, status: .pending)
        let a2 = AgentAction(kind: .openURL, command: "https://x", fromMessageID: UUID(),
                             approvalID: nil, result: "done", status: .done)
        let saved = [a1, a2]
        ctrl.save(saved, file: "t_actions")
        let restored = ctrl.load([AgentAction].self, file: "t_actions") ?? []
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].status, .pending)
        XCTAssertEqual(restored[1].status, .done)
    }

    func testLegacyActivityRecovery() {
        let event = ActivityEvent(date: Date(), icon: "test", title: "old", detail: "d", color: .purple)
        let envelope = PersistenceEnvelope(schemaVersion: 1, savedAt: Date(), payload: [event])
        let dict = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as! [String: Any]
        let rawPayload = dict["payload"]!
        // Strip the envelope: this is the pre-envelope on-disk form.
        try! JSONSerialization.data(withJSONObject: rawPayload).write(to: ctrl.url(for: "activity"))
        let store = ActivityStore()
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].title, "old")
        XCTAssertEqual(store.events[0].colorName, "purple")
    }

    func testV1RepairAddsModelDefaults() {
        let evDict: [String: Any] = [
            "id": UUID().uuidString,
            "date": Date().timeIntervalSinceReferenceDate,
            "icon": "gear",
            "title": "old",
            "detail": "d",
        ] // no "colorName" → must be backfilled by the v1→v2 chain.
        let v1: [String: Any] = ["schemaVersion": 1, "savedAt": Date().timeIntervalSince1970,
                                 "payload": [evDict]]
        try! JSONSerialization.data(withJSONObject: v1).write(to: ctrl.url(for: "activity"))
        let store = ActivityStore()
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].colorName, "blue")
    }
}

@MainActor
final class BackupTests: XCTestCase {
    private var backups: BackupManager { BackupManager.shared }

    override func setUp() async throws {
        let fm = FileManager.default
        let root = WorkspaceManager.shared.rootURL
        for name in ["Data", "Backups"] {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: url)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        backups.retention = 8
        backups.lastError = nil
    }

    func testSnapshotCapturesStoresAndVerifies() {
        struct S: Codable, Equatable { var name: String }
        PersistenceController.shared.save([S(name: "a"), S(name: "b")], file: "bk_t")
        XCTAssertTrue(backups.backupNow(force: true))
        XCTAssertEqual(backups.snapshots.count, 1)
        let snap = try! XCTUnwrap(backups.snapshots.first)
        XCTAssertEqual(snap.fileCount, 1)
        XCTAssertTrue(backups.verify(snapshot: snap))
        XCTAssertNotNil(backups.lastBackup)
    }

    func testTamperDetectedAndRestoreRefused() {
        struct S: Codable { var name: String }
        let controller = PersistenceController.shared
        controller.save([S(name: "good")], file: "bk_tamper")
        XCTAssertTrue(backups.backupNow(force: true))
        let snap = backups.snapshots[0]
        let file = controller.url(for: "bk_tamper")

        // Corrupting live data is repaired by a restore from the intact snapshot.
        try! Data("corrupted".utf8).write(to: file, options: .atomic)
        XCTAssertTrue(backups.restore(from: snap))
        XCTAssertNotNil(controller.load([S].self, file: "bk_tamper"))

        // Corrupting the SNAPSHOT itself trips the integrity gate: verify fails
        // and restore is refused, leaving the live file untouched.
        let snapshotCopy = WorkspaceManager.shared.rootURL
            .appendingPathComponent("Backups")
            .appendingPathComponent(snap.dirName)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("bk_tamper.json")
        try! Data("tampered-snapshot".utf8).write(to: snapshotCopy, options: .atomic)
        XCTAssertFalse(backups.verify(snapshot: snap))
        XCTAssertFalse(backups.restore(from: snap))
        let liveAfterRefused = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertTrue(liveAfterRefused.contains("schemaVersion"))
    }

    func testRestoreRollsBackExtraFiles() {
        struct S: Codable { var name: String }
        PersistenceController.shared.save([S(name: "x")], file: "bk_keep")
        XCTAssertTrue(backups.backupNow(force: true))
        let snap = backups.snapshots[0]
        PersistenceController.shared.save([S(name: "y")], file: "bk_extra")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: PersistenceController.shared.url(for: "bk_extra").path))
        XCTAssertTrue(backups.restore(from: snap))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PersistenceController.shared.url(for: "bk_extra").path))
        XCTAssertNotNil(PersistenceController.shared.load([S].self, file: "bk_keep"))
    }

    func testRetentionKeepsNewestOnly() {
        struct S: Codable { var name: String }
        backups.retention = 2
        PersistenceController.shared.save([S(name: "1")], file: "bk_r")
        XCTAssertTrue(backups.backupNow(force: true))
        PersistenceController.shared.save([S(name: "2")], file: "bk_r")
        XCTAssertTrue(backups.backupNow(force: true))
        PersistenceController.shared.save([S(name: "3")], file: "bk_r")
        XCTAssertTrue(backups.backupNow(force: true))
        XCTAssertEqual(backups.snapshots.count, 3)
        backups.prune()
        XCTAssertEqual(backups.snapshots.count, 2)
    }

    func testRestoreThenMigrate() {
        // A v1-era snapshot (activity events without `colorName`) must boot
        // cleanly after restore: the v1→v2 chain backfills and re-saves.
        let evDict: [String: Any] = [
            "id": UUID().uuidString,
            "date": Date().timeIntervalSinceReferenceDate,
            "icon": "gear",
            "title": "old-era event",
            "detail": "d",
        ]
        let v1: [String: Any] = ["schemaVersion": 1, "savedAt": Date().timeIntervalSince1970,
                                 "payload": [evDict]]
        let activityURL = PersistenceController.shared.url(for: "activity")
        try! JSONSerialization.data(withJSONObject: v1).write(to: activityURL)
        XCTAssertTrue(backups.backupNow(force: true))
        let snap = backups.snapshots[0]

        try? FileManager.default.removeItem(at: activityURL)
        XCTAssertTrue(backups.restore(from: snap))

        let store = ActivityStore()
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].title, "old-era event")
        XCTAssertEqual(store.events[0].colorName, "blue")
        let onDisk = try! JSONSerialization.jsonObject(with: Data(contentsOf: activityURL)) as! [String: Any]
        XCTAssertEqual(onDisk["schemaVersion"] as? Int, PersistenceController.currentSchemaVersion)
    }
}

@MainActor
final class DiagnosticsTests: XCTestCase {
    private func freshDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NexieTests\(UUID().uuidString)", isDirectory: true)
    }
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "NexieTests-\(UUID().uuidString)")!
    }
    private func pump(_ cond: @escaping @MainActor () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    func testRingAndFile() {
        let diag = Diagnostics(directory: freshDir(), defaults: freshDefaults(), ring: 60)
        for i in 0..<80 { diag.record(.debug, source: "x", "e\(i)") }
        XCTAssertEqual(diag.events.count, 60)
        XCTAssertTrue(diag.events[0].message.hasPrefix("e20"))
        let text = (try? String(contentsOf: diag.logFileURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("e79"))
    }

    func testRotation() {
        let dir = freshDir()
        let diag = Diagnostics(directory: dir, defaults: freshDefaults())
        for _ in 0..<80 { diag.record(.debug, source: "bulk", String(repeating: "a", count: 4096)) }
        sleep(1)
        let current = (try? diag.logFileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        XCTAssertLessThanOrEqual(current, Diagnostics.rotationBytes + 4096)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("nexie-1.log").path))
    }

    func testCrashDetectionAndRelaunch() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: Diagnostics.persistKey + ".cleanExit")
        let first = Diagnostics(directory: freshDir(), defaults: defaults)
        first.beginSession()
        XCTAssertEqual(first.stats.launches, 1)
        XCTAssertEqual(first.stats.crashes, 1)
        first.markCleanExit()
        let second = Diagnostics(directory: freshDir(), defaults: defaults)
        second.beginSession()
        XCTAssertEqual(second.stats.launches, 2)
        XCTAssertEqual(second.stats.crashes, 1)
    }

    func testNotificationCounters() {
        let diag = Diagnostics(directory: freshDir(), defaults: freshDefaults())
        diag.beginSession()
        NotificationCenter.default.post(name: .nexieCommandEvent, object: nil, userInfo: ["type": "blocked"])
        NotificationCenter.default.post(name: .nexieBackupEvent, object: nil, userInfo: ["event": "backup"])
        NotificationCenter.default.post(name: .nexieMigrationEvent, object: nil, userInfo: ["file": "tasks"])
        XCTAssertTrue(pump {
            diag.stats.blockedCommands == 1 && diag.stats.backups == 1 && diag.stats.migrations == 1
        })
    }

    func testExportBundle() {
        let diag = Diagnostics(directory: freshDir(), defaults: freshDefaults())
        diag.beginSession()
        diag.record(.warn, source: "shell", "blocked a destructive command")
        guard let url = diag.export(to: freshDir(), sidecars: ["research": true]) else {
            return XCTFail("export returned nil")
        }
        let obj = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual((obj["stats"] as? [String: Any])?["launches"] as? Int, 1)
        let events = obj["events"] as? [[String: Any]] ?? []
        XCTAssertTrue(events.contains { ($0["source"] as? String) == "shell" })
        XCTAssertEqual((obj["sidecars"] as? [String: Any])?["research"] as? Bool, true)
    }
}

final class ShellTests: XCTestCase {
    func testCaptureStdout() {
        let r = ShellRunner.runBlocking("echo hello-world")
        XCTAssertEqual(r.text.trimmingCharacters(in: .whitespacesAndNewlines), "hello-world")
        XCTAssertFalse(r.failed)
        XCTAssertFalse(r.wasCancelled)
    }

    func testFailureCapturesStderr() {
        let r = ShellRunner.runBlocking("echo boom 1>&2; exit 3")
        XCTAssertTrue(r.failed)
        XCTAssertTrue(r.text.contains("boom"))
    }

    func testFixedWorkingDirectory() {
        let r = ShellRunner.runBlocking("pwd")
        XCTAssertEqual(r.text.trimmingCharacters(in: .whitespacesAndNewlines),
                       ShellRunner.workspaceDirectoryURL.path)
    }

    func testEnvScrubbed() {
        let r = ShellRunner.runBlocking("echo \"${MY_SECRET:-UNSET}\"")
        XCTAssertEqual(r.text.trimmingCharacters(in: .whitespacesAndNewlines), "UNSET")
    }

    func testDestructiveBlocked() {
        let r = ShellRunner.runBlocking("rm -rf /tmp/whatever")
        XCTAssertTrue(r.failed)
        XCTAssertTrue(r.text.contains("Blocked"))
    }

    func testCuratedBypassRuns() {
        let cmd = "rm -rf /tmp/nexie-test-xyz"
        let r = ShellRunner.runBlocking(cmd, curated: Set([cmd]))
        XCTAssertFalse(r.text.contains("Blocked"))
    }

    func testUnknownCommandStillBlocked() {
        let cmd = "rm -rf /tmp/nexie-test-xyz"
        let r = ShellRunner.runBlocking(cmd, curated: Set(["other"]))
        XCTAssertTrue(r.text.contains("Blocked"))
    }

    func testOutputCapped() {
        let r = ShellRunner.runBlocking("python3 -c \"print('abcdef'*10_000)\"")
        XCTAssertLessThanOrEqual(r.text.count, ShellRunner.outputCharCap + 32)
        XCTAssertTrue(r.text.contains("truncated"))
    }

    func testTimeoutKillsCommand() {
        let start = Date()
        let r = ShellRunner.runBlocking("/bin/sleep 30", timeout: 1.0)
        XCTAssertTrue(r.failed)
        XCTAssertTrue(r.text.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testCancellationInterrupts() async {
        let sid = UUID()
        let cancelTask = Task.detached {
            try? await Task.sleep(nanoseconds: 500_000_000)
            ShellRunner.cancel(sid)
        }
        let r = ShellRunner.runBlocking("/bin/sleep 30", id: sid)
        _ = await cancelTask.value
        XCTAssertTrue(r.wasCancelled)
    }

    func testPreStartCancelShortCircuits() {
        let preID = UUID()
        _ = ShellRunner.cancel(preID)
        let r = ShellRunner.runBlocking("echo never", id: preID)
        XCTAssertTrue(r.wasCancelled)
    }

    func testPATHWorksScrubbed() {
        let r = ShellRunner.runBlocking("command -v /bin/ls")
        XCTAssertFalse(r.failed)
        XCTAssertTrue(r.text.contains("/bin/ls"))
    }
}

@MainActor
final class UpdateTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(VersionCompare.isGreater("1.10", than: "1.9"))
        XCTAssertFalse(VersionCompare.isGreater("1.1", than: "1.10"))
        XCTAssertTrue(VersionCompare.isGreater("2.0.0", than: "1.9.9"))
        XCTAssertFalse(VersionCompare.isGreater("1.5", than: "1.5"))
        XCTAssertTrue(VersionCompare.isAtLeast("1.10", minimum: "1.9"))
        XCTAssertFalse(VersionCompare.isAtLeast("1.4", minimum: "1.5"))
    }

    func testDiscoversUpdateFromManifest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent("UpdateManifest.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = UpdateManifest(version: "1.1", minimumVersion: "1.0",
                                      releasedAt: Date(), releaseNotes: ["New", "Shiny"])
        try encoder.encode(manifest).write(to: manifestURL)

        let suite = "UpdateTests.defaults"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!

        let um = UpdateManager(manifestFile: manifestURL, defaults: defaults, currentVersion: "1.0")
        XCTAssertTrue(um.checkForUpdates())
        XCTAssertEqual(um.latestVersion, "1.1")
        XCTAssertFalse(um.isCriticalUpdate)

        let below = UpdateManager(manifestFile: manifestURL, defaults: defaults, currentVersion: "0.9")
        _ = below.checkForUpdates()
        XCTAssertTrue(below.isCriticalUpdate)

        try? FileManager.default.removeItem(at: dir)
    }

    func testUpgradeRitualFiresOncePerVersion() async {
        let suite = "UpdateTests.ritual"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("1.0", forKey: UpdateManager.lastRunKey)

        let um = UpdateManager(manifestFile: URL(fileURLWithPath: "/nonexistent.json"),
                               defaults: defaults, currentVersion: "1.1")
        var upgrades = 0
        var verified = false
        um.onUpgraded = { upgrades += 1 }
        um.onVerifySnapshot = { verified = true; return true }

        um.begin()
        XCTAssertEqual(upgrades, 1)
        XCTAssertTrue(verified)
        XCTAssertEqual(um.lastUpgrade?.to, "1.1")

        um.begin()
        XCTAssertEqual(upgrades, 1, "ritual must not repeat on same-version launch")
        XCTAssertEqual(defaults.string(forKey: UpdateManager.lastRunKey), "1.1")
    }
}

@MainActor
final class SecurityTests: XCTestCase {
    private let allowlistSuite = "SecurityTests.allowlist"

    override func setUp() {
        UserDefaults.standard.removePersistentDomain(forName: allowlistSuite)
        CommandAllowlist.defaults = UserDefaults(suiteName: allowlistSuite)!
        CommandAllowlist.clear()
    }

    func testAllowlistPersistsAndEdits() {
        XCTAssertTrue(CommandAllowlist.add("sh maintenance.sh"))
        XCTAssertTrue(CommandAllowlist.allows("sh maintenance.sh"))
        XCTAssertFalse(CommandAllowlist.add("sh maintenance.sh"), "duplicates rejected")
        XCTAssertTrue(CommandAllowlist.remove("sh maintenance.sh"))
        XCTAssertFalse(CommandAllowlist.allows("sh maintenance.sh"))
    }

    func testAllowlistOverridesShellBlocklist() {
        // ShellRunner reads the real UserDefaults key; test it round-trips.
        let realKey = ShellRunner.allowlistStorageKey
        UserDefaults.standard.removeObject(forKey: realKey)
        defer { UserDefaults.standard.removeObject(forKey: realKey) }

        XCTAssertTrue(ShellRunner.isDestructive("rm -rf /tmp/a", curated: []))
        UserDefaults.standard.set(["rm -rf /tmp/a"], forKey: realKey)
        XCTAssertFalse(ShellRunner.isDestructive("rm -rf /tmp/a", curated: []))
    }

    func testRedactorMasksSecrets() {
        let jwt = "token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.asdf"
        XCTAssertFalse(SecretRedactor.redact(jwt).contains("eyJ"))
        XCTAssertFalse(SecretRedactor.redact("api_key=sk-abc123def456ghi789").contains("sk-abc123"))
        XCTAssertFalse(SecretRedactor.redact("reach me at alice@example.com").contains("alice@example.com"))
        XCTAssertEqual(SecretRedactor.redact("Hello world"), "Hello world")
    }

    func testDataTrimRemovesOldOutputs() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SecurityTests-\(UUID())")
        let outputs = root.appendingPathComponent("Outputs")
        try fm.createDirectory(at: outputs, withIntermediateDirectories: true)

        let old = outputs.appendingPathComponent("2026-01-01 00.00.00")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 500).write(to: old.appendingPathComponent("f.txt"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86400)], ofItemAtPath: old.path)

        let fresh = outputs.appendingPathComponent("2026-09-01 00.00.00")
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 800).write(to: fresh.appendingPathComponent("f.txt"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: fresh.path)

        UserDefaults.standard.set(30, forKey: DataTrim.retentionDaysKey)
        defer { UserDefaults.standard.removeObject(forKey: DataTrim.retentionDaysKey) }

        let report = DataTrim.trim(at: root)
        XCTAssertEqual(report.itemsRemoved, 1)
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        try? fm.removeItem(at: root)
    }

    func testApprovalTTLOverride() {
        // Default TTL applies, then a UserDefaults override shortens it.
        UserDefaults.standard.removeObject(forKey: "approval.ttlSeconds")
        XCTAssertEqual(ApprovalStore.ttlSeconds, ApprovalStore.kApprovalTimeout)
        UserDefaults.standard.set(30, forKey: "approval.ttlSeconds")
        defer { UserDefaults.standard.removeObject(forKey: "approval.ttlSeconds") }
        XCTAssertEqual(ApprovalStore.ttlSeconds, 30)

        let store = ApprovalStore()
        let item = store.add(title: "ttl", detail: "d")
        let approval = store.items.first { $0.id == item }
        XCTAssertNotNil(approval)
        let window = approval!.expiresAt.timeIntervalSinceNow
        XCTAssertGreaterThan(window, 0)
        XCTAssertLessThanOrEqual(window, 35)
    }
}

/// In-memory SecretBackend for deterministic tests of secret handling.
final class MemorySecretBackend: SecretBackend {
    var storage: [String: String] = [:]
    func save(_ value: String, for key: String) throws { storage[key] = value }
    func read(_ key: String) throws -> String? { storage[key] }
    func delete(_ key: String) throws { storage[key] = nil }
}

@MainActor
final class SecretStoreTests: XCTestCase {
    override func setUp() {
        SecretStore.backend = MemorySecretBackend()
    }

    func testRoundTripAndDelete() throws {
        try SecretStore.save("sk-test-123", for: "alpha")
        XCTAssertEqual(try SecretStore.read("alpha"), "sk-test-123")
        try SecretStore.delete("alpha")
        XCTAssertNil(try SecretStore.read("alpha"))
    }

    func testOverwriteReplacesValue() throws {
        try SecretStore.save("first", for: "k")
        try SecretStore.save("second", for: "k")
        XCTAssertEqual(try SecretStore.read("k"), "second")
    }

    func testMigrationPullsFromUserDefaults() {
        let suite = "SecretStoreTests.migration"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("legacy-key", forKey: "miniMaxH3ApiKey")

        let migrated = SecretStore.migrateLegacyIfNeeded("miniMaxH3ApiKey", defaults: defaults)
        XCTAssertEqual(migrated, "legacy-key")
        XCTAssertEqual(try? SecretStore.read("miniMaxH3ApiKey"), "legacy-key")
        XCTAssertNil(defaults.string(forKey: "miniMaxH3ApiKey"), "plaintext copy must be cleared")
    }

    func testMigrationNoOpWhenAlreadyKeychain() throws {
        let suite = "SecretStoreTests.migration2"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        try SecretStore.save("in-keychain", for: "k2")
        defaults.set("legacy", forKey: "k2")

        XCTAssertEqual(SecretStore.migrateLegacyIfNeeded("k2", defaults: defaults), "in-keychain")
        XCTAssertEqual(defaults.string(forKey: "k2"), "legacy", "already-migrated key untouched")
    }
}

final class NexusErrorTests: XCTestCase {
    func testTypedErrorCodableRoundTrip() throws {
        let error = NexusError(.sidecarUnavailable, "research sidecar not responding",
                               retryable: true, requestID: RequestID.make(prefix: "research"))
        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(NexusError.self, from: data)
        XCTAssertEqual(decoded, error)
        XCTAssertEqual(decoded.code, .sidecarUnavailable)
        XCTAssertTrue(decoded.retryable)
    }

    func testShellResultCarriesErrorCodeAndRequestID() {
        let r = ShellRunner.runBlocking("rm -rf /nope", curated: [])
        XCTAssertTrue(r.failed)
        XCTAssertEqual(r.errorCode, .toolBlocked)
        XCTAssertNotNil(r.requestID)
        XCTAssertTrue(r.requestID!.hasPrefix("shell-"))
    }

    func testRequestIDsUnique() {
        let ids = (0..<500).map { _ in RequestID.make(prefix: "t") }
        XCTAssertEqual(Set(ids).count, 500)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("t-") })
    }
}