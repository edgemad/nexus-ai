import Foundation

/// Posted whenever a store is written to disk, so backup/observability layers
/// can react without being called from every store directly.
extension Notification.Name {
    static let nexieStoreSaved = Notification.Name("nexie.storeSaved")
}

/// Versioned envelope written around every persisted store payload so future
/// migrations can key off a schema version instead of guessing from content.
struct PersistenceEnvelope<T: Codable>: Codable {
    var schemaVersion: Int
    var savedAt: Date
    var payload: T
}

/// Atomic, schema-versioned JSON persistence for the app's stores. Every write
/// goes through a temp-file rename (`options: .atomic`) so a crash mid-write can
/// never leave a truncated file; corrupt or future-version files are ignored and
/// the caller falls back to a fresh/empty store instead of crashing.
///
/// Stores are small (activity/approvals/automations/tasks, at most a few KB) so
/// writes are immediate: rapid mutations are cheap and the last state survives
/// an abrupt app exit without needing a terminate hook.
@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    /// Bump when any payload shape changes; old files then read as missing and
    /// can be migrated explicitly. (See `migrateIfNeeded` for the hook.)
    static let currentSchemaVersion = 2

    let dataURL: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    private init() {
        dataURL = WorkspaceManager.shared.rootURL.appendingPathComponent("Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
    }

    func url(for file: String) -> URL {
        dataURL.appendingPathComponent("\(file).json")
    }

    /// Returns the payload when the file exists on the current schema version.
    /// Corrupt, missing, or future-schema files return nil (caller decides what
    /// to seed instead — empty store or demo data).
    func load<T: Codable>(_ type: T.Type, file: String) -> T? {
        let url = url(for: file)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? decoder.decode(PersistenceEnvelope<T>.self, from: data) else {
            return nil
        }
        // Future formats are never trusted; migrate explicitly or start over.
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return envelope.payload
    }

    // MARK: - Schema migrations

    /// Version-by-version migrations, registered PER STORE FILE (keyed by
    /// `"<file>|<fromVersion>"`) so every store can carry its own independent
    /// upgrade chain without clobbering a sibling at the same version.
    private var migrations: [String: (Data) -> Data?] = [:]

    private func migrationKey(_ file: String, _ version: Int) -> String {
        "\(file)|\(version)"
    }

    /// Registers the migration upgrading `file`'s payload one step from
    /// `fromVersion`. Migrations compose: `migrateIfNeeded` walks version by
    /// version.
    func registerMigration(fromVersion: Int, for file: String, _ migrate: @escaping (Data) -> Data?) {
        migrations[migrationKey(file, fromVersion)] = migrate
    }

    /// Reads a saved store file, walks any older-version payload through the
    /// registered migrations up to the current schema version, rewrites the
    /// file at the current version (atomically), and returns the migrated
    /// payload. Returns nil when the file is absent, already current, future-
    /// versioned, or needs a migration that isn't registered (caller decides:
    /// treat as empty rather than guessing).
    ///
    /// Files written before versioned envelopes existed (raw payload JSON with
    /// no `schemaVersion`) are treated as version 0 so legacy data can be
    /// recovered instead of silently dropped.
    @discardableResult
    func migrateIfNeeded<T: Codable>(_ type: T.Type, file: String) -> T? {
        ModelMigrations.registerAll()
        let url = url(for: file)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let version: Int
        let payload: Any
        if let dict = obj as? [String: Any], let v = dict["schemaVersion"] as? Int {
            version = v
            payload = dict["payload"] as Any
        } else {
            // Legacy pre-envelope store: the whole document is the payload.
            version = 0
            payload = obj
        }
        // Never re-process already-current (or future) files; plain `load`
        // handles them.
        guard version < Self.currentSchemaVersion else { return nil }
        return migratePayload(payload, version: version, to: type, file: file)
    }

    private func migratePayload<T: Codable>(_ root: Any, version: Int, to type: T.Type, file: String) -> T? {
        var current = version
        var payloadAny = root
        while current < Self.currentSchemaVersion {
            guard let migrate = migrations[migrationKey(file, current)] else { return nil }
            guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadAny),
                  let migratedData = migrate(payloadData),
                  let migratedAny = try? JSONSerialization.jsonObject(with: migratedData) else { return nil }
            payloadAny = migratedAny
            current += 1
        }
        guard let finalData = try? JSONSerialization.data(withJSONObject: payloadAny),
              let decoded = try? decoder.decode(T.self, from: finalData) else { return nil }
        save(decoded, file: file)
        NotificationCenter.default.post(name: .nexieMigrationEvent, object: file,
                                        userInfo: ["file": file])
        return decoded
    }

    /// Prefers a migrated payload when the saved file is on an older schema
    /// version; otherwise behaves like `load`. Stores that anticipate future
    /// changes should call this instead of `load` directly.
    func loadOrMigrate<T: Codable>(_ type: T.Type, file: String) -> T? {
        if let migrated = migrateIfNeeded(type, file: file) { return migrated }
        return load(type, file: file)
    }

    /// Atomically writes `value` wrapped in the current schema envelope.
    func save<T: Codable>(_ value: T, file: String) {
        let envelope = PersistenceEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            savedAt: Date(),
            payload: value
        )
        guard let data = try? encoder.encode(envelope) else { return }
        try? data.write(to: url(for: file), options: .atomic)
        NotificationCenter.default.post(name: .nexieStoreSaved, object: file)
    }
}