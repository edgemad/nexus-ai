import Foundation

/// BackupManager behavior exercises: snapshot round-trip, integrity checks,
/// tamper-detection (verify/restore gates), rollback of extra store files,
/// retention pruning, and deletion. Runs against the REAL BackupManager and
/// PersistenceController, rooted at the throwaway tmp data dir (stub).
@main
struct BackupHarness {
    @MainActor
    static func main() async {
        let fm = FileManager.default
        let root = WorkspaceManager.shared.rootURL
        let dataDir = root.appendingPathComponent("Data", isDirectory: true)
        let backupsDir = root.appendingPathComponent("Backups", isDirectory: true)
        for url in [dataDir, backupsDir] {
            try? fm.removeItem(at: url)
        }
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

        struct Sample: Codable, Equatable { var id = UUID(); var name: String }
        let controller = PersistenceController.shared
        controller.save([Sample(name: "alpha")], file: "bkt_a")
        controller.save([Sample(name: "beta")], file: "bkt_b")

        let backups = BackupManager.shared
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(name): \(ok ? "PASS" : "FAIL")")
            if !ok { failures += 1 }
        }

        // 1. Snapshot captures both store files + a valid manifest.
        check("backup creates snapshot", backups.backupNow(force: true))
        let first = backups.snapshots.first
        check("snapshot listed with 2 files", first?.fileCount == 2)
        check("last backup timestamp set", backups.lastBackup != nil)

        // 2. Real DR scenario: live data is corrupted → restore from the intact
        //    snapshot repairs the store file.
        let tampered = dataDir.appendingPathComponent("bkt_a.json")
        try? Data("corrupted".utf8).write(to: tampered, options: .atomic)
        check("live data corrupted", (try? String(contentsOf: tampered, encoding: .utf8)) == "corrupted")
        check("restore repairs live data", backups.restore(from: first!))
        let repaired = controller.load([Sample].self, file: "bkt_a")
        check("repaired payload matches snapshot", repaired?.first?.name == "alpha")

        // 3. A corrupted SNAPSHOT (integrity gate) is detected and refused.
        let snapshotDataDir = backupsDir
            .appendingPathComponent(first!.dirName)
            .appendingPathComponent("Data", isDirectory: true)
        try? Data("tampered-snapshot".utf8).write(to: snapshotDataDir.appendingPathComponent("bkt_a.json"),
                                                 options: .atomic)
        check("verify detects tampered snapshot", !backups.verify(snapshot: first!))
        let beforeRestore = (try? String(contentsOf: tampered, encoding: .utf8)) ?? ""
        check("restore refuses tampered snapshot", !backups.restore(from: first!))
        check("live data untouched by refused restore",
              (try? String(contentsOf: tampered, encoding: .utf8)) == beforeRestore)
        check("fresh snapshot for rollback", backups.backupNow(force: true))
        let clean = backups.snapshots.first!
        controller.save([Sample(name: "later")], file: "bkt_c")
        check("extra store file present", fm.fileExists(atPath: dataDir.appendingPathComponent("bkt_c.json").path))
        check("restore removes files outside snapshot", backups.restore(from: clean))
        check("extra store file gone after rollback", !fm.fileExists(atPath: dataDir.appendingPathComponent("bkt_c.json").path))

        // 6. Retention pruning keeps only the newest N.
        controller.save([Sample(name: "one")], file: "bkt_r1")
        backups.retention = 2
        check("backup two", backups.backupNow(force: true))
        sleep(1)
        controller.save([Sample(name: "two")], file: "bkt_r2")
        check("backup three", backups.backupNow(force: true))
        sleep(1)
        controller.save([Sample(name: "three")], file: "bkt_r3")
        check("backup four", backups.backupNow(force: true))
        let beforePrune = backups.snapshots.sorted { $0.createdAt < $1.createdAt }
            .map { $0.createdAt }
        backups.prune()
        check("retention keeps 2 newest", backups.snapshots.count == 2)
        let retainedSorted = backups.snapshots.map { $0.createdAt }.sorted()
        let expectedNewestTwo = Array(beforePrune.suffix(2))
        check("newest snapshots survive",
              retainedSorted == expectedNewestTwo)
        check("oldest snapshots pruned",
              !retainedSorted.contains(beforePrune.first!))

        // 7. Delete removes the snapshot from disk + list.
        if let oldest = backups.snapshots.last {
            let dir = backupsDir.appendingPathComponent(oldest.dirName)
            backups.delete(snapshot: oldest)
            check("deleted snapshot gone", backups.snapshots.count == 1 && !fm.fileExists(atPath: dir.path))
        } else {
            check("deleted snapshot gone", false)
        }

        // 8. Restore-then-migrate: a snapshot taken from an older schema (v1,
        //    pre-`colorName`) is restored over the v1 file, then a real store
        //    boots through the registered chain to v2 and re-saves enveloped.
        do {
            let activityURL = dataDir.appendingPathComponent("activity.json")
            let evDict: [String: Any] = [
                "id": UUID().uuidString,
                "date": Date().timeIntervalSinceReferenceDate,
                "icon": "gear",
                "title": "old-era event",
                "detail": "written before colorName existed",
            ]
            let v1: [String: Any] = [
                "schemaVersion": 1,
                "savedAt": Date().timeIntervalSince1970,
                "payload": [evDict],
            ]
            try! JSONSerialization.data(withJSONObject: v1).write(to: activityURL)

            check("snapshot v1 era", backups.backupNow(force: true))
            let v1Snap = backups.snapshots.first!
            // Simulate data loss, then a restore of the older-era backup.
            try? fm.removeItem(at: activityURL)
            check("restore v1 snapshot", backups.restore(from: v1Snap))

            // Real store boots: v1 -> v2 repairs the missing colorName.
            let activity = ActivityStore()
            check("restored store migrates",
                  activity.events.count == 1 && activity.events[0].title == "old-era event"
                  && activity.events[0].colorName == "blue")
            let onDisk = try? JSONSerialization.jsonObject(
                with: Data(contentsOf: activityURL)) as? [String: Any]
            check("migrated file rewritten at v2",
                  (onDisk?["schemaVersion"] as? Int) == PersistenceController.currentSchemaVersion)

            try? fm.removeItem(at: activityURL)
        } catch {
            check("restore-then-migrate block", false)
        }

        backups.retention = 8
        print("backup harness done: \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        exit(failures == 0 ? 0 : 1)
    }
}