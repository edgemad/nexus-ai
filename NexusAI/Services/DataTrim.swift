import Foundation

/// Output-retention policy: trims generated AI output artifacts so the
/// workspace can't silently consume the whole disk. Two levers, both optional:
///   - `trim.outputsRetentionDays` (0 = off): remove timestamped output items
///     (and `tts-cache` entries) not touched in N days.
///   - `trim.maxOutputsMB` (0 = off): when generated output exceeds this,
///     oldest items are removed until back under the cap.
struct TrimReport: Equatable {
    var itemsRemoved: Int = 0
    var bytesReclaimed: Int64 = 0
    var beforeMB: Double = 0
    var afterMB: Double = 0
}

enum DataTrim {
    static let retentionDaysKey = "trim.outputsRetentionDays"
    static let maxOutputsMBKey = "trim.maxOutputsMB"

    static var retentionDays: Int {
        max(0, UserDefaults.standard.integer(forKey: retentionDaysKey))
    }
    static var maxOutputsMB: Int {
        max(0, UserDefaults.standard.integer(forKey: maxOutputsMBKey))
    }

    private static var outputLocations: (URL) -> [URL] {
        { root in
            [root.appendingPathComponent("Outputs"), root.appendingPathComponent("tts-cache")]
        }
    }

    /// Total bytes held by generated output (timestamped folders under
    /// Outputs/ and files under tts-cache/, measured recursively).
    static func currentOutputsBytes(at root: URL) -> Int64 {
        tally(at: root).reduce(0) { $0 + $1.size }
    }

    private static func tally(at root: URL) -> [(url: URL, size: Int64, mtime: Date)] {
        var items: [(URL, Int64, Date)] = []
        let fm = FileManager.default
        for location in outputLocations(root) {
            guard let children = try? fm.contentsOfDirectory(
                at: location, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else { continue }
            for child in children {
                items.append((child, sizeOf(child), mtimeOf(child)))
            }
        }
        return items.map { ($0.0, $0.1, $0.2) }
    }

    private static func sizeOf(_ url: URL) -> Int64 {
        let fm = FileManager.default
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDir else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard let children = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return 0 }
        return children.reduce(0) { total, child in
            let dir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return total + (dir ? sizeOf(child) : Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
        }
    }

    private static func mtimeOf(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Applies the retention/quota policy in place. Retention is judged by each
    /// item's own modification date; quota removes oldest-first.
    @discardableResult
    static func trim(at root: URL, now: Date = Date()) -> TrimReport {
        var report = TrimReport()
        let fm = FileManager.default

        var items = tally(at: root)
        var totalBytes = items.reduce(0) { $0 + $1.size }
        report.beforeMB = Double(totalBytes) / (1024 * 1024)

        var doomed = Set<String>()
        if retentionDays > 0 {
            for item in items where now.timeIntervalSince(item.mtime) > Double(retentionDays) * 86400 {
                doomed.insert(item.url.path)
            }
        }
        let capBytes = Int64(maxOutputsMB) * 1024 * 1024
        if capBytes > 0 {
            for item in items.sorted(by: { $0.mtime < $1.mtime }) where totalBytes > capBytes {
                totalBytes -= item.size
                doomed.insert(item.url.path)
            }
        }

        for item in items where doomed.contains(item.url.path) {
            if (try? fm.removeItem(at: item.url)) != nil {
                report.itemsRemoved += 1
                report.bytesReclaimed += item.size
            }
        }
        report.afterMB = Double(currentOutputsBytes(at: root)) / (1024 * 1024)
        return report
    }
}