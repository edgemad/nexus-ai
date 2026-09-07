import Foundation

/// Phase 8 coordinator: plans a multi-step goal into a DAG of typed nodes,
/// executes it with approvals, retries, and caching, and keeps every run
/// durable so the Run Inspector can audit or resume it after a relaunch.
///
/// Execution rules:
/// - `.prompt`   → answered by the local model (non-streaming, safe to rerun)
/// - `.tool`     → read-only tool, no approval required (validated natively)
/// - `.shell`    → requires a fresh user approval; denied ⇒ node skipped
/// - `.join`     → folds upstream results into a summary, no external work
/// - failed nodes stay cached; `retry` re-queues them (max 3 attempts)
/// - succeeded results are never re-executed
@MainActor
final class TaskGraphEngine: ObservableObject {
    @Published private(set) var runs: [TaskGraphRun] = []
    @Published private(set) var isRunning = false

    static let shared = TaskGraphEngine()

    static let maxAttempts = 3
    private let storageFile = "graphs"

    private var runnerTasks: [UUID: Task<Void, Never>] = [:]
    /// nodeID → continuation awaiting a user approval verdict.
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// approvalID → nodeID so ApprovalStore decisions route back to the graph.
    private var approvalsByNode: [UUID: UUID] = [:] // nodeID → approvalID
    private var decisionSubscription: ApprovalSubscription?
    private let llm = LLMService()

    private init() {
        if let saved = PersistenceController.shared.loadOrMigrate([TaskGraphRun].self, file: storageFile) {
            runs = saved
        }
        decisionSubscription = ApprovalStore.shared.subscribe { [weak self] approvalID, allow in
            Task { @MainActor in
                guard let self else { return }
                guard let nodeID = self.approvalsByNode.first(where: { $0.value == approvalID })?.key else { return }
                self.approvalsByNode[nodeID] = nil
                guard let cont = self.waiters[nodeID] else { return }
                self.waiters[nodeID] = nil
                cont.resume(returning: allow)
            }
        }
    }

    // MARK: - Graph lifecycle

    /// Adds a validated graph. Throws `NexusError(.invalidInput, ...)` when the
    /// graph has cycles or dangling dependencies.
    @discardableResult
    func create(title: String, goal: String, nodes: [TaskNode]) throws -> TaskGraphRun {
        let graph = TaskGraphRun(title: title, goal: goal, nodes: nodes)
        guard TaskGraphScheduler.isWellFormed(graph) else {
            throw NexusError(.invalidInput, "Task graph is not a valid DAG (cycle or unknown dependency).")
        }
        runs.insert(graph, at: 0)
        persist()
        return graph
    }

    /// Schemes a dependency graph straight from a plain-language goal using the
    /// local model. If the model does not answer with structured JSON (or llama
    /// is offline) it degrades to a single `.prompt` node rather than failing.
    func importPlan(from prompt: String) async -> TaskGraphRun {
        let planner: [LLMMessage] = [
            LLMMessage(role: "system", content: TaskGraphEngine.planInstructions),
            LLMMessage(role: "user", content: "Goal: \(prompt)")
        ]
        let reply = await llm.complete(messages: planner)
        var nodes = buildPlanNodes(from: reply)
        if nodes.isEmpty {
            nodes = [TaskNode(title: "Answer", kind: .prompt, payload: prompt)]
        }
        return try! create(
            title: compactTitle(from: prompt),
            goal: prompt,
            nodes: nodes
        )
    }

