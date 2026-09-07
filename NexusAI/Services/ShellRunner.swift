import Foundation

/// Fired without a listener dependency so shell harnesses compile standalone.
private let nexieCommandEvent = Notification.Name("nexie.commandEvent")

/// Result of running one command, with enough info to distinguish a clean
/// failure from a kill by timeout or user cancellation.
struct ShellResult {
    var text: String
    var failed: Bool
    var wasCancelled: Bool = false
    /// Tracing ID emitted alongside the command's diagnostics events.
    var requestID: String? = nil
    /// Typed failure category when the command was blocked or timed out.
    var errorCode: NexusErrorCode? = nil
}

/// Self-contained hardened shell runner used by AgentExecutor (and exercised
/// directly by the test harness). Guarantees:
/// - a hard timeout kills any command that outlives it
/// - output is capped and streamed to a temp file (no unbounded pipe)
/// - a scrubbed environment replaces inherited secrets (API keys, tokens...)
/// - a fixed, visible working directory is used
/// - in-flight processes can be cancelled (SIGINT escalated to SIGTERM)
/// - a destructive-command blocklist is enforced
enum ShellRunner {
    /// Default seconds a command may run before it is killed.
    static let commandTimeout: TimeInterval = 60
    /// Maximum characters of output kept for a single command result.
    static let outputCharCap = 4000

    /// The dash of environment a child shell may see; everything else inherited
    /// from the app (API keys, token caches, etc.) is stripped.
    static let shellEnvAllowlist: Set<String> = [
        "PATH", "HOME", "USER", "USERNAME", "LOGNAME", "SHELL",
        "TERM", "TERM_PROGRAM", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
    ]

