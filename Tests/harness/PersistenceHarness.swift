import Foundation

@main
struct PersistenceHarness {
    static func main() async {
        let ctrl = PersistenceController.shared
        let file = "harnesstest"

        struct Sample: Codable, Equatable {
            var id = UUID()
            var name: String
            var count: Int
        }

        // 1) Round-trip: save then load
        let first = [Sample(name: "one", count: 1), Sample(name: "two", count: 2)]
        ctrl.save(first, file: file)
        let loaded: [Sample]? = ctrl.load([Sample].self, file: file)
        print("1 round-trip:", loaded == first && loaded?.count == 2 ? "PASS" : "FAIL")

        // 2) Overwrite persists latest
        let second = [Sample(name: "three", count: 3)]
        ctrl.save(second, file: file)
        let reloaded: [Sample]? = ctrl.load([Sample].self, file: file)
        print("2 overwrite:", reloaded?.first?.name == "three" ? "PASS" : "FAIL")

        // 3) Corrupt file -> nil (no crash, no decode)
        let url = ctrl.url(for: file)
        try? Data("not json at all".utf8).write(to: url)
        let corrupt: [Sample]? = ctrl.load([Sample].self, file: file)
        print("3 corrupt:", corrupt == nil ? "PASS" : "FAIL")

        // 4) Future schema version -> ignored (nil)
        let future = PersistenceEnvelope(schemaVersion: 999, savedAt: Date(), payload: [Sample(name: "x", count: 0)])
        let enc = JSONEncoder()
        let futureData = try! enc.encode(future)
        try? futureData.write(to: url)
        let futureLoad: [Sample]? = ctrl.load([Sample].self, file: file)
        print("4 future schema:", futureLoad == nil ? "PASS" : "FAIL")

        // 5) Missing file -> nil
        let missing: [Sample]? = ctrl.load([Sample].self, file: "does_not_exist")
        print("5 missing:", missing == nil ? "PASS" : "FAIL")

        // 6) Schema migration: hand-written v0 file -> registered per-file
        //    chain (v0->v1 rename, v1->v2 pass) -> current schema.
        let migFile = "migrationtest"
        struct MigratedSample: Codable, Equatable { var id = UUID(); var name: String }
        let v0Envelope: [String: Any] = [
            "schemaVersion": 0,
            "savedAt": Date().timeIntervalSince1970,
            "payload": ["id": UUID().uuidString, "oldKey": "legacy"]
        ]
        try! JSONSerialization.data(withJSONObject: v0Envelope).write(to: ctrl.url(for: migFile))
        ctrl.registerMigration(fromVersion: 0, for: migFile) { payloadData in
            guard var obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }
            obj["name"] = obj.removeValue(forKey: "oldKey")
            return try? JSONSerialization.data(withJSONObject: obj)
        }
        ctrl.registerMigration(fromVersion: 1, for: migFile) { $0 }
        let migrated = ctrl.loadOrMigrate(MigratedSample.self, file: migFile)
        print("6 migration runs (multi-hop):", migrated?.name == "legacy" ? "PASS" : "FAIL")

        // Migrated file is rewritten at the current schema: plain load reads it.
        let again = ctrl.load(MigratedSample.self, file: migFile)
        print("7 migration persisted:", again == migrated ? "PASS" : "FAIL")

        // A file that needs an unregistered hop is abandoned (nil), not guessed.
        try! JSONSerialization.data(withJSONObject: v0Envelope).write(to: ctrl.url(for: migFile))
        let stuck = ctrl.loadOrMigrate([MigratedSample].self, file: migFile)
        print("8 missing hop = nil:", stuck == nil ? "PASS" : "FAIL")

        // 9) Per-file isolation: same version, two files, distinct migrations,
        //    no clobbering.
        ctrl.registerMigration(fromVersion: 1, for: "iso_a") { data in
            Self.stamp(data, "A")
        }
        ctrl.registerMigration(fromVersion: 1, for: "iso_b") { data in
            Self.stamp(data, "B")
        }
        struct Tagged: Codable, Equatable { var tag: String }
        for (fn, mark) in [("iso_a", "A"), ("iso_b", "B")] {
            let v1Envelope: [String: Any] = [
                "schemaVersion": 1,
                "savedAt": Date().timeIntervalSince1970,
                "payload": [["tag": "plain"]]
            ]
            try! JSONSerialization.data(withJSONObject: v1Envelope).write(to: ctrl.url(for: fn))
        }
        let gotA = ctrl.loadOrMigrate([Tagged].self, file: "iso_a")
        let gotB = ctrl.loadOrMigrate([Tagged].self, file: "iso_b")
        print("9 per-file migrations isolated:", gotA?.first?.tag == "A" && gotB?.first?.tag == "B" ? "PASS" : "FAIL")

        // 10) Legacy recovery: a pre-envelope raw array loads as version 0,
        //     runs the full registered chain, and is re-saved enveloped.
        let legacyJSON: [[String: Any]] = [["name": "pre-envelope"]]
        let legacyURL = ctrl.url(for: "legacyfile")
        try! JSONSerialization.data(withJSONObject: legacyJSON).write(to: legacyURL)
        struct LegacyItem: Codable, Equatable { let name: String }
        ctrl.registerMigration(fromVersion: 0, for: "legacyfile") { $0 }
        ctrl.registerMigration(fromVersion: 1, for: "legacyfile") { $0 }
        let recovered = ctrl.loadOrMigrate([LegacyItem].self, file: "legacyfile")
        print("10 legacy v0 recovered:", recovered == [LegacyItem(name: "pre-envelope")] ? "PASS" : "FAIL")
        let decodedNow = try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: legacyURL)) ?? Data())
        let envelopeVersion = (decodedNow as? [String: Any])?["schemaVersion"] as? Int
        print("10b legacy rewritten enveloped:", envelopeVersion == PersistenceController.currentSchemaVersion ? "PASS" : "FAIL")

        for f in [ctrl.url(for: migFile), ctrl.url(for: "iso_a"), ctrl.url(for: "iso_b"), legacyURL] {
            try? FileManager.default.removeItem(at: f)
        }
        print("harness done")
    }

    static func stamp(_ data: Data, _ mark: String) -> Data? {
        guard var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return data }
        for i in arr.indices { arr[i]["tag"] = mark }
        return try? JSONSerialization.data(withJSONObject: arr)
    }
}