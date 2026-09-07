import Combine
import CryptoKit
import Foundation

/// Rolling, checksum-verified snapshots of the durable stores (the `Data/`
/// folder under the workspace) with retention pruning and restore. Purpose:
/// an unexpected loss or corruption of a single store file (or the whole Data
/// folder) is one click away from a known-good, timestamped recovery point.
///
/// Design notes:
/// - Each snapshot is a self-contained folder `Backups/<yyyyMMdd-HHmmss>`
///   holding a copy of `Data/` plus a `manifest.json` recording per-file
///   SHA-256 checksums, so a snapshot's integrity is provable before restore.
/// - Restore verifies the snapshot, copies every recorded file back atomically,
///   and removes store files that aren't part of the snapshot (true rollback).
///   The caller is expected to relaunch the app afterwards — in-memory stores
///   are not re-read live.
/// - Automatic backups run on launch (baseline) and on an interval, and also
///   trip early after a burst of store writes.
@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    enum Keys {
        static let auto = "backup.auto"
        static let intervalHours = "backup.intervalHours"
        static let retention = "backup.retention"
    }

    static let defaultIntervalHours = 6.0
    static let defaultRetention = 8

    @Published private(set) var lastBackup: Date?
    @Published private(set) var snapshots: [BackupSnapshot] = []
    @Published private(set) var isBackingUp = false
    @Published var lastError: String?

    var autoBackup: Bool {
        get { UserDefaults.standard.object(forKey: Keys.auto) == nil || UserDefaults.standard.bool(forKey: Keys.auto) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.auto) }
    }
    var intervalHours: Double {
        get { UserDefaults.standard.object(forKey: Keys.intervalHours) as? Double ?? Self.defaultIntervalHours }
        set { UserDefaults.standard.set(max(1, min(168, newValue)), forKey: Keys.intervalHours) }
    }
    var retention: Int {
        get { UserDefaults.standard.object(forKey: Keys.retention) as? Int ?? Self.defaultRetention }
        set { UserDefaults.standard.set(max(1, newValue), forKey: Keys.retention) }
    }

    /// Writes since the last snapshot; a burst trips an early auto-backup.
    private(set) var writesSinceBackup = 0

    private var lastAutoAttempt: Date?
    private var ticker: Timer?
    private var observer: NSObjectProtocol?

    private var backupsRoot: URL {
        WorkspaceManager.shared.rootURL.appendingPathComponent("Backups", isDirectory: true)
    }
    private var dataURL: URL { PersistenceController.shared.dataURL }

    private init() {
        refreshSnapshotList()
    }

    /// Starts the per-minute scheduler and the launch-time baseline snapshot.
    /// Safe to call repeatedly (app launch paths) — it only schedules once.
    func startScheduling() {
        observer = observer ?? NotificationCenter.default.addObserver(
            forName: .nexieStoreSaved, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.writesSinceBackup += 1 }
        }
        guard ticker == nil else { return }

        let baseline = Timer(timeInterval: 5, repeats: false) { _ in
            Task { @MainActor in
                guard Self.shared.lastBackup == nil else { return }
                if Self.shared.backupNow() { Self.shared.prune() }
            }
        }
        RunLoop.main.add(baseline, forMode: .default)

        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                Self.shared.tick()
            }
        }
    }

    /// One per-minute evaluation of whether an automatic backup is due.
    func tick() {
        if isBackingUp { return }
        if !autoBackup { return }
        guard dueForAutoBackup() else { return }
        if backupNow() { prune() }
    }

    private func dueForAutoBackup() -> Bool {
        let now = Date()
        if let last = lastBackup {
            // Never hammer the disk more than once a minute.
            if now.timeIntervalSince(last) < 60 { return false }
            // Traffic-based early trigger.
            if writesSinceBackup >= 60 { return true }
            if let attempt = lastAutoAttempt, now.timeIntervalSince(attempt) < 60 { return false }
            if now.timeIntervalSince(last) >= intervalHours * 3600 { return true }
            return false
        }
        // Never backed up yet → due now (guard the rapid-repeat case below).
        if let attempt = lastAutoAttempt, now.timeIntervalSince(attempt) < 60 { return false }
        return true
    }

    /// Captures a fresh snapshot of the stores. Returns false (with `lastError`
    /// set) if a snapshot already exists for the same second, unless it clearly
    /// succeeded. `force` bypasses the between-attempt cooldown.
    @discardableResult
    func backupNow(force: Bool = false) -> Bool {
        guard !isBackingUp else { lastError = "Backup already running"; return false }
        if !force, let attempt = lastAutoAttempt, Date().timeIntervalSince(attempt) < 5 {
            return false
        }
        isBackingUp = true
        lastAutoAttempt = Date()
        defer { isBackingUp = false }

        let fm = FileManager.default
        do {
            let files = try fm.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.pathExtension == "json" }
            let dir = uniqueSnapshotDir()
            let dataDir = dir.appendingPathComponent("Data", isDirectory: true)
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

            var records: [BackupFileRecord] = []
            for file in files {
                let checksum = try Self.sha256(of: file)
                try fm.copyItem(at: file, to: dataDir.appendingPathComponent(file.lastPathComponent))
                let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                records.append(BackupFileRecord(name: file.lastPathComponent, checksum: checksum, size: size))
            }
            let manifest = BackupManifest(createdAt: Date(), files: records)
            try JSONEncoder().encode(manifest)
                .write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)

            writesSinceBackup = 0
            lastError = nil
            refreshSnapshotList()
            NotificationCenter.default.post(name: .nexieBackupEvent, object: nil,
                                            userInfo: ["event": "backup"])
            return true
        } catch {
            lastError = error.localizedDescription
            refreshSnapshotList()
            NotificationCenter.default.post(name: .nexieBackupEvent, object: nil,
                                            userInfo: ["event": "failed"])
            return false
        }
    }

    /// Verifies the most recent snapshot, if any. Used by the post-upgrade
    /// ritual (`UpdateManager`): after an upgrade force-backs-up, then checks
    /// the new snapshot's checksums so `/data` is proven restorable.
    func verifyLatestSnapshot() -> Bool {
        refreshSnapshotList()
        guard let latest = snapshots.first else { return false }
        return verify(snapshot: latest)
    }

    /// True when every recorded file exists in the snapshot and its checksum
    /// matches the manifest — the gate a restore runs before touching Data/.
    func verify(snapshot: BackupSnapshot) -> Bool {
        guard let manifest = manifest(for: snapshot),
              let dataDir = snapshotDataDir(for: snapshot) else { return false }
        for record in manifest.files {
            let url = dataDir.appendingPathComponent(record.name)
            if (try? Self.sha256(of: url)) != record.checksum { return false }
        }
        return true
    }

    /// Rolls Data/ back to the snapshot state: every recorded file restored
    /// atomically, and store files not in the snapshot removed. In-memory
    /// stores are stale afterwards — callers must relaunch the app.
    @discardableResult
    func restore(from snapshot: BackupSnapshot) -> Bool {
        guard verify(snapshot: snapshot) else {
            lastError = "Snapshot failed integrity check; restore cancelled"
            return false
        }
        guard let manifest = manifest(for: snapshot),
              let dataDir = snapshotDataDir(for: snapshot) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: dataURL, withIntermediateDirectories: true)

        for record in manifest.files {
            let src = dataDir.appendingPathComponent(record.name)
            guard let data = try? Data(contentsOf: src) else {
                lastError = "Missing file '\(record.name)' in snapshot"
                return false
            }
            try? data.write(to: dataURL.appendingPathComponent(record.name), options: .atomic)
        }
        // Full rollback: drop stores that didn't exist at snapshot time.
        if let existing = try? fm.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: nil) {
            let keep = Set(manifest.files.map { $0.name })
            for file in existing where !keep.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
        lastError = nil
        NotificationCenter.default.post(name: .nexieBackupEvent, object: nil,
                                        userInfo: ["event": "restore"])
        return true
    }

    func delete(snapshot: BackupSnapshot) {
        try? FileManager.default.removeItem(at: snapshotDir(for: snapshot))
        refreshSnapshotList()
        NotificationCenter.default.post(name: .nexieBackupEvent, object: nil,
                                        userInfo: ["event": "delete"])
    }

    /// Enforces `retention`: keeps the newest N snapshots, oldest first-removed.
    func prune() {
        refreshSnapshotList()
        let sorted = snapshots.sorted { $0.dirName > $1.dirName }
        guard sorted.count > retention else { return }
        for snapshot in sorted.dropFirst(retention) {
            try? FileManager.default.removeItem(at: snapshotDir(for: snapshot))
        }
        refreshSnapshotList()
        NotificationCenter.default.post(name: .nexieBackupEvent, object: nil,
                                        userInfo: ["event": "prune"])
    }

    // MARK: - Internals

    private func uniqueSnapshotDir() -> URL {
        var dir = backupsRoot.appendingPathComponent(Self.dirName(for: Date()), isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = backupsRoot.appendingPathComponent("\(Self.dirName(for: Date()))-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return dir
    }

    private func snapshotDir(for snapshot: BackupSnapshot) -> URL {
        backupsRoot.appendingPathComponent(snapshot.dirName, isDirectory: true)
    }

    private func snapshotDataDir(for snapshot: BackupSnapshot) -> URL? {
        let dir = snapshotDir(for: snapshot).appendingPathComponent("Data", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    private func manifest(for snapshot: BackupSnapshot) -> BackupManifest? {
        let url = snapshotDir(for: snapshot).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BackupManifest.self, from: data)
    }

    private func refreshSnapshotList() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil) else {
            snapshots = []
            lastBackup = nil
            return
        }
        var list: [BackupSnapshot] = []
        for dir in dirs where dir.hasDirectoryPath {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else { continue }
            list.append(BackupSnapshot(dirName: dir.lastPathComponent,
                                       createdAt: manifest.createdAt,
                                       fileCount: manifest.files.count,
                                       totalBytes: manifest.files.reduce(0) { $0 + $1.size }))
        }
        snapshots = list.sorted { $0.createdAt > $1.createdAt }
        lastBackup = snapshots.first?.createdAt
    }

    static func dirName(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One snapshot folder on disk plus its manifest-derived summary.
struct BackupSnapshot: Identifiable, Equatable {
    let dirName: String
    let createdAt: Date
    let fileCount: Int
    let totalBytes: Int64

    var id: String { dirName }
}

/// Per-file manifest entry: name, SHA-256 of the stored bytes, size.
struct BackupFileRecord: Codable {
    let name: String
    let checksum: String
    let size: Int64
}

/// Integrity manifest written alongside a snapshot's Data copy.
struct BackupManifest: Codable {
    let createdAt: Date
    let files: [BackupFileRecord]
}