    /// Fixed, visible working directory for shell actions: the NexusAI
    /// Workspace root when present, else the user's home directory.
    static var workspaceDirectoryURL: URL {
        let workspace = URL(fileURLWithPath: NSHomeDirectory() + "/NexusAI Workspace", isDirectory: true)
        if FileManager.default.fileExists(atPath: workspace.path) { return workspace }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Flags `id` as cancelled and interrupts the in-flight process.
    static func cancel(_ id: UUID) -> Bool { Registry.shared.requestCancel(id) }
    static func isCancelled(_ id: UUID) -> Bool { Registry.shared.isCancelled(id) }
    static func clear(_ id: UUID) { Registry.shared.clear(id) }

    /// Conservative blocklist for clearly destructive or system-level commands.
    /// Commands in `curated` (pre-audited, scoped maintenance built-ins) bypass
    /// it, as do commands in the persistent user allowlist (`commands.allowlist`,
    /// managed in Settings → Security).
    static let allowlistStorageKey = "commands.allowlist"
    static func isDestructive(_ command: String, curated: Set<String>) -> Bool {
        if curated.contains(command) { return false }
        if (UserDefaults.standard.array(forKey: allowlistStorageKey) as? [String])?.contains(command) == true {
            return false
        }
        let c = command.lowercased()
        let patterns = [
            "rm -rf /", "rm -r /", "rm -rf ~", "mkfs", "dd if=",
            "diskutil erasevolume", "diskutil zeroDisk", "shutdown", "halt",
            "poweroff", "init 0", "init 6", "sudo ",
            #"\;.*reboot"#, "mv / ", "chown -r", "fsck", "> /dev/sd"
        ]
        return patterns.contains { c.contains($0) }
    }

    /// Runs `command` under `/bin/zsh -c` with hardening. Returns within
    /// `timeout` seconds, or with `wasCancelled` set once `cancel(id)` races in.
    /// `id` is the caller's action identifier used for cancellation.
static func runBlocking(_ command: String,
                        id: UUID = UUID(),
                        curated: Set<String> = [],
                        timeout: TimeInterval = ShellRunner.commandTimeout) -> ShellResult {
        let requestID = RequestID.make(prefix: "shell")
        if Registry.shared.isCancelled(id) {
            postEvent("cancelled", requestID: requestID)
            return ShellResult(text: "Cancelled by the user.", failed: true,
                               wasCancelled: true, requestID: requestID)
        }
        if isDestructive(command, curated: curated) {
            postEvent("blocked", requestID: requestID)
            return ShellResult(text: "Blocked: this command looks destructive and is not allowed.",
                               failed: true, requestID: requestID, errorCode: .toolBlocked)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        proc.currentDirectoryURL = workspaceDirectoryURL

        var env = ProcessInfo.processInfo.environment
        for key in env.keys where !shellEnvAllowlist.contains(key) { env[key] = nil }
        env["PATH"] = env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env

        let outFile = temporaryOutputFile()
        guard let outHandle = try? FileHandle(forWritingTo: outFile) else {
            return ShellResult(text: "Could not set up command output file.",
                               failed: true, requestID: requestID, errorCode: .unknown)
        }
        proc.standardOutput = outHandle
        proc.standardError = outHandle
        Registry.shared.associate(id, proc)

        do {
            try proc.run()
        } catch {
            Registry.shared.clear(id)
            try? outHandle.close()
            try? FileManager.default.removeItem(at: outFile)
            return ShellResult(text: "Could not start command: \(error.localizedDescription)",
                               failed: true, requestID: requestID, errorCode: .unknown)
        }

        var cancelled = false
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Registry.shared.isCancelled(id) {
                cancelled = true
                proc.interrupt()
                for _ in 0..<10 where proc.isRunning { Thread.sleep(forTimeInterval: 0.1) }
                if proc.isRunning { proc.terminate() }
                break
            }
            if Date() > deadline {
                timedOut = true
                proc.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Registry.shared.clear(id)
        try? outHandle.close()
        // Reap the process before reading its status: after interrupt/terminate
        // the process may still be winding down, and reading terminationStatus
        // (or letting Process dealloc) while running raises an exception.
        proc.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: outFile) }

        let status = proc.terminationStatus
        let out = readCappedOutput(from: outFile)

        if cancelled {
            postEvent("cancelled", requestID: requestID)
            return ShellResult(text: "Cancelled by the user.", failed: true,
                               wasCancelled: true, requestID: requestID)
        }
        if timedOut {
            postEvent("timeout", requestID: requestID)
            return ShellResult(text: "Command timed out after \(Int(timeout)) seconds.\nPartial output:\n\(out)",
                               failed: true, requestID: requestID, errorCode: .toolTimeout)
        }
        if status != 0 { postEvent("failed", requestID: requestID) }
        return ShellResult(text: out, failed: status != 0, requestID: requestID)
    }

    // MARK: - Observability

    private static func postEvent(_ type: String, requestID: String) {
        NotificationCenter.default.post(name: nexieCommandEvent, object: nil,
                                        userInfo: ["type": type, "requestID": requestID])
    }

    /// Reads the command output file and applies the character cap + trimming.
    static func readCappedOutput(from url: URL) -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return "(no output)" }
        if text.count > outputCharCap {
            return String(text.prefix(outputCharCap)) + "\n…(truncated)"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no output)" : trimmed
    }

    /// Scratch file used to capture stdout/stderr without holding a pipe in memory.
    private static func temporaryOutputFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexie-cmd-\(UUID().uuidString).log")
        try? Data().write(to: url)
        return url
    }
}

/// Thread-safe registry of in-flight shell processes so a running command can
/// be interrupted from the UI or by approval expiry. Called from detached tasks.
private final class Registry {
    static let shared = Registry()

    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var cancelled: Set<UUID> = []

    func associate(_ id: UUID, _ p: Process) {
        lock.lock(); defer { lock.unlock() }
        processes[id] = p
    }

    func clear(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        processes.removeValue(forKey: id)
        cancelled.remove(id)
    }

    func isCancelled(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(id)
    }

    /// Flags `id` as cancelled (effective even before the process starts) and
    /// interrupts + terminates the process if one is in flight.
    @discardableResult
    func requestCancel(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        cancelled.insert(id)
        guard let p = processes[id] else { return false }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { p.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if p.isRunning { p.terminate() }
        }
        return true
    }
}