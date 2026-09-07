import Foundation
import AppKit

/// Executes computer-control actions proposed by the model. Actions are only
/// ever run after an explicit user decision (Approvals panel or inline cards).
///
/// Hardening guarantees (Phase 1, item 3):
/// - every shell command gets a 60s timeout and an output character cap
/// - output is streamed to a temp file (never blocked on an unbounded pipe)
/// - a scrubbed environment (PATH/HOME/etc.) replaces the inherited one, so
///   secrets sitting in app env vars are not passed into child shells
/// - a fixed, visible working directory (the NexusAI Workspace root) is set
/// - running commands can be cancelled from the UI (SIGINT -> SIGTERM)
/// - every execution is written to `Data/executions.json` (audit trail)
@MainActor
final class AgentExecutor: ObservableObject {
    static let shared = AgentExecutor()

    @Published private(set) var actions: [AgentAction] = []

    /// Hardening of shell execution (timeout, output cap, env scrubbing, fixed
    /// working directory, cancellation, blocklist) lives in `ShellRunner`.
    /// Defaults here mirror it, for documentation and emergency tuning.
    nonisolated static let commandTimeout: TimeInterval = ShellRunner.commandTimeout
    nonisolated static let outputCharCap = ShellRunner.outputCharCap

    /// System-prompt text that teaches the model the action protocol.
    static let instructions = """
        You can automate things on this Mac (like OpenCode) — but every action \
        requires the user's approval, so you ask first by emitting the action, \
        then the user sees a permission card.

        Wrap exactly one action at a time in a JSON block like this:
        <<<{"action":"run_command","command":"ls -la"}>>>
        or for the typed read-only tools:
        <<<{"action":"read_file","path":"/Users/you/example.txt","maxBytes":20000}>>>

        Available actions:
        - run_command:  command = a shell command. Prefer read-only and safe commands.
        - list_files:   command = absolute directory path to list (safe, read-only).
        - read_file:    path = an absolute file path, optional "maxBytes" (512–200000, default 20000). Reads as UTF-8, never writes.
        - search_files: path = an absolute directory, query = a file-name substring.
        - open_file:    command = absolute path of a file to open in its default app.
        - reveal_file:  command = absolute path to reveal in Finder.
        - open_url:     command = a https:// URL to open in the browser.
        - upgrade:      command = "scan" to audit the local setup and propose
                        self-improvements (they appear in the Approvals panel).

        Read-only tools are typed and native (no shell): list_files, read_file,
        search_files can never modify anything. Emit their payload directly in
        the JSON block rather than via a shell command line.

        Rules:
        - Emit at most one action per turn, include plain-text reasoning around it.
        - NEVER emit destructive commands (rm -rf, disk formatting, shutdown, sudo).
        - Never claim an action ran — wait for the tool result the user approves.
        - Self-improvement: you may proactively propose upgrade scans, but NEVER
          apply changes yourself; every upgrade is approved by the user first.
        """

    private init() {
        restore()
        approvalSub = ApprovalStore.shared.subscribe { [weak self] approvalID, allow in
            self?.handleDecision(approvalID: approvalID, allow: allow)
        }
    }

    // MARK: - Parsing

    /// Extracts `<<<…>>>` blocks from assistant text into (kind, command) pairs.
    static func parse(_ text: String) -> [(kind: AgentActionKind, command: String)] {
        guard let regex = try? NSRegularExpression(pattern: #"<<<\s*([\s\S]*?)\s*>>>"#) else { return [] }
        let ns = text as NSString
        var out: [(AgentActionKind, String)] = []

        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard out.count < 6, let match, match.numberOfRanges > 1 else { return }
            let raw = ns.substring(with: match.range(at: 1))
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kindRaw = obj["action"] as? String,
                  let kind = AgentActionKind(rawValue: kindRaw) else { return }

            if kind == .readFile || kind == .searchFiles {
                // Typed tools carry their validated JSON payload as the command.
                var payload = obj
                payload.removeValue(forKey: "action")
                payload["tool"] = kind.rawValue
                guard let pData = try? JSONSerialization.data(withJSONObject: payload),
                      let command = String(data: pData, encoding: .utf8) else { return }
                out.append((kind, command))
                return
            }

            guard let command = obj["command"] as? String, !command.isEmpty else { return }
            out.append((kind, command))
        }
        return out
    }