    static let planInstructions = """
    You are a task planner. Convert the goal into a small dependency graph.
    Respond with ONLY valid JSON — no prose, no markdown fences — in this exact shape:
    {"title":"<short title>","steps":[{"title":"<label>","kind":"prompt|shell|tool|join","payload":"<instruction>","deps":[<0-based step indexes>]}]}
    Rules:
    - "prompt": a self-contained question the local model must answer.
    - "shell": exactly one concrete command string (it will require user approval).
    - "tool": a read-only tool call, JSON literal, e.g. {"tool":"list_directory","path":"/Users/you"} or {"tool":"read_file","path":"/Users/you/a.txt","maxBytes":20000} or {"tool":"search_files","path":"/Users/you","query":"report"}.
    - "join": summarize the outputs of its declared dependencies.
    - deps lists which earlier steps this step needs first; omit for start steps.
    - At most 6 steps. Keep dependencies minimal and acyclic.
    """

    /// Deletes a run (and any in-flight runner).
    func remove(_ graphID: UUID) {
        cancel(graphID)
        runs.removeAll { $0.id == graphID }
        persist()
    }

    func removeAllFinished() {
        runnerTasks.keys.forEach { runnerTasks[$0]?.cancel() }
        runnerTasks.removeAll()
        runs.removeAll { $0.status != .running && $0.status != .awaitingApproval }
        persist()
    }

    // MARK: - Execution control

