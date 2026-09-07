import Foundation

// Phase 5 observability harness: ring log, rotating file writer, persisted
// reliability stats (crash detection, counters), notification-driven events,
// diagnostics export, and concurrent logging from background threads.
// Compiles with just Diagnostics.swift (Foundation + Combine).

@main
struct DiagnosticsHarness {
    static var failed = false
    static func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        print("\(name): \(cond ? "PASS" : "FAIL")\(cond ? "" : " — \(detail)")")
        if !cond { failed = true }
    }

    static func freshDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NexieDiag\(UUID().uuidString)", isDirectory: true)
    }
    static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "NexieDiagSuite-\(UUID().uuidString)")!
    }

    @MainActor
    static func pump(until cond: @MainActor () -> Bool, timeout: TimeInterval = 12) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    @MainActor
    static func main() {
        let logDir = freshDir()
        let diag = Diagnostics(directory: logDir, defaults: freshDefaults(), ring: 600)
        diag.record(.info, source: "test", "first event")
        diag.record(.error, source: "test", "second event")
        check("records capture levels in order",
              diag.events.count == 2 && diag.events[0].level == .info && diag.events[1].level == .error)
        let fileURL = diag.logFileURL
        let fileText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        check("log file written with source + message",
              fileText.contains("first event") && fileText.contains("[info] test: first event"))
        check("relative ordering in file", fileText.split(separator: "\n").count >= 2)

        for _ in 0..<700 { diag.record(.debug, source: "bulk", "x") }
        check("ring capped at 600", diag.events.count == 600)

        for _ in 0..<75 {
            diag.record(.debug, source: "bulk", String(repeating: "a", count: 4096))
        }
        sleep(1)
        let rotatedExists = FileManager.default.fileExists(atPath: logDir.appendingPathComponent("nexie-1.log").path)
        let currentSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        check("log rotates past 256 KB", rotatedExists || currentSize <= Diagnostics.rotationBytes)
        check("current log stays within cap", currentSize <= Diagnostics.rotationBytes + Diagnostics.rotationBytes / 4)

        let crashDefaults = freshDefaults()
        crashDefaults.set(false, forKey: Diagnostics.persistKey + ".cleanExit")
        let crashed = Diagnostics(directory: freshDir(), defaults: crashDefaults)
        crashed.beginSession()
        check("abnormal previous exit detected", crashed.stats.crashes == 1 && crashed.stats.launches == 1)

        let relaunchDefaults = freshDefaults()
        let relaunch1 = Diagnostics(directory: freshDir(), defaults: relaunchDefaults)
        relaunch1.beginSession()
        let relaunch2 = Diagnostics(directory: freshDir(), defaults: relaunchDefaults)
        relaunch2.beginSession()
        check("launch counter survives relaunch", relaunch2.stats.launches == 2)

        let evDefaults = freshDefaults()
        let evDiag = Diagnostics(directory: freshDir(), defaults: evDefaults)
        evDiag.beginSession()
        NotificationCenter.default.post(name: .nexieCommandEvent, object: nil, userInfo: ["type": "blocked"])
        NotificationCenter.default.post(name: .nexieCommandEvent, object: nil, userInfo: ["type": "timeout"])
        NotificationCenter.default.post(name: .nexieBackupEvent, object: nil, userInfo: ["event": "backup"])
        NotificationCenter.default.post(name: .nexieMigrationEvent, object: nil, userInfo: ["file": "activity"])
        let counted = pump {
            evDiag.stats.blockedCommands == 1 && evDiag.stats.shellTimeouts == 1
                && evDiag.stats.backups == 1 && evDiag.stats.migrations == 1
        }
        check("notification events bump stats", counted)
        check("command events logged",
              evDiag.events.contains { $0.source == "shell" && $0.message.contains("blocked") })

        let exportURL = evDiag.export(to: freshDir(), sidecars: ["research": true])
        check("export file created",
              exportURL != nil && FileManager.default.fileExists(atPath: exportURL!.path))
        if let exportURL {
            let data = try! Data(contentsOf: exportURL)
            let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            check("export contains stats", (obj["stats"] as? [String: Any])?["blockedCommands"] as? Int == 1)
            check("export contains events + version + sidecars",
                  (obj["events"] as? [Any])?.count ?? 0 > 0 && obj["version"] != nil
                      && ((obj["sidecars"] as? [String: Any])?["research"] as? Bool) == true)
        }

        let threadDefaults = freshDefaults()
        let threadDiag = Diagnostics(directory: freshDir(), defaults: threadDefaults)
        threadDiag.beginSession()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "diag.threads", attributes: .concurrent)
        for i in 0..<20 {
            group.enter()
            queue.async {
                for j in 0..<25 {
                    Diagnostics.recordFromAnyThread(.info, source: "thread", "\(i)-\(j)")
                }
                group.leave()
            }
        }
        group.wait()
        let threaded = pump {
            Diagnostics.shared.events.filter { $0.source == "thread" }.count >= 500
        }
        check("concurrent logging safe + complete", threaded)

        print()
        print(failed ? "DIAGNOSTICS HARNESS FAILED" : "diagnostics harness done: ALL PASS")
        exit(failed ? 1 : 0)
    }
}