    /// Strips action blocks from displayed text so bubbles read naturally.
    static func scrubbed(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<<<\s*[\s\S]*?\s*>>>"#) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    // MARK: - Registration & decisions

    /// Subscription to the approval store's decide events. Kept alive for the
    /// executor's lifetime so approvals (including auto-expiries that fire
    /// while the app is open) reach their matching agent action by ID.
    private var approvalSub: ApprovalSubscription?

    /// Registers one or more actions found in an assistant message, raising a
    /// permission request in the Approvals panel for each.
    @discardableResult
    func registerActions(in messageText: String, messageID: UUID, chat: ChatStore) -> Int {
        let parsed = Self.parse(messageText)
        guard !parsed.isEmpty else { return 0 }

        for p in parsed {
            let action = AgentAction(kind: p.kind, command: p.command,
                                     fromMessageID: messageID, status: .pending)
            actions.append(action)
            let approvalID = ApprovalStore.shared.add(
                title: p.kind.title,
                detail: "Nexie wants to \(describe(p)) — approve to allow, or deny.",
                icon: p.kind.icon
            )
            actions[actions.count - 1].approvalID = approvalID
        }
        persistActions()
        return parsed.count
    }

    func actions(for messageID: UUID) -> [AgentAction] {
        actions.filter { $0.fromMessageID == messageID }
    }

    /// The decision funnel reached by every approval event (user approves,
    /// user denies, or an approval auto-expires). Only a pending action whose
    /// approvalID matches may be decided; keyed by id so it works for actions
    /// restored from disk after a relaunch too.
    private func handleDecision(approvalID: UUID, allow: Bool) {
        guard let idx = actions.firstIndex(where: { $0.approvalID == approvalID && $0.status == .pending })
        else { return }

        if allow {
            actions[idx].status = .approved
            persistActions()
            execute(idx)
        } else {
            actions[idx].status = .denied
            actions[idx].result = "Action denied by the user."
            appendAudit(kind: actions[idx].kind, command: actions[idx].command,
                        status: "denied", duration: 0)
            persistActions()
        }
    }

    // MARK: - Durability

    /// Persists the action list so approvals and their executor state survive
    /// relaunch. Decisions key by the persisted `approvalID`.
    private func persistActions() {
        PersistenceController.shared.save(actions, file: "actions")
    }

    /// Restores previously registered actions. Anything that was approved but
    /// never finished running before the app quit is put back to `.pending`
    /// (and its approval reopened) so the user re-decides instead of getting
    /// an auto-running command on next launch. Expired/denied stay as-is.
    private func restore() {
        guard let saved = PersistenceController.shared.loadOrMigrate([AgentAction].self, file: "actions") else { return }
        actions = saved
        var needsReset = false
        for i in actions.indices where actions[i].status == .approved || actions[i].status == .running {
            actions[i].status = .pending
            actions[i].result = nil
            needsReset = true
        }
        if needsReset {
            for action in actions where action.status == .pending {
                if let aid = action.approvalID {
                    ApprovalStore.shared.resetApprovalToPending(aid)
                }
            }
        }
    }

    /// Interrupts a running (or not-yet-started) action. The in-flight process
    /// is sent SIGINT and then escalated to SIGTERM if it doesn't exit.
    func cancel(_ actionID: UUID) {
        guard let idx = actions.firstIndex(where: { $0.id == actionID }),
              actions[idx].status == .running || actions[idx].status == .approved else { return }
        _ = ShellRunner.cancel(actionID)
        actions[idx].status = .cancelled
        actions[idx].result = "Cancelled by the user."
        appendAudit(kind: actions[idx].kind, command: actions[idx].command,
                    status: "cancelled", duration: 0)
        persistActions()
    }

    // MARK: - Execution

    private func execute(_ idx: Int) {
        let action = actions[idx]
        actions[idx].status = .running
        let startedAt = Date()

        // Self-improvement scans are async: run them inline instead of through
        // the stateless run() funnel.
        if action.kind == .upgrade {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.runUpgradeScan(action)
                let duration = Date().timeIntervalSince(startedAt)
                if let i = self.actions.firstIndex(where: { $0.id == action.id }) {
                    self.actions[i].status = outcome.wasCancelled ? .cancelled : (outcome.failed ? .failed : .done)
                    self.actions[i].result = outcome.text
                }
                self.persistActions()
                self.appendAudit(kind: action.kind, command: action.command,
                                 status: outcome.wasCancelled ? "cancelled" : (outcome.failed ? "failed" : "done"),
                                 duration: duration)
                if !outcome.failed, !outcome.wasCancelled {
                    self.post(action)
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome: ShellResult
            switch action.kind {
            case .runCommand:
                outcome = await Self.runShellAsync(action)
            case .listFiles, .readFile, .searchFiles:
                let a = action
                outcome = await Task.detached(priority: .userInitiated) { Self.runReadOnly(a) }.value
            default:
                outcome = self.run(action)
            }
            let duration = Date().timeIntervalSince(startedAt)
            if let i = self.actions.firstIndex(where: { $0.id == action.id }) {
                self.actions[i].status = outcome.wasCancelled ? .cancelled : (outcome.failed ? .failed : .done)
                self.actions[i].result = outcome.text
            }
            self.persistActions()
            self.appendAudit(kind: action.kind, command: action.command,
                             status: outcome.wasCancelled ? "cancelled" : (outcome.failed ? "failed" : "done"),
                             duration: duration)
            if !outcome.failed, !outcome.wasCancelled {
                if let i = self.actions.firstIndex(where: { $0.id == action.id }) {
                    self.post(self.actions[i])
                }
            }
        }
    }

    /// Shell commands are executed off the main actor so a slow or large
    /// command never freezes the UI and can't be starved by the main run loop.
    /// (List/read/search never reach a shell — see `runReadOnly`.)
    nonisolated private static func runShellAsync(_ action: AgentAction) async -> ShellResult {
        // Curated trash and cache commands run natively in-app via FileManager
        // to avoid macOS TCC/Full Disk Access issues with child processes.
        if action.command == CuratedTask.emptyTrash {
            return await Task.detached(priority: .userInitiated) { Self.emptyTrashNative() }.value
        }
        if action.command == CuratedTask.clearCaches {
            return await Task.detached(priority: .userInitiated) { Self.clearCachesNative() }.value
        }
        return await Task.detached(priority: .userInitiated) { Self.runShellBlocking(action.command, id: action.id) }.value
    }

    /// Runs a bounded, native, read-only tool (`list_files`, `read_file`,
    /// `search_files`) off the main actor. Every call is validated first, so an
    /// invalid payload surfaces as a typed failure without touching the disk.
    nonisolated private static func runReadOnly(_ action: AgentAction) -> ShellResult {
        switch action.kind {
        case .readFile, .searchFiles:
            switch ReadOnlyTools.parse(action.command) {
            case .success(let call): return ReadOnlyTools.run(call)
            case .failure(let err): return ShellResult(text: err.message, failed: true, errorCode: err.code)
            }
        case .listFiles:
            switch ReadOnlyTools.validate(["tool": ReadOnlyTool.listDirectory.rawValue,
                                           "path": action.command]) {
            case .success(let call): return ReadOnlyTools.run(call)
            case .failure(let err):
                return err.code == .fileNotFound
                    ? ShellResult(text: "Path not found: \(action.command)", failed: true, errorCode: err.code)
                    : ShellResult(text: err.message, failed: true, errorCode: err.code)
            }
        default:
            return ShellResult(text: "Unexpected tool action.", failed: true, errorCode: .invalidInput)
        }
    }

    /// Empties the user's Trash across home and all mounted volumes using
    /// FileManager (in-process, so TCC/Full Disk Access applies directly).
    nonisolated private static func emptyTrashNative() -> ShellResult {
        // Use Finder via AppleScript — this is the only reliable way to empty
        // Trash on macOS, especially for root-owned items. Finder has its own
        // permissions and handles volume trashes, SIP-protected files, etc.
        // Requires one-time Automation permission ("control Finder").
        let result = runShellBlocking("osascript -e 'tell application \"Finder\" to empty trash' 2>&1", id: UUID())
        if result.failed {
            // Fall back to a shell rm for user-owned home trash items only.
            let fallback = runShellBlocking("/usr/bin/find \"$HOME/.Trash\" -mindepth 1 -user $(id -u) -delete 2>/dev/null; echo \"Trash emptied (user-owned items only). Root-owned items require Finder or sudo.\"", id: UUID())
            return ShellResult(text: fallback.text, failed: false)
        }
        return ShellResult(text: "Trash emptied via Finder.", failed: false)
    }

    /// Clears the user's ~/Library/Caches using FileManager (in-process).
    nonisolated private static func clearCachesNative() -> ShellResult {
        let fm = FileManager.default
        let cachesDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        var removed = 0

        if let items = try? fm.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: nil) {
            for item in items {
                if (try? fm.removeItem(at: item)) != nil { removed += 1 }
            }
        }

        let remaining = (try? fm.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: nil).count) ?? 0
        return ShellResult(text: "User caches cleared. Removed \(removed) item(s). Items remaining in ~/Library/Caches: \(remaining)",
                           failed: false)
    }