    /// Starts (or resumes) a run. Nodes still `running`/`awaitingApproval` from
    /// a previous launch are folded back to `pending`, approvals re-requested.
    func start(_ graphID: UUID) {
        guard runnerTasks[graphID] == nil,
              let idx = runs.firstIndex(where: { $0.id == graphID }) else { return }
        guard runs[idx].status != .completed else { return }
        isRunning = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runGraph(graphID)
        }
        runnerTasks[graphID] = task
    }

    /// Re-runs the failed nodes of a settled run. Already succeeded nodes keep
    /// their cached results.
    func retry(_ graphID: UUID) {
        guard let idx = runs.firstIndex(where: { $0.id == graphID }) else { return }
        var updated = false
        for i in runs[idx].nodes.indices {
            guard runs[idx].nodes[i].status == .failed,
                  runs[idx].nodes[i].attempts < Self.maxAttempts else { continue }
            runs[idx].nodes[i].status = .pending
            runs[idx].nodes[i].result = nil
            updated = true
        }
        guard updated else { return }
        runs[idx].status = .drafted
        runs[idx].updatedAt = Date()
        persist()
        start(graphID)
    }

    func cancel(_ graphID: UUID) {
        guard let idx = runs.firstIndex(where: { $0.id == graphID }) else { return }
        runnerTasks[graphID]?.cancel()
        runnerTasks[graphID] = nil
        for i in runs[idx].nodes.indices {
            let node = runs[idx].nodes[i].id
            waiters[node]?.resume(returning: false)
            waiters[node] = nil
            if runs[idx].nodes[i].status == .running || runs[idx].nodes[i].status == .awaitingApproval {
                runs[idx].nodes[i].status = .cancelled
                runs[idx].nodes[i].finishedAt = Date()
            } else if runs[idx].nodes[i].status == .pending {
                runs[idx].nodes[i].status = .cancelled
            }
        }
        runs[idx].status = .cancelled
        runs[idx].updatedAt = Date()
        isRunning = runnerTasks.values.contains { !$0.isCancelled }
        persist()
    }

    // MARK: - Run loop

    private func runGraph(_ graphID: UUID) async {
        defer {
            runnerTasks[graphID] = nil
            isRunning = !runnerTasks.isEmpty
        }
        while !Task.isCancelled {
            guard let idx = runs.firstIndex(where: { $0.id == graphID }) else { return }
            guard runs[idx].status != .cancelled else { return }

            if TaskGraphScheduler.isSettled(runs[idx]) {
                finalize(graphID)
                return
            }
            let ready = TaskGraphScheduler.nextReady(runs[idx])
            guard let node = ready.first else {
                // Deadlock defence: a pending node whose only unresolved dep is
                // failed/skipped/cancelled can never run.
                markBlocked(graphID)
                return
            }
            await execute(node: node.id, in: graphID)
        }
        // Cancelled mid-flight: mark active nodes cancelled.
        if let idx = runs.firstIndex(where: { $0.id == graphID }), runs[idx].status == .running {
            for i in runs[idx].nodes.indices where runs[idx].nodes[i].status == .running {
                runs[idx].nodes[i].status = .cancelled
            }
            runs[idx].status = .cancelled
            runs[idx].updatedAt = Date()
            persist()
        }
    }

    private func execute(node nodeID: UUID, in graphID: UUID) async {
        guard let idx = runs.firstIndex(where: { $0.id == graphID }),
              let nodeIdx = runs[idx].nodes.firstIndex(where: { $0.id == nodeID }),
              runs[idx].nodes[nodeIdx].status == .pending else { return }

        runs[idx].nodes[nodeIdx].status = .running
        runs[idx].nodes[nodeIdx].attempts += 1
        runs[idx].nodes[nodeIdx].startedAt = Date()
        runs[idx].status = .running
        runs[idx].updatedAt = Date()
        persist()

        let node = runs[idx].nodes[nodeIdx]
        var outcome: TaskNodeStatus
        var detail: String

        switch node.kind {
        case .prompt:
            (outcome, detail) = await runPrompt(node)
        case .tool:
            (outcome, detail) = await runTool(node)
        case .shell:
            // Approval-gated: a deny or expiry skips the node, not the whole run.
            let approved = await requestApproval(node: node, in: graphID)
            if Task.isCancelled {
                outcome = .cancelled
                detail = "Run cancelled while waiting for approval."
            } else if approved {
                (outcome, detail) = await runShell(node)
            } else {
                outcome = .skipped
                detail = "Approval denied or expired."
            }
        case .join:
            (outcome, detail) = runJoin(node, in: graphID)
        }

        guard let idx = runs.firstIndex(where: { $0.id == graphID }),
              let nodeIdx = runs[idx].nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        runs[idx].nodes[nodeIdx].status = outcome
        runs[idx].nodes[nodeIdx].result = detail
        runs[idx].nodes[nodeIdx].finishedAt = Date()
        runs[idx].updatedAt = Date()
        persist()
    }

    // MARK: - Node runners

    private func runPrompt(_ node: TaskNode) async -> (TaskNodeStatus, String) {
        let llm = LLMService()
        let messages = [
            LLMMessage(role: "system", content: "You are Nexus AI. Answer the task node directly and concisely. Do not emit tool calls."),
            LLMMessage(role: "user", content: node.payload)
        ]
        let reply = await llm.complete(messages: messages)
        if reply.isEmpty {
            return (.failed, "No model response (is the local llama-server reachable?)")
        }
        return (.succeeded, reply)
    }

    private func runTool(_ node: TaskNode) async -> (TaskNodeStatus, String) {
        guard let data = node.payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (.failed, "Tool node payload is not valid JSON: \(node.payload)")
        }
        switch ReadOnlyTools.validate(obj) {
        case .failure(let error):
            return (.failed, error.message)
        case .success(let call):
            let result = await Task.detached { ReadOnlyTools.run(call) }.value
            if result.failed {
                return (.failed, result.text)
            }
            return (.succeeded, result.text)
        }
    }

    private func requestApproval(node: TaskNode, in graphID: UUID) async -> Bool {
        let approvalID = ApprovalStore.shared.add(
            title: "Approve task step: \(node.title)",
            detail: node.payload,
            icon: "point.3.connected.trianglepath.dotted"
        )
        approvalsByNode[node.id] = approvalID
        return await withCheckedContinuation { cont in
            waiters[node.id] = cont
        }
    }

    private func runShell(_ node: TaskNode) async -> (TaskNodeStatus, String) {
        let result = await Task.detached {
            ShellRunner.runBlocking(node.payload, id: UUID())
        }.value
        if result.wasCancelled {
            return (.cancelled, result.text)
        }
        if result.failed {
            return (.failed, result.text)
        }
        return (.succeeded, result.text)
    }

    private func runJoin(_ node: TaskNode, in graphID: UUID) -> (TaskNodeStatus, String) {
        guard let graph = runs.first(where: { $0.id == graphID }) else { return (.failed, "Graph gone.") }
        var parts: [String] = []
        for depID in node.dependencies {
            guard let dep = graph.nodes.first(where: { $0.id == depID }),
                  dep.status == .succeeded, let depResult = dep.result, !depResult.isEmpty else { continue }
            parts.append("— \(dep.title) —\n\(depResult)")
        }
        guard !parts.isEmpty else { return (.failed, "Join had no succeeded dependencies to fold.") }
        return (.succeeded, parts.joined(separator: "\n\n"))
    }

    // MARK: - Finalization

    private func finalize(_ graphID: UUID) {
        guard let idx = runs.firstIndex(where: { $0.id == graphID }),
              runs[idx].status != .completed else { return }
        let anyFailure = runs[idx].nodes.contains { $0.status == .failed }
        runs[idx].status = anyFailure ? .failed : .completed
        runs[idx].resultSummary = summarize(runs[idx])
        runs[idx].updatedAt = Date()
        persist()
    }

    private func markBlocked(_ graphID: UUID) {
        guard let idx = runs.firstIndex(where: { $0.id == graphID }) else { return }
        runs[idx].status = .failed
        runs[idx].resultSummary = "Execution blocked: no step can proceed (an upstream step failed or was skipped)."
        runs[idx].updatedAt = Date()
        persist()
    }

    private func summarize(_ graph: TaskGraphRun) -> String {
        let parts = graph.nodes
            .filter { $0.status == .succeeded && $0.result?.isEmpty == false }
            .compactMap { node -> String? in
                var body = node.result ?? ""
                if body.count > 1200 { body = String(body.prefix(1200)) + "…" }
                return "## \(node.title)\n\(body)"
            }
        guard !parts.isEmpty else { return "No successful steps." }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - LLM plan parsing

    /// Extracts the JSON blob a planner model returns and turns it into nodes.
    /// Returns `[]` on any malformed input (caller falls back to a single
    /// `prompt` node instead of failing the whole import).
    private func buildPlanNodes(from reply: String) -> [TaskNode] {
        let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start < end,
              let data = String(cleaned[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = obj["steps"] as? [[String: Any]], !steps.isEmpty else {
            return []
        }

        var nodes: [TaskNode] = []
        for step in steps {
            let rawKind = (step["kind"] as? String ?? "prompt").lowercased()
            let kind: TaskNodeKind
            switch rawKind {
            case "shell": kind = .shell
            case "tool": kind = .tool
            case "join": kind = .join
            default: kind = .prompt
            }
            let payload: String
            if kind == .tool, let objValue = step["payload"] as? [String: Any] {
                payload = (try? JSONSerialization.data(withJSONObject: objValue))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            } else {
                payload = (step["payload"] as? String) ?? ""
            }
            let label = (step["title"] as? String ?? payload)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            nodes.append(TaskNode(
                title: String(label.prefix(60)),
                kind: kind,
                payload: payload.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        // Resolve 0-based index deps (["deps":[0,1]]) against the node ids.
        for (i, step) in steps.enumerated() {
            guard i < nodes.count else { continue }
            var resolved: [UUID] = []
            for raw in (step["deps"] as? [Int]) ?? [] where raw < nodes.count && raw != i {
                resolved.append(nodes[raw].id)
            }
            guard !resolved.isEmpty else { continue }
            var update = nodes[i]
            update.dependencies = resolved
            nodes[i] = update
        }
        return nodes
    }

    private func compactTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 48 { return trimmed }
        return String(trimmed.prefix(48)) + "…"
    }

    // MARK: - Persistence

    private func persist() {
        PersistenceController.shared.save(runs, file: storageFile)
    }
}