import Foundation

@main
struct SecretHarness {
    struct Stat { var pass = 0; var fail = 0 }

    static func main() {
        var stat = Stat()
        func check(_ name: String, _ ok: Bool) {
            if ok { stat.pass += 1 } else { stat.fail += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name)")
        }

        // Use an in-memory backend so the CLI harness needs no Keychain session.
        SecretStore.backend = MemorySecretBackend()

        do {
            try SecretStore.save("sk-test", for: "k1")
            check("save+read", (try? SecretStore.read("k1")) == "sk-test")
        } catch {}
        check("read missing → nil", (try? SecretStore.read("nope")) == nil)
        try? SecretStore.save("v1", for: "k2")
        try? SecretStore.save("v2", for: "k2")
        check("overwrite", (try? SecretStore.read("k2")) == "v2")
        try? SecretStore.delete("k2")
        check("delete", (try? SecretStore.read("k2")) == nil)

        let suite = "SecretHarness.defaults"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("legacy", forKey: "cloudProvider.key.openai")
        check("migrate returns value",
              SecretStore.migrateLegacyIfNeeded("cloudProvider.key.openai", defaults: defaults) == "legacy")
        check("migrate stores in backend",
              (try? SecretStore.read("cloudProvider.key.openai")) == "legacy")
        check("legacy default cleared",
              defaults.string(forKey: "cloudProvider.key.openai") == nil)
        check("re-migrate is no-op",
              SecretStore.migrateLegacyIfNeeded("cloudProvider.key.openai", defaults: defaults) == "legacy")

        UserDefaults.standard.removePersistentDomain(forName: suite)

        print()
        if stat.fail == 0 {
            print("ALL SECRET CHECKS PASSED (\(stat.pass))")
        } else {
            print("\(stat.fail) SECRET CHECKS FAILED")
            exit(1)
        }
    }
}

final class MemorySecretBackend: SecretBackend {
    var storage: [String: String] = [:]
    func save(_ value: String, for key: String) throws { storage[key] = value }
    func read(_ key: String) throws -> String? { storage[key] }
    func delete(_ key: String) throws { storage[key] = nil }
}