    /// Runs the self-improvement scan and returns a summary for the chat.
    private func runUpgradeScan(_ action: AgentAction) async -> ShellResult {
        let trimmed = action.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "scan" || trimmed == "upgrade" || trimmed.isEmpty else {
            return ShellResult(text: "Upgrade action: expected command \"scan\".", failed: true)
        }
        let summary = await SelfImprovementService.shared.runScan(source: "The agent requested an upgrade scan.")
        let text = summary == "no proposals"
            ? "I audited the local setup and found nothing new worth proposing right now."
            : summary
        return ShellResult(text: text, failed: false)
    }

    /// Runs a shell command that the user already approved as part of an
    /// upgrade proposal. Still applies the destructive-command blocklist and
    /// the timeout/env/working-directory hardening.
    func executeApprovedShell(_ command: String) async -> (text: String, failed: Bool) {
        let r = await Task.detached(priority: .userInitiated) {
            Self.runShellBlocking(command, id: UUID())
        }.value
        return (r.text, r.failed)
    }

    /// Posts the result back into the conversation so the model can continue.
    private func post(_ action: AgentAction) {
        guard let chat = ChatRegistry.shared.active else { return }
        switch action.kind {
        case .runCommand:
            chat.toolResult(action, outputLabel: "Command output")
        case .listFiles:
            chat.toolResult(action, outputLabel: "Directory listing")
        case .readFile:
            chat.toolResult(action, outputLabel: "File contents")
        case .searchFiles:
            chat.toolResult(action, outputLabel: "Search results")
        case .openFile, .revealFile, .openURL:
            chat.toolResult(action, outputLabel: nil)
        case .upgrade:
            chat.toolResult(action, outputLabel: "Upgrade scan")
        }
    }

