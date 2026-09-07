import Foundation

/// Transient storage for generated media that must NOT be persisted to the
/// user's Outputs folder. Files live in a temp directory that is wiped whenever
/// the app opens and pruned periodically, so generated media only exists while
/// the app is running (video can't play from raw memory, so it needs a
/// throwaway file path; this cache is that place). Opt-in Save buttons write a
/// copy to a user-chosen location.
@MainActor
final class TempMediaCache {
    static let shared = TempMediaCache()

    var directory: URL {
        _directory ?? createDirectory()
    }

    private var _directory: URL?

    private init() {}

    private func createDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexusAI-Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Wipe anything left from a previous run on first use.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
            for f in files {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(f))
            }
        }
        _directory = base
        return base
    }

    /// Returns a unique temp URL for a generated file with `ext` (no leading dot).
    func url(ext: String) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// Writes `data` to a fresh temp file and returns its URL, or nil on error.
    func write(_ data: Data, ext: String) -> URL? {
        let url = url(ext: ext)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Prunes temp files older than `maxAge`. Called on a timer by the app.
    func prune(olderThan maxAge: TimeInterval = 3600) {
        guard let dir = _directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for f in files {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if mod < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Removes every generated file. Called when the app quits so no generated
    /// media survives the session.
    func clearAll() {
        guard let dir = _directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}
