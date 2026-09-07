import Foundation

@main
struct SecurityHarness {
    struct Stat { var pass = 0; var fail = 0 }

    static func main() {
        var stat = Stat()

        func check(_ name: String, _ ok: Bool) {
            if ok { stat.pass += 1 } else { stat.fail += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name)")
        }

        // ---- CommandAllowlist (isolated onto a throwaway suite) ----
        let suiteName = "SecurityHarness.allowlist"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        CommandAllowlist.defaults = UserDefaults(suiteName: suiteName)!
        CommandAllowlist.clear()

        check("allowlist starts empty", CommandAllowlist.all.isEmpty)
        check("add curated command", CommandAllowlist.add("sh maintenance.sh"))
        check("allows added command", CommandAllowlist.allows("sh maintenance.sh"))
        check("duplicate add ignored", !CommandAllowlist.add("sh maintenance.sh"))
        check("remove works", CommandAllowlist.remove("sh maintenance.sh"))
        check("removed no longer allowed", !CommandAllowlist.allows("sh maintenance.sh"))
        check("remove of missing no-op", !CommandAllowlist.remove("never-added"))
        CommandAllowlist.add("curl example.com")
        check("persists after rewrite", CommandAllowlist.allows("curl example.com"))
        CommandAllowlist.clear()
        check("clear empties", CommandAllowlist.all.isEmpty)

        // ---- ShellRunner allowlist bypass (isolated to avoid dev-machine key) ----
        let realKey = ShellRunner.allowlistStorageKey
        UserDefaults.standard.removeObject(forKey: realKey)
        check("blocklist blocks rm -rf", ShellRunner.isDestructive("rm -rf /tmp/a", curated: []))
        UserDefaults.standard.set(["rm -rf /tmp/a"], forKey: realKey)
        check("allowlist bypasses blocklist",
              !ShellRunner.isDestructive("rm -rf /tmp/a", curated: []))
        UserDefaults.standard.removeObject(forKey: realKey)
        check("block restored after clear", ShellRunner.isDestructive("rm -rf /tmp/a", curated: []))
        check("curated still bypasses", !ShellRunner.isDestructive("rm -rf /tmp/a", curated: ["rm -rf /tmp/a"]))

        // ---- SecretRedactor ----
        let withJWT = "token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.asdf"
        check("redacts inline JWT", !SecretRedactor.redact(withJWT).contains("eyJ"))
        check("hides api_key value",
              !SecretRedactor.redact("api_key=sk-abc123def456ghi789").contains("sk-abc123"))
        check("redacts bearer token",
              !SecretRedactor.redact("Authorization: Bearer xyzabc0123456789XyZ0123456789").contains("xyzabc012"))
        check("redacts email", SecretRedactor.redact("reach me at alice@example.com now").contains("alice@example.com") == false)
        check("long blob masked", !SecretRedactor.redact("09f6e1a7b83c4d5e6f7a8b9c0d1e2f3a").contains("09f6e1a7"))
        check("plain text untouched", SecretRedactor.redact("Hello world") == "Hello world")
        check("emails consistently masked", !SecretRedactor.redact("a@b.io and c@d.io").contains("@"))

        // ---- DataTrim ----
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DataTrimHarness-\(UUID().uuidString)")
        let outputs = root.appendingPathComponent("Outputs")
        let tts = root.appendingPathComponent("tts-cache")
        try! fm.createDirectory(at: outputs, withIntermediateDirectories: true)
        try! fm.createDirectory(at: tts, withIntermediateDirectories: true)
        func touch(_ url: URL, bytes: Int, age: TimeInterval) {
            try! Data(repeating: 0x41, count: bytes).write(to: url)
            try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let oldFolder = outputs.appendingPathComponent("2026-01-01 00.00.00")
        try! fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        touch(oldFolder.appendingPathComponent("file.txt"), bytes: 1_000, age: 60 * 86400)
        try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: oldFolder.path)
        let newFolder = outputs.appendingPathComponent("2026-09-01 12.00.00")
        try! fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
        touch(newFolder.appendingPathComponent("file.txt"), bytes: 2_000, age: 3_600)
        try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: newFolder.path)
        touch(tts.appendingPathComponent("a.wav"), bytes: 500, age: 30)

        UserDefaults.standard.set(30, forKey: DataTrim.retentionDaysKey)
        let report = DataTrim.trim(at: root)
        check("retention removed old item", report.itemsRemoved == 1)
        check("reclaimed approximate bytes", report.bytesReclaimed >= 1_000)
        check("newer item kept", fm.fileExists(atPath: newFolder.path))
        check("tts-cache kept (recent)", fm.fileExists(atPath: tts.appendingPathComponent("a.wav").path))

        let bigFolder = outputs.appendingPathComponent("2026-09-05 12.00.00")
        try! fm.createDirectory(at: bigFolder, withIntermediateDirectories: true)
        try! Data(repeating: 0x42, count: 1_400_000).write(to: bigFolder.appendingPathComponent("big.txt"))
        let now = Date()
        try! fm.setAttributes([.modificationDate: now], ofItemAtPath: bigFolder.path)
        try! fm.setAttributes([.modificationDate: now], ofItemAtPath: bigFolder.appendingPathComponent("big.txt").path)

        UserDefaults.standard.set(1, forKey: DataTrim.maxOutputsMBKey)
        let quota = DataTrim.trim(at: root)
        check("quota evicted until under cap", quota.itemsRemoved >= 3)
        check("quota reclaimed generous bytes", quota.bytesReclaimed >= 1_400_000)

        UserDefaults.standard.removeObject(forKey: DataTrim.retentionDaysKey)
        UserDefaults.standard.removeObject(forKey: DataTrim.maxOutputsMBKey)
        try? fm.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        print()
        if stat.fail == 0 {
            print("ALL SECURITY CHECKS PASSED (\(stat.pass))")
        } else {
            print("\(stat.fail) SECURITY CHECKS FAILED")
            exit(1)
        }
    }
}