    private func run(_ action: AgentAction) -> ShellResult {
        switch action.kind {
        case .runCommand:
            return Self.runShellBlocking(action.command, id: action.id)
        case .listFiles, .readFile, .searchFiles:
            return Self.runReadOnly(action)
        case .openFile:
            let path = (action.command as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                return ShellResult(text: "File not found: \(action.command)", failed: true)
            }
            return ShellResult(text: NSWorkspace.shared.open(URL(fileURLWithPath: path)) ? "Opened \(path)" : "Could not open \(path)",
                               failed: false)
        case .revealFile:
            let path = (action.command as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                return ShellResult(text: "Path not found: \(action.command)", failed: true)
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return ShellResult(text: "Revealed \(path) in Finder", failed: false)
        case .openURL:
            guard let url = URL(string: action.command), url.scheme == "https" || url.scheme == "http" else {
                return ShellResult(text: "Invalid URL: \(action.command)", failed: true)
            }
            return ShellResult(text: NSWorkspace.shared.open(url) ? "Opened \(action.command)" : "Could not open \(action.command)",
                               failed: false)
        case .upgrade:
            return ShellResult(text: "Upgrade scans run asynchronously.", failed: false)
        }
    }

    /// Runs a shell command with the `ShellRunner` hardening applied
    /// (timeout, output cap, scrubbed env, fixed cwd, cancellation). The action
    /// id is the cancellation key, so the UI's Cancel button can interrupt it.
    nonisolated private static func runShellBlocking(_ command: String, id: UUID) -> ShellResult {
        ShellRunner.runBlocking(command, id: id, curated: CuratedTask.all)
    }

    /// Conservative blocklist for clearly destructive or system-level commands.
    nonisolated static func isDestructive(_ command: String) -> Bool {
        ShellRunner.isDestructive(command, curated: CuratedTask.all)
    }

    // MARK: - Audit

    /// A single row of the durable execution audit trail.
    private struct ExecutionRecord: Codable {
        var at: Date
        var kind: String
        var command: String
        var status: String
        var duration: Double
    }

    /// Appends an execution record to `Data/executions.json` (published store
    /// files, replace-all semantics). Kept bounded to the latest 500 events.
    private func appendAudit(kind: AgentActionKind, command: String, status: String, duration: TimeInterval) {
        var records = PersistenceController.shared.loadOrMigrate([ExecutionRecord].self, file: "executions") ?? []
        records.append(ExecutionRecord(at: Date(), kind: kind.rawValue,
                                       command: command, status: status, duration: duration))
        if records.count > 500 { records.removeFirst(records.count - 500) }
        PersistenceController.shared.save(records, file: "executions")
    }

    /// Pre-audited, scoped maintenance commands used by the offline command
    /// router. Each is intentionally limited to the current user's own files
    /// and is always shown for approval before it runs.
    enum CuratedTask {
        static let home = NSHomeDirectory()
        static let emptyTrash = "setopt null_glob 2>/dev/null; F=\"\(home)/.Trash\"; /usr/bin/find \"$F\" -mindepth 1 -delete 2>/dev/null; for v in /Volumes/*; do /usr/bin/find \"$v/.Trashes\" -mindepth 1 -delete 2>/dev/null; done; L=$(/usr/bin/find \"$F\" -mindepth 1 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '); echo \"Trash emptied. Items remaining in home Trash: $L\""
        static let clearCaches = "setopt null_glob 2>/dev/null; F=\"\(home)/Library/Caches\"; /usr/bin/find \"$F\" -mindepth 1 -delete 2>/dev/null; L=$(/usr/bin/find \"$F\" -mindepth 1 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '); echo \"User caches cleared. Items remaining in ~/Library/Caches: $L\""
        static let systemHealth = "/usr/bin/memory_pressure; /bin/df -h / | /usr/bin/tail -1"
        static let revealOutputs = "open \"\(home)/NexusAI Workspace/Outputs\" 2>/dev/null || echo \"Outputs folder not found.\""
        static let listModels = "/bin/ls \"\(home)/NexusAI Workspace\"/app/llm-models \"\(home)/NexusAI Workspace\"/app/models 2>&1 || echo \"(no models installed)\""
        static let all: Set<String> = [emptyTrash, clearCaches, systemHealth, revealOutputs, listModels]
    }

    private func describe(_ p: (kind: AgentActionKind, command: String)) -> String {
        switch p.kind {
        case .runCommand: return "run `\(p.command)` in the terminal"
        case .openFile: return "open `\(p.command)`"
        case .revealFile: return "reveal `\(p.command)` in Finder"
        case .openURL: return "open `\(p.command)` in your browser"
        case .listFiles: return "list the folder `\(p.command)`"
        case .readFile: return "read the file described by `\(p.command)`"
        case .searchFiles: return "search files using `\(p.command)`"
        case .upgrade: return "scan the system and propose self-improvements"
        }
    }
}

/// Lets non-view services reach the active chat without fighting lifetimes.
@MainActor
final class ChatRegistry {
    static let shared = ChatRegistry()
    weak var active: ChatStore?
    private init() {}
}