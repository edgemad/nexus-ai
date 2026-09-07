import Combine
import Foundation

// MARK: - Notifications emitted by app subsystems and consumed by Diagnostics.

// Producers post these WITHOUT any dependency on Diagnostics so the store /
// backup / shell harnesses keep compiling exactly as-is (posts are inert when
// nobody is listening).
extension Notification.Name {
    /// userInfo["type"]: "blocked" | "timeout" | "cancelled" | "failed"
    static let nexieCommandEvent = Notification.Name("nexie.commandEvent")
    /// userInfo["event"]: "backup" | "restore" | "prune" | "delete" | "failed"
    static let nexieBackupEvent = Notification.Name("nexie.backupEvent")
    /// userInfo["file"]: name of the store migrated to the current schema
    static let nexieMigrationEvent = Notification.Name("nexie.migrationEvent")
}

enum LogLevel: String, Codable, Comparable, CaseIterable {
    case debug, info, warn, error
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

struct LogEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let ts: Date
    let level: LogLevel
    let source: String
    let message: String
    /// Machine-readable event code (e.g. "tool.blocked", "backup.completed").
    let name: String?
    /// Tracing ID linking this event to a user request / run.
    let requestID: String?

    init(level: LogLevel, source: String, message: String,
         name: String? = nil, requestID: String? = nil) {
        self.id = UUID()
        self.ts = Date()
        self.level = level
        self.source = source
        self.message = message
        self.name = name
        self.requestID = requestID
    }

    var line: String {
        "\(ts.ISO8601Format()) [\(level.rawValue)] \(source): \(message)"
    }
}

/// Lifetime counters that survive relaunches (crash detection included).
/// `sessionStart` is meaningful only for the current process.
struct DiagnosticsStats: Codable, Equatable {
    var launches = 0
    var crashes = 0
    var blockedCommands = 0
    var shellTimeouts = 0
    var shellCancellations = 0
    var sidecarRespawns: [String: Int] = [:]
    var backups = 0
    var restores = 0
    var migrations = 0
    var sessionStart = Date()
}

