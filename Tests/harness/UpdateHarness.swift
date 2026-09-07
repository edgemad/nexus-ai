import Foundation

@main
struct UpdateHarness {
    struct Stat { var pass = 0; var fail = 0; var failures = 0 }

    static func main() async {
        var stat = Stat()

        func check(_ name: String, _ ok: Bool) {
            if ok { stat.pass += 1 } else { stat.fail += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name)")
        }

        // ---- VersionCompare ----
        check("1.10 > 1.9", VersionCompare.isGreater("1.10", than: "1.9"))
        check("1.1 < 1.10", !VersionCompare.isGreater("1.1", than: "1.10"))
        check("2.0.0 > 1.9.9", VersionCompare.isGreater("2.0.0", than: "1.9.9"))
        check("equal not greater", !VersionCompare.isGreater("1.5", than: "1.5"))
        check("at least equal", VersionCompare.isAtLeast("1.5", minimum: "1.5"))
        check("at least higher", VersionCompare.isAtLeast("1.6", minimum: "1.5"))
        check("below minimum", !VersionCompare.isAtLeast("1.4", minimum: "1.5"))
        check("1.10 at least 1.9", VersionCompare.isAtLeast("1.10", minimum: "1.9"))

        // ---- Manifest decode + checkForUpdates ----
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("UpdateHarness-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestFile = dir.appendingPathComponent("UpdateManifest.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = UpdateManifest(version: "1.1",
                                      minimumVersion: "1.0",
                                      releasedAt: Date(),
                                      releaseNotes: ["Self-maintenance", "Security"])
        try! encoder.encode(manifest).write(to: manifestFile)

        let suiteName = "UpdateHarness.defaults"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!

        let um = UpdateManager(manifestFile: manifestFile, defaults: defaults, currentVersion: "1.0")
        check("update available 1.0→1.1", um.checkForUpdates())
        check("latest set", um.latestVersion == "1.1")
        check("not critical (1.0 ≥ min 1.0)", !um.isCriticalUpdate)

        let umCurrent = UpdateManager(manifestFile: manifestFile, defaults: defaults, currentVersion: "1.1")
        check("no update at same version", !umCurrent.checkForUpdates())

        let belowMin = UpdateManager(manifestFile: manifestFile, defaults: defaults, currentVersion: "0.9")
        _ = belowMin.checkForUpdates()
        check("critical when below minimum", belowMin.isCriticalUpdate)

        // ---- Upgrade detection / ritual ----
        defaults.set("1.0", forKey: UpdateManager.lastRunKey)
        var upgradedCalls = 0
        var verified = false
        let um2 = UpdateManager(manifestFile: manifestFile, defaults: defaults, currentVersion: "1.1")
        um2.checkForUpdates()
        var notificationFired = false
        let token = NotificationCenter.default.addObserver(forName: .nexieVersionUpgraded, object: nil, queue: nil) { _ in
            notificationFired = true
        }
        um2.onUpgraded = { upgradedCalls += 1 }
        um2.onVerifySnapshot = { verified = true; return true }
        um2.begin()
        check("ritual ran on version change", upgradedCalls == 1)
        check("snapshot verify called", verified)
        check("upgrade notification fired", notificationFired)
        check("lastRun updated to current", defaults.string(forKey: UpdateManager.lastRunKey) == "1.1")
        check("lastUpgrade recorded", um2.lastUpgrade?.to == "1.1")
        check("whatsNew shown after upgrade", um2.whatsNewText?.contains("Self-maintenance") == true)
        check("post-upgrade snapshot verified (default true path presented)",
              um2.onVerifySnapshot() == true)
        NotificationCenter.default.removeObserver(token)

        // Re-run begin(): stored now == current, so the ritual must NOT repeat.
        upgradedCalls = 0
        um2.onUpgraded = { upgradedCalls += 1 }
        um2.begin()
        check("no repeat on same-version relaunch", upgradedCalls == 0)
        check("upgrade event unchanged on same version",
              um2.lastUpgrade?.from == "1.0" && um2.lastUpgrade?.to == "1.1")

        // Missing manifest.
        let empty = UpdateManager(manifestFile: dir.appendingPathComponent("missing.json"), defaults: defaults, currentVersion: "1.0")
        check("missing manifest → no update", !empty.checkForUpdates())

        try? fm.removeItem(at: dir)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        print()
        if stat.fail == 0 {
            print("ALL UPDATE CHECKS PASSED (\(stat.pass))")
        } else {
            print("\(stat.fail) UPDATE CHECKS FAILED")
            exit(1)
        }
    }
}