import Foundation

/// Persistent curated-command allowlist ("scoped, pre-audited maintenance
/// built-ins") that merges into ShellRunner's caller-supplied `curated` set.
///
/// ShellRunner reads the shared storage key directly (it must keep compiling
/// standalone in the shell harness), so this type is a thin, typed wrapper
/// around the same UserDefaults key. Keep `storageKey` in sync with
/// ShellRunner.allowlistStorageKey.
enum CommandAllowlist {
    static let storageKey = "commands.allowlist"

    static var all: [String] {
        defaults.array(forKey: storageKey) as? [String] ?? []
    }

    static func allows(_ command: String) -> Bool {
        all.contains(command)
    }

    @discardableResult
    static func add(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !allows(trimmed) else { return false }
        var updated = all
        updated.append(trimmed)
        defaults.set(updated, forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    @discardableResult
    static func remove(_ command: String) -> Bool {
        var updated = all
        guard let idx = updated.firstIndex(of: command) else { return false }
        updated.remove(at: idx)
        defaults.set(updated, forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    static func clear() {
        defaults.set([String](), forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static let didChange = Notification.Name("nexie.allowlistChanged")

    static var defaults: UserDefaults = .standard
}