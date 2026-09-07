import Foundation
import Combine

// MARK: - Observability hooks for self-maintenance

// UpdateManager fires these without dependency on other subsystems; the app
// wires them to force a backup and verify the newest snapshot after an upgrade.
extension Notification.Name {
    static let nexieVersionUpgraded = Notification.Name("nexie.versionUpgraded")
}

/// Read from `UpdateManifest.json` at the workspace root. Optional; when the
/// file is absent the app reports "manifest not found" and keeps running.
struct UpdateManifest: Codable, Equatable {
    var version: String
    var minimumVersion: String
    var releasedAt: Date
    var releaseNotes: [String]
}

/// Version-string comparison: dotted numeric parts compared in order
/// (e.g. "1.10" > "1.9", "2.0.1" > "2.0.0").
enum VersionCompare {
    static func tuple(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }

    /// Returns true when `lhs` is a valid version and strictly greater than `rhs`.
    static func isGreater(_ lhs: String, than rhs: String) -> Bool {
        let a = tuple(lhs), b = tuple(rhs)
        precondition(!a.isEmpty)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    static func isAtLeast(_ candidate: String, minimum: String) -> Bool {
        let a = tuple(candidate), b = tuple(minimum)
        precondition(!a.isEmpty && !b.isEmpty)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return true
    }
}

/// Self-maintenance: reads the local update manifest, tracks which app version
/// last launched (upgrade detection), and drives the post-upgrade ritual
/// (backup + snapshot integrity verification + "What's New").
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var latestVersion: String?
    @Published private(set) var minimumVersion: String?
    @Published private(set) var releaseNotes: [String]?
    @Published private(set) var isUpdateAvailable = false
    @Published private(set) var isCriticalUpdate = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastUpgrade: (from: String, to: String)?

    var currentVersion: String
    let manifestURL: URL
    let defaults: UserDefaults

    /// Set by the app's wiring to force a pre-upgrade snapshot and to verify
    /// the newest snapshot's integrity after an upgrade. Overridden in tests.
    var onUpgraded: () -> Void = {}
    var onVerifySnapshot: () -> Bool = { true }

    static let lastRunKey = "update.lastRunVersion"

    nonisolated static var defaultManifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("NexusAI Workspace/UpdateManifest.json")
    }

    init(manifestFile: URL = UpdateManager.defaultManifestURL,
         defaults: UserDefaults = .standard,
         currentVersion: String = {
             Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
         }()) {
        self.manifestURL = manifestFile
        self.defaults = defaults
        self.currentVersion = currentVersion
    }

    // MARK: - Manifest

    @discardableResult
    func checkForUpdates() -> Bool {
        lastCheckedAt = Date()
        guard let manifest = manifest() else {
            latestVersion = nil
            minimumVersion = nil
            releaseNotes = nil
            isUpdateAvailable = false
            isCriticalUpdate = false
            return false
        }
        latestVersion = manifest.version
        minimumVersion = manifest.minimumVersion
        releaseNotes = manifest.releaseNotes
        isUpdateAvailable = VersionCompare.isGreater(manifest.version, than: currentVersion)
        isCriticalUpdate = !VersionCompare.isAtLeast(currentVersion, minimum: manifest.minimumVersion)
        return isUpdateAvailable
    }

    func manifest() -> UpdateManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UpdateManifest.self, from: data)
    }

    // MARK: - Upgrade detection + post-upgrade ritual

    /// Called once at launch after migrations/backup startup: detects that the
    /// installed version changed since the previous session and runs the
    /// post-upgrade ritual (backup, snapshot integrity, What's New event).
    func begin() {
        let stored = defaults.string(forKey: UpdateManager.lastRunKey)
        defaults.set(currentVersion, forKey: UpdateManager.lastRunKey)
        guard let stored, stored != currentVersion else { return }
        lastUpgrade = (from: stored, to: currentVersion)
        NotificationCenter.default.post(name: .nexieVersionUpgraded, object: nil,
                                        userInfo: ["from": stored, "to": currentVersion])
        onUpgraded()
        let verified = onVerifySnapshot()
        if verified {
            Diagnostics.shared.record(.info, source: "updates",
                                      "upgraded \(stored) → \(currentVersion); back up + snapshot verified")
        } else {
            Diagnostics.shared.record(.error, source: "updates",
                                      "upgraded \(stored) → \(currentVersion) but snapshot verification FAILED")
        }
    }

    /// The release notes shown right after an upgrade, until dismissed.
    var whatsNewText: String? {
        guard lastUpgrade != nil else { return nil }
        if let notes = releaseNotes, !notes.isEmpty {
            return notes.joined(separator: "\n")
        }
        return "Updated to \(currentVersion)."
    }
}