/// Central observability: an in-memory ring of log events plus a rotating file
/// writer, persisted reliability counters, and a diagnostics export. All state
/// is isolated to the main actor; background subsystems publish through
/// notifications and this class translates them on the main queue.
@MainActor
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()

    @Published private(set) var events: [LogEvent] = []
    @Published private(set) var stats = DiagnosticsStats()

    let logDirectoryURL: URL
    let defaults: UserDefaults
    private let ring: Int
    private var observers: [NSObjectProtocol] = []

    nonisolated static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("NexusAI Workspace/logs", isDirectory: true)
    }
    static let persistKey = "diagnostics.stats.v1"
    static let rotationBytes = 256 * 1024

    init(directory: URL = Diagnostics.defaultLogDirectory,
         defaults: UserDefaults = .standard,
         ring: Int = 600) {
        self.logDirectoryURL = directory
        self.defaults = defaults
        self.ring = ring
        if let disk = defaults.data(forKey: Diagnostics.persistKey),
           let decoded = try? JSONDecoder().decode(DiagnosticsStats.self, from: disk) {
            stats = decoded
        }
        stats.sessionStart = Date()
    }

    // MARK: - Session lifecycle

    /// Called at launch: counts the run, detects an abnormally-ended previous
    /// session, resets the clean-exit flag, and starts listening.
    func beginSession() {
        let cleanKey = Diagnostics.persistKey + ".cleanExit"
        // Only a session that STARTED but never marked exit counts as a crash;
        // a brand-new install (no stored flag at all) is not one.
        if defaults.object(forKey: cleanKey) != nil, defaults.bool(forKey: cleanKey) == false {
            stats.crashes += 1
            record(.warn, source: "app",
                   "previous session ended abnormally (crash count now \(stats.crashes))")
        }
        stats.launches += 1
        defaults.set(false, forKey: cleanKey)
        persist()
        registerObservers()
        record(.info, source: "app", "session began — launch #\(stats.launches)")
    }

    /// Called on graceful termination so the next launch knows it was clean.
    func markCleanExit() {
        defaults.set(true, forKey: Diagnostics.persistKey + ".cleanExit")
        persist()
    }

    // MARK: - Logging

    func record(_ level: LogLevel, source: String, _ message: String,
            name: String? = nil, requestID: String? = nil) {
        let event = LogEvent(level: level, source: source, message: message,
                             name: name, requestID: requestID)
        events.append(event)
        if events.count > ring {
            events.removeFirst(events.count - ring)
        }
        write(event.line)
    }

    /// Same as `record` but with a typed error + its request ID attached.
    func record(_ error: NexusError, source: String) {
        record(.error, source: source, error.message,
               name: "error.\(error.code.rawValue)", requestID: error.requestID)
    }

    func recordRespawn(_ kind: String) {
        stats.sidecarRespawns[kind, default: 0] += 1
        record(.warn, source: "sidecars",
               "\(kind) sidecar unresponsive — respawning (total \(stats.sidecarRespawns[kind] ?? 0))")
    }

    /// Thread-safe escape hatch for background callers that need the log API
    /// directly (rather than posting a notification).
    nonisolated static func recordFromAnyThread(_ level: LogLevel, source: String, _ message: String) {
        Task { @MainActor in
            shared.record(level, source: source, message)
        }
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(stats) {
            defaults.set(data, forKey: Diagnostics.persistKey)
        }
    }

    // MARK: - File writer (rotating)

    var logFileURL: URL { logDirectoryURL.appendingPathComponent("nexie.log") }

    private func write(_ line: String) {
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        let url = logFileURL
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size > Diagnostics.rotationBytes {
            rotate()
        }
        let data = "\(line)\n".data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func rotatedURL(_ index: Int) -> URL {
        logDirectoryURL.appendingPathComponent("nexie-\(index).log")
    }

    private func rotate() {
        let fm = FileManager.default
        if fm.fileExists(atPath: rotatedURL(2).path) {
            try? fm.removeItem(at: rotatedURL(2))
        }
        if fm.fileExists(atPath: rotatedURL(1).path) {
            try? fm.moveItem(at: rotatedURL(1), to: rotatedURL(2))
        }
        try? fm.moveItem(at: logFileURL, to: rotatedURL(1))
    }

    // MARK: - Notifications from other subsystems

    private func registerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: .nexieCommandEvent, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let requestID = note.userInfo?["requestID"] as? String
                switch note.userInfo?["type"] as? String {
                case "blocked":
                    self.stats.blockedCommands += 1
                    self.record(.warn, source: "shell", "blocked a destructive command",
                                name: "tool.blocked", requestID: requestID)
                case "timeout":
                    self.stats.shellTimeouts += 1
                    self.record(.warn, source: "shell", "command timed out",
                                name: "tool.timeout", requestID: requestID)
                case "cancelled":
                    self.stats.shellCancellations += 1
                    self.record(.info, source: "shell", "command cancelled",
                                name: "tool.cancelled", requestID: requestID)
                case "failed":
                    self.record(.debug, source: "shell", "command exited non-zero",
                                name: "tool.failed", requestID: requestID)
                default:
                    break
                }
            }
        })

        observers.append(center.addObserver(forName: .nexieBackupEvent, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch note.userInfo?["event"] as? String {
                case "backup":
                    self.stats.backups += 1
                    self.record(.info, source: "backups", "backup created (total \(self.stats.backups))")
                case "restore":
                    self.stats.restores += 1
                    self.record(.warn, source: "backups", "restore performed (total \(self.stats.restores))")
                case "prune":
                    self.record(.info, source: "backups", "retention pruning ran")
                case "delete":
                    self.record(.info, source: "backups", "snapshot deleted")
                case "failed":
                    self.record(.error, source: "backups", "backup failed")
                default:
                    break
                }
            }
        })

        observers.append(center.addObserver(forName: .nexieMigrationEvent, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stats.migrations += 1
                let file = note.userInfo?["file"] as? String ?? "store"
                self.record(.info, source: "migrations", "migrated \(file) to the current schema")
            }
        })
    }

    // MARK: - Export

    private struct Export: Codable {
        var exportedAt: Date
        var sessionStarted: Date
        var uptimeSeconds: Int
        var stats: DiagnosticsStats
        var events: [LogEvent]
        var logFile: String
        var version: String
        var sidecars: [String: Bool]
    }

    /// Writes a standalone JSON bundle (stats + recent events + health
    /// snapshot) under `<base>/Exports/Diagnostics/diagnostics-<stamp>.json`.
    @discardableResult
    func export(to baseDirectory: URL,
                sidecars: [String: Bool] = [:],
                recentEvents: Int = 200) -> URL? {
        let dir = baseDirectory.appendingPathComponent("Exports/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: Date())
        let url = dir.appendingPathComponent("diagnostics-\(stamp).json")

        let export = Export(exportedAt: Date(),
                            sessionStarted: stats.sessionStart,
                            uptimeSeconds: Int(Date().timeIntervalSince(stats.sessionStart)),
                            stats: stats,
                            events: Array(events.suffix(recentEvents)),
                            logFile: logFileURL.path,
                            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                            sidecars: sidecars)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(export) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}