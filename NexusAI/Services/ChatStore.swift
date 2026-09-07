import Foundation
import SwiftUI

/// How to approach each question: how much web research and depth to use.
enum AnswerMode: String, CaseIterable, Identifiable {
    case quick = "Quick"
    case research = "Research"
    case deep = "Deep"
    var id: String { rawValue }
}

/// Central manager for multiple chat windows (sessions), memory, and dispatch
/// to the local LLM backend or the rule-based fallback.
@MainActor
final class ChatStore: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var activeID: UUID?
    @Published var isProcessing = false
    @Published var memoryFacts: [String] = []
    /// Live response-generation progress. `responseTokens` counts characters
    /// streamed; `responsePercent` is tokens against the max_tokens ceiling so
    /// the UI can show a determinate percentage while the model answers.
    @Published private(set) var responseTokens = 0
    @Published private(set) var responsePercent: Double = 0
    @Published var isResponding = false
    /// When on, the model may propose computer-control actions that the user
    /// must approve before they run.
    @Published var computerControl = false

    /// Per-question depth: Quick (minimal research), Research (web + citations),
    /// or Deep (multi-step, comparisons). Persisted app-wide.
    @Published var answerMode: AnswerMode {
        didSet { UserDefaults.standard.set(answerMode.rawValue, forKey: "answerMode") }
    }

    let llm = LLMService()
    /// Cloud LLM providers (OpenAI, Google, Claude, OpenRouter, custom). Used
    /// when the user configures a provider in Settings; otherwise local runs.
    let cloud = CloudProviderStore.shared
    let web = WebSearch()
    let knowledge = KnowledgeStore.shared
    let selfImprovement = SelfImprovementService.shared
    private let fallback = ChatEngine()
    private let workspace = WorkspaceManager.shared
    /// Running count of tool-follow-up passes since the last user message,
    /// capped so the agent can't loop forever.
    private var toolSteps = 0
    private let maxToolSteps = 4
    /// The in-flight exchange task; kept so "Stop" can cancel a reply in
    /// progress (stops streaming and web research immediately).
    private var exchangeTask: Task<Void, Never>?

    /// What the assistant last offered (e.g. generate audio for a reply) so a
    /// short "yes"/"no" can act on it instead of becoming a standalone query.
    private enum PendingOffer {
        case audioReply(String)
        case polishDraft
    }
    private var pendingOffer: PendingOffer?
    /// Optional hook set by the UI so the affirmative handler can actually play
    /// the offered audio for a prior reply.
    var audioGenerator: (() -> Void)?

    var activeSession: ChatSession? {
        sessions.first { $0.id == activeID }
    }

    var pinnedSessions: [ChatSession] {
        sessions.filter { $0.isPinned && !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var normalSessions: [ChatSession] {
        sessions.filter { !$0.isPinned && !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var archivedSessions: [ChatSession] {
        sessions.filter { $0.isArchived }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "answerMode"),
           let mode = AnswerMode(rawValue: raw) {
            answerMode = mode
        } else {
            answerMode = .research
        }
        ChatRegistry.shared.active = self
        workspace.ensure()
        load()
        if sessions.isEmpty { _ = newChat() }
        activeID = sessions.first?.id
        loadMemory()
    }

    private func load() {
        sessions = workspace.loadChats()
    }

    /// Remembers the last-flushed signature of each session so untouched sessions
    /// are skipped during bulk saves (turning O(sessionCount) I/O into O(changed)).
    private var lastFlushed: [UUID: String] = [:]

    private func signature(_ session: ChatSession) -> String {
        guard let last = session.messages.last else {
            return "|\(session.title)|0|"
        }
        return "\(session.title)|\(session.messages.count)|\(last.id)|\(last.role)|\(last.text.count)"
    }

    func persist() {
        for session in sessions where !session.isArchived {
            if lastFlushed[session.id] == signature(session) {
                continue
            }
            guard (try? workspace.saveChat(session)) != nil else { continue }
            lastFlushed[session.id] = signature(session)
        }
        for session in sessions where session.isArchived {
            workspace.deleteChatFile(session)
        }
    }

    /// Persists only the given session (plus archive cleanup). Hot per-message
    /// paths use this so a single exchange costs one atomic write instead of
    /// one write per open session.
    @discardableResult
    func persist(_ sessionID: UUID) -> Bool {
        var saved = false
        for session in sessions where session.id == sessionID {
            if session.isArchived {
                workspace.deleteChatFile(session)
            } else if (try? workspace.saveChat(session)) != nil {
                lastFlushed[session.id] = signature(session)
                saved = true
            }
        }
        for session in sessions where session.isArchived {
            workspace.deleteChatFile(session)
        }
        return saved
    }

    // MARK: - Session management

    @discardableResult
    func newChat() -> ChatSession {
        let chat = ChatSession(title: defaultTitle())
        sessions.insert(chat, at: 0)
        activeID = chat.id
        try? workspace.saveChat(chat)
        return chat
    }

    func select(_ id: UUID) {
        activeID = id
    }

    /// Attaches (or removes) a task-specific bot for the given session.
    func setBot(_ botID: UUID?, for sessionID: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].botID = botID
        persist()
    }

    /// Attaches (or removes) a prompt preset for the given session.
    func setPreset(_ presetID: UUID?, for sessionID: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].presetID = presetID
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].title = trimmed.isEmpty ? "Untitled" : trimmed
        persist()
    }

    func delete(_ id: UUID) {
        guard let chat = sessions.first(where: { $0.id == id }) else { return }
        sessions.removeAll { $0.id == id }
        workspace.deleteChatFile(chat)
        if activeID == id { activeID = sessions.first?.id }
    }

    func archive(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let chat = sessions[idx]
        sessions[idx].isArchived = true
        workspace.deleteChatFile(chat) // moved to archive folder if desired
        workspace.archiveChat(chat)
        if activeID == id { activeID = sessions.first?.id }
    }

    func unarchive(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isArchived = false
        persist()
    }

    func togglePin(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isPinned.toggle()
        persist()
    }

    func setFolderTag(_ id: UUID, _ tag: String?) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].folderTag = tag
        persist()
    }

    private func defaultTitle() -> String {
        "Chat \(sessions.count + 1)"
    }

    // MARK: - Sending

    func send(_ text: String, webResearch: Bool = false,
              completion: ((String) -> Void)? = nil) {
        guard let session = activeSession else { return }
        isProcessing = true
        toolSteps = 0
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMsg = ChatMessage(role: .user, text: trimmed)
        append(userMsg, to: session.id)
        // Give the session a title from the first user message.
        if let idx = sessions.firstIndex(where: { $0.id == session.id }),
           sessions[idx].title.hasPrefix("Chat ") {
            trimTitle(&sessions[idx], from: trimmed)
        }

        // Short "yes"/"no" replies act on whatever Nexie just offered, instead
        // of being misread as a fresh topic (e.g. "yes" becoming the band Yes).
        if let reply = affirmativeReply(for: trimmed) {
            append(ChatMessage(role: .assistant, text: reply), to: session.id)
            isProcessing = false
            persist()
            exchangeTask = nil
            completion?(reply)
            return
        }

        // Typed tools: a leading "/command" is routed to the app's own tools
        // instead of the model, so it works even when the model is offline.
        let parsedCommand = ChatCommandParser.parse(trimmed)
        if parsedCommand != .notACommand {
            handleCommand(parsedCommand, sessionID: session.id, completion: completion)
            return
        }

        let sessionID = session.id
        runExchange(userText: trimmed, webResearch: webResearch, sessionID: sessionID,
                    completion: completion)
    }

    /// Executes a typed "/command" that bypassed the model pipeline.
    private func handleCommand(_ parsed: ChatCommandParse,
                               sessionID: UUID,
                               completion: ((String) -> Void)?) {
        switch parsed {
        case .notACommand:
            return
        case .usageError(let message):
            append(ChatMessage(role: .assistant, text: message), to: sessionID)
            isProcessing = false
            persist()
            completion?(message)
        case .action(let action):
            switch action {
            case .help:
                let text = ChatCommandParser.helpText
                append(ChatMessage(role: .assistant, text: text), to: sessionID)
                isProcessing = false
                persist()
                completion?(text)
            case .clear:
                if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
                    sessions[idx].messages.removeAll()
                }
                let text = "Session cleared."
                append(ChatMessage(role: .assistant, text: text), to: sessionID)
                isProcessing = false
                persist()
                completion?(text)
            case .research(let query):
                answerMode = .research
                runExchange(userText: query, webResearch: true,
                            sessionID: sessionID, completion: completion)
            case .deepResearch(let query):
                answerMode = .deep
                runExchange(userText: query, webResearch: true,
                            sessionID: sessionID, completion: completion)
            case .remember(let fact):
                knowledge.learnFromConversation(userText: fact, assistantText: "Stored per /remember.")
                if !memoryFacts.contains(fact) {
                    memoryFacts.append(fact)
                }
                Task {
                    _ = await MemoryServiceClient.shared.learn(userText: fact, assistantText: "Stored per /remember.")
                }
                let text = "Stored: “\(fact)”"
                append(ChatMessage(role: .assistant, text: text), to: sessionID)
                isProcessing = false
                persist()
                completion?(text)
            case .compute(let expression):
                let text: String
                if let value = ExpressionEvaluator.evaluate(expression) {
                    text = "\(expression) = \(ExpressionEvaluator.format(value))"
                } else {
                    text = "Couldn't parse “\(expression)”. Try something like /compute (4 + 6) * 3"
                }
                append(ChatMessage(role: .assistant, text: text), to: sessionID)
                isProcessing = false
                persist()
                completion?(text)
            case .eval:
                runEvalCommand(sessionID: sessionID, completion: completion)
            }
        }
    }

    /// /eval — run the golden suite against the on-device model and post the
    /// scoreboard as the reply.
    private func runEvalCommand(sessionID: UUID, completion: ((String) -> Void)?) {
        guard BackendManager.shared.isLLMRunning() else {
            let offline = "The local model isn't running, so a live eval would just score failures. Start a model, then retry /eval."
            append(ChatMessage(role: .assistant, text: offline), to: sessionID)
            isProcessing = false
            persist(sessionID)
            completion?(offline)
            return
        }
        let placeholder = "Running the golden eval suite against the local model…"
        append(ChatMessage(role: .assistant, text: placeholder), to: sessionID)
        guard let sessionIdx = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIdx = sessions[sessionIdx].messages.lastIndex(where: { $0.role == .assistant }) else {
            isProcessing = false
            persist(sessionID)
            completion?(placeholder)
            return
        }
        exchangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let board = await EvalRunner.runLive(llm: self.llm)
            let text = EvalRunner.boardSummary(board)
            self.writeStreaming(text, sessionID: sessionID, messageIndex: msgIdx)
            self.isProcessing = false
            self.persist(sessionID)
            completion?(text)
        }
    }

    /// Regenerates the last assistant reply in the given session. The most
    /// recent user message is re-sent and everything after it is discarded.
    func regenerateLast(in sessionID: UUID) {
        guard !isProcessing,
              let idx = sessions.firstIndex(where: { $0.id == sessionID }),
              let lastUser = sessions[idx].messages.last(where: { $0.role == .user }) else { return }
        // Truncate everything after that user message.
        if let pos = sessions[idx].messages.firstIndex(where: { $0.id == lastUser.id }),
           sessions[idx].messages.count > pos + 1 {
            sessions[idx].messages.removeSubrange((pos + 1)...)
        }
        persist()
        runExchange(userText: lastUser.text, webResearch: false, sessionID: sessionID)
    }

    /// ⌘R — re-run the last user query in Research mode.
    func rerunLastInResearch() {
        guard !isProcessing, let session = activeSession,
              let lastUser = session.messages.last(where: { $0.role == .user })?.text else { return }
        answerMode = .research
        send(lastUser, webResearch: true)
    }

    /// Edits a user message in place and re-runs the exchange from that point
    /// forward (anything after it is discarded).
    func editAndResend(_ messageID: UUID, newText: String, in sessionID: UUID) {
        guard !isProcessing,
              let idx = sessions.firstIndex(where: { $0.id == sessionID }),
              let pos = sessions[idx].messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard sessions[idx].messages[pos].role == .user else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[idx].messages[pos].text = trimmed
        if sessions[idx].messages.count > pos + 1 {
            sessions[idx].messages.removeSubrange((pos + 1)...)
        }
        persist()
        runExchange(userText: trimmed, webResearch: false, sessionID: sessionID)
    }

    /// Shared pipeline: optionally research, stream/fallback, persist, memorize.
    private func runExchange(userText: String, webResearch: Bool, sessionID: UUID,
                             completion: ((String) -> Void)? = nil) {
        isProcessing = true
        exchangeTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { completion?(userText); return }
            // Fast path: trivial date/time/day questions are answered instantly
            // so a simple "what's the date?" never waits on the slow local
            // model or a web round-trip, even with research on. The routing
            // brain lives in the Python sidecar; the built-in Swift versions
            // stay as fallbacks when it's offline (connection-refused returns
            // empty instantly, so this stays cheap).
            let brainIntent = await BrainServiceClient.shared.intent(
                query: userText,
                style: AssistantSettings.shared.style == .jarvis ? "jarvis" : "standard"
            )
            let instant = brainIntent.instantAnswer.isEmpty ? self.instantReply(for: userText) ?? "" : brainIntent.instantAnswer
            if !instant.isEmpty {
                self.append(ChatMessage(role: .assistant, text: instant), to: sessionID)
                self.isProcessing = false
                self.persist()
                completion?(instant)
                return
            }
            // Location questions are answered from Core Location natively, with
            // an approximate IP-derived fix from the research sidecar whenever
            // the user hasn't granted (or can't give) precise location.
            if brainIntent.needsLocation || self.asksForLocation(userText) {
                let reply = await self.locationReply()
                self.append(ChatMessage(role: .assistant, text: reply), to: sessionID)
                self.isProcessing = false
                self.persist()
                completion?(reply)
                return
            }
            // Optional web research round. Runs based on the chosen Answer mode:
            // Quick only researches when the user explicitly toggles it on and
            // the question looks live; Research/Deep always research so answers
            // stay grounded with sources.
            var research = ""
            var researchSources: [ResearchSource] = []
            var researchConfidence: Int? = nil
            // Python brain's research verdict (OR'ed with the built-in Swift
            // heuristic so behaviour is identical whether or not it is up).
            let brainResearch = brainIntent.needsResearch
            let needsResearch: Bool
            switch self.answerMode {
            // Quick: only when the user toggles research on AND the ask is live.
            case .quick:
                needsResearch = webResearch && (brainResearch || self.looksLikeResearch(userText))
            // Research / Deep: research when the question genuinely needs live
            // info (or the toggle is on) — NOT on every casual message, so
            // follow-ups and quick questions stay direct and on-topic.
            case .research, .deep:
                needsResearch = webResearch || brainResearch || self.looksLikeResearch(userText)
            }
            if needsResearch {
                // Deep mode runs multi-step research for a thorough, cited answer.
                let outcome = self.answerMode == .deep
                    ? await self.runDeepResearch(userText)
                    : await self.runWebResearch(userText)
                research = outcome.text
                researchSources = outcome.sources
                researchConfidence = outcome.confidence
            }

            let images = self.imageAttachments(in: userText)
            // Fetch long-term memory context through the Python sidecar first,
            // falling back to the built-in KnowledgeStore when it's offline.
            // (context returns "" instantly on connection-refused, so this is
            // cheap even when the sidecar is down.)
            let (pyContext, _) = await MemoryServiceClient.shared.context(query: userText)
            let memoryContext = pyContext.isEmpty ? self.knowledge.contextForPrompt(userText) : pyContext
            let history = self.historyFor(sessionID, memoryContext: memoryContext)
            let finalText: String
            // Exactly one assistant message is persisted per exchange. Streaming
            // paths append an empty placeholder once and write into it live;
            // non-streaming paths append the finished text afterwards.
            var placeholderIndex: Int? = nil
            if !research.isEmpty && images.isEmpty {
                // Research already produced a direct, on-topic answer (with
                // citations). Use it as-is instead of re-answering, so the
                // reply stays focused instead of a second wandering pass.
                finalText = research
            } else if let provider = self.cloud.effectiveProvider {
                // Cloud LLM is configured — stream from it. If it fails or
                // returns nothing, fall back to local/offline so a reply
                // always comes back.
                self.append(ChatMessage(role: .assistant, text: ""), to: sessionID)
                placeholderIndex = self.indexOfLastMessage(sessionID)
                var text = await self.streamFromProvider(history, research: research,
                                                         sessionID: sessionID, images: images,
                                                         provider: provider, messageIndex: placeholderIndex!)
                if text.isEmpty {
                    // Provider produced nothing — drop its empty placeholder and
                    // let the fallback chain own a fresh one.
                    if let i = self.sessions.firstIndex(where: { $0.id == sessionID }),
                       let pi = placeholderIndex {
                        self.sessions[i].messages.remove(at: pi)
                    }
                    self.append(ChatMessage(role: .assistant, text: ""), to: sessionID)
                    placeholderIndex = self.indexOfLastMessage(sessionID)
                    text = await self.localOrFallback(text: userText, research: research,
                                                      history: history, images: images,
                                                      sessionID: sessionID, messageIndex: placeholderIndex!,
                                                      offlineReply: brainIntent.offlineReply)
                }
                finalText = text
            } else if await self.llm.isReachable() {
                self.append(ChatMessage(role: .assistant, text: ""), to: sessionID)
                placeholderIndex = self.indexOfLastMessage(sessionID)
                finalText = await self.streamFromLocal(history, research: research,
                                                       sessionID: sessionID, images: images,
                                                       messageIndex: placeholderIndex!)
            } else if self.looksLikeResearch(userText) || !research.isEmpty {
                let offline = await self.runOfflineResearch(userText)
                finalText = offline.isEmpty
                    ? (brainIntent.offlineReply.isEmpty ? self.fallback.generateReply(to: userText) : brainIntent.offlineReply)
                    : offline
            } else {
                if self.computerControl, let agentReply = self.offlineComputerControlReply(userText) {
                    finalText = agentReply
                } else {
                    var reply = brainIntent.offlineReply.isEmpty ? self.fallback.generateReply(to: userText) : brainIntent.offlineReply
                    if !images.isEmpty {
                        reply += "\n\nNote: I found \(images.count) attached image(s), but this offline build can't read them. Connect a vision-capable local or cloud model and I'll analyze them."
                    }
                    finalText = reply
                }
            }
            // Persist the single assistant message: fill/remove the streaming
            // placeholder, or append the finished non-streamed text.
            if let pi = placeholderIndex {
                if let i = self.sessions.firstIndex(where: { $0.id == sessionID }),
                   let piUnwrapped = placeholderIndex,
                   self.sessions[i].messages.indices.contains(piUnwrapped) {
                    if finalText.isEmpty {
                        self.sessions[i].messages.remove(at: piUnwrapped)
                    } else {
                        self.sessions[i].messages[piUnwrapped].text = finalText
                        if !researchSources.isEmpty {
                            self.sessions[i].messages[piUnwrapped].sources = researchSources
                            self.sessions[i].messages[piUnwrapped].researchConfidence = researchConfidence
                        }
                    }
                }
            } else if !finalText.isEmpty {
                self.append(ChatMessage(role: .assistant, text: finalText,
                                        sources: researchSources,
                                        researchConfidence: researchConfidence), to: sessionID)
            }
            // Agent: surface any computer-control actions the reply proposes.
            if self.computerControl, !finalText.isEmpty,
               let mid = self.sessions.first(where: { $0.id == sessionID })?.messages.last?.id {
                AgentExecutor.shared.registerActions(in: finalText, messageID: mid, chat: self)
            }
            self.isProcessing = false
            self.persist()
            // Learn durable memories & knowledge from this exchange,
            // preferring the Python sidecar (authoritative writer) and keeping
            // the local KnowledgeStore in sync so the panel stays accurate.
            // (learn returns 0 instantly when the sidecar is down.)
            let learned = await MemoryServiceClient.shared.learn(userText: userText, assistantText: finalText)
            if learned == 0 {
                self.knowledge.learnFromConversation(userText: userText, assistantText: finalText)
            }
            self.knowledge.reload()
            self.remember(conversation: finalText)

            // Self-improvement: once in a while, let the AI audit the local
            // setup and float upgrade proposals (approval-gated).
            if self.computerControl {
                Task { await self.selfImprovement.runProactiveScanIfDue(chat: self) }
            }
            if Task.isCancelled { self.isProcessing = false }
            self.exchangeTask = nil
            completion?(finalText)
        }
        exchangeTask = task
    }

    /// Cancels any in-progress reply: stops streaming, web research, and clears
    /// the processing flag so the UI returns to an idle state.
    func stop() {
        exchangeTask?.cancel()
        exchangeTask = nil
        isProcessing = false
        isResponding = false
    }

    // MARK: - Computer control (agent loop)

    /// Offline intent router: when the local LLM is unreachable but computer
    /// control is on, this recognizes common system requests and turns them
    /// into permission-gated actions (same approval flow as the model agent).
    private func offlineComputerControlReply(_ text: String) -> String? {
        let t = text.lowercased()
        let C = AgentExecutor.CuratedTask.self
        var commands: [(summary: String, cmd: String)] = []

        func add(_ summary: String, _ cmd: String, dedupeWith other: String? = nil) {
            let key = other ?? cmd
            guard !commands.contains(where: { $0.cmd == key }) else { return }
            commands.append((summary, cmd))
        }

        if t.contains("trash") {
            add("Empty the Trash", C.emptyTrash)
        }
        if t.contains("cache") {
            add("Clear the user caches in ~/Library/Caches (safe to recreate)", C.clearCaches)
        }
        if t.contains("disk") || t.contains("storage") || (t.contains("space") && t.contains("free")) {
            add("Check disk space and memory pressure", C.systemHealth,
                dedupeWith: t.contains("memory") ? C.systemHealth : nil)
        }
        if t.contains("health") || t.contains("memory") || t.contains(" cpu") || t.contains("ram") {
            add("Report system health (memory + disk)", C.systemHealth, dedupeWith: C.systemHealth)
        }
        if t.contains("output") || t.contains("workspace") {
            add("Reveal the workspace Outputs folder", C.revealOutputs)
        }
        if t.contains("model") || t.contains("checkpoint") {
            add("List installed models", C.listModels)
        }

        guard !commands.isEmpty else { return nil }

        let plan = commands.enumerated()
            .map { "\($0.offset + 1). \($0.element.summary)" }
            .joined(separator: "\n")
        let blocks = commands.compactMap { c in
            (try? JSONSerialization.data(withJSONObject: ["action": "run_command", "command": c.cmd]))
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { "<<<\($0)>>>" }
        }.joined(separator: "\n")

        var note = "I'm running offline, but with Computer control I can still do this locally. "
        note += "I've prepared permission-gated steps below — approve each card to let me run it."
        if t.contains("cache") {
            note += "\n\nClearing caches removes only safe-to-recreate temp files; you may need to restart apps after."
        }
        if t.contains("trash") {
            note += "\n\nNote: emptying the Trash permanently deletes its contents."
        }
        return "\(note)\n\n\(plan)\n\n\(blocks)"
    }

    /// Appends a plain assistant note into the active session (used by the
    /// self-improvement service so proposals/results stay visible in chat).
    func injectAssistantNote(_ text: String) {
        guard let sessionID = activeSession?.id else { return }
        append(ChatMessage(role: .assistant,
                           text: "[AI self-improvement] \(text)"), to: sessionID)
        persist()
    }

    /// Appends a plain one-line proactive suggestion (an assistant message)
    /// after a task so Nexie feels helpful without waiting for the user to ask.
    func injectSuggestion(_ text: String) {
        guard let sessionID = activeSession?.id else { return }
        // Capture the prior assistant reply so a later "yes" can act on the
        // offer (e.g. re-play it as audio), then record the pending offer.
        let prior = sessions.first(where: { $0.id == sessionID })?
            .messages.last(where: { $0.role == .assistant })?.text
        append(ChatMessage(role: .assistant, text: text), to: sessionID)
        if text.contains("generate audio") {
            pendingOffer = .audioReply(prior ?? text)
        } else if text.contains("polished email draft") {
            pendingOffer = .polishDraft
        }
        persist()
    }

    /// Returns a contextual reply to a short "yes/no" when appropriate, or nil
    /// to let the normal reply pipeline continue. Prevents a lone "yes"/"no"
    /// from being misread as a new topic (the classic "yes → the band Yes" bug).
    private func affirmativeReply(for text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count <= 24 else { return nil }
        let words = t.split(separator: " ").map(String.init)

        let yes = ["yes", "yeah", "yep", "sure", "ok", "okay", "go ahead", "proceed",
                   "please", "please do", "correct", "right", "do it", "yes please",
                   "that would be great", "sounds good", "fine"]
        let no = ["no", "nope", "nah", "no thanks", "not now", "skip", "never mind",
                  "cancel", "don't", "dont", "stop", "no need", "not really"]

        // Only treat bare confirmations (2 words or fewer) as affirmatives so a
        // real sentence like "Yes the report is ready" still goes to the model.
        let isYes = words.count <= 2 && yes.contains(where: { t == $0 || t.hasPrefix($0 + " ") })
        let isNo = words.count <= 2 && no.contains(where: { t == $0 })
        guard isYes || isNo else { return nil }

        // JARVIS-style courtesy opener for confirmations.
        let honor = AssistantSettings.shared.style == .jarvis ? "Sir, " : ""

        switch pendingOffer {
        case .audioReply(let original):
            pendingOffer = nil
            if isYes {
                // Queue playback of the prior reply; append a short confirmation
                // so the user gets immediate verbal/text feedback.
                let confirmation = "\(honor)Playing it for you now."
                audioGenerator?()
                return confirmation
            } else {
                return "\(honor)Understood — I'll skip the audio. Do say if you'd like it later."
            }
        case .polishDraft:
            pendingOffer = nil
            return isYes
                ? "\(honor)Certainly — I can shape this into a polished draft. Which tone did you want?"
                : "\(honor)As you wish, I'll leave the draft as is."
        case nil:
            // No pending offer: a bare "yes"/"no" without context — don't let it
            // spiral into research about a band or company named after the word.
            return isYes ? "\(honor)At your service. What would you like me to do?" : "\(honor)Understood."
        }
    }


    /// Returns a contextual one-line next-step suggestion after a reply, or nil
    /// when none applies. Kept heuristic and cheap so it never blocks the reply.
    func proactiveSuggestion(afterReply reply: String) -> String? {
        let l = reply.lowercased()
        // JARVIS-style courtesy opener for offers.
        let honor = AssistantSettings.shared.style == .jarvis ? "Sir, " : ""
        // After drafting/writing a reply or message → offer to hear it aloud.
        if l.contains("draft") || l.contains("email") || l.contains("sent you")
            || l.contains("here's a") || l.contains("here is a") {
            return "\(honor)Shall I generate audio for this so you can hear how it sounds?"
        }
        // After a summarization → offer to turn it into a polished draft.
        if l.contains("summary") || l.contains("summar") {
            return "\(honor)I can turn this into a polished email draft, if you like."
        }
        return nil
    }

    /// Records a failed self-improvement attempt so the failure is visible and
    /// remembered (skips re-adding duplicate failure notes).
    func reportSelfImprovementFailure(_ text: String) {
        addMemoryFact("Self-improvement note: \(text)")
    }

    /// Called by the AgentExecutor after an approved action finished. Records
    /// the result for the user and lets the model continue for up to
    /// `maxToolSteps` passes.
    func toolResult(_ action: AgentAction, outputLabel: String?) {
        guard let sessionID = activeSession?.id, toolSteps < maxToolSteps else { return }

        var note = "[tool: \(action.kind.rawValue)] \(action.command)\n\n"
        if let label = outputLabel {
            note += "\(label):\n\(action.result ?? "(no output)")\n\n"
        } else {
            note += (action.result ?? "Done.") + "\n\n"
        }
        append(ChatMessage(role: .assistant, text: note), to: sessionID)
        persist()

        toolSteps += 1
        continueAgentStep(sessionID: sessionID)
    }

    /// One extra model pass after a tool result so the agent can finish the
    /// task or propose the next (still permission-gated) action.
    private func continueAgentStep(sessionID: UUID) {
        guard computerControl else { return }
        Task { @MainActor [weak self] in
            guard let self, await self.llm.isReachable() else { return }
            var messages = self.historyFor(sessionID, limit: 16)
            messages.append(LLMMessage(role: "system", content:
                "The user approved your last action and the result is shown above. " +
                "Continue helping them — summarize, or if another tool action is " +
                "needed, emit it the same way (you will be asked for permission again)."))
            self.isProcessing = true
            let full = await self.streamContext(messages, sessionID: sessionID)
            if !full.isEmpty, let mid = self.sessions.first(where: { $0.id == sessionID })?.messages.last?.id {
                if self.computerControl {
                    AgentExecutor.shared.registerActions(in: full, messageID: mid, chat: self)
                }
            }
            self.isProcessing = false
            self.persist()
        }
    }

    /// Streams a context-only reply into the session (used for agent follow-ups
    /// that don't repeat the user's original prompt).
    private func streamContext(_ messages: [LLMMessage], sessionID: UUID) async -> String {
        append(streaming: "", to: sessionID)
        let msgIdx = indexOfLastMessage(sessionID)
        var pendingText = ""
        var sinceFlush = 0
        let flushEvery = 16
        let maxTokens = Double(LLMService.maxTokens)

        responseTokens = 0
        responsePercent = 0
        isResponding = true

        let full = await llm.streamChat(messages: messages) { [weak self] token in
            guard let self else { return }
            pendingText.append(token)
            sinceFlush += 1
            self.responseTokens = pendingText.count
            self.responsePercent = min(1.0, Double(pendingText.count) / maxTokens)
            guard sinceFlush >= flushEvery else { return }
            sinceFlush = 0
            self.writeStreaming(pendingText, sessionID: sessionID, messageIndex: msgIdx)
        }
        isResponding = false
        responsePercent = 0
        if let i = self.sessions.firstIndex(where: { $0.id == sessionID }),
           self.sessions[i].messages.indices.contains(msgIdx) {
            if full.isEmpty {
                self.sessions[i].messages.remove(at: msgIdx)
            } else {
                self.sessions[i].messages[msgIdx].text = full
            }
        }
        return full
    }

    // MARK: - Export

    /// Exports the session as Markdown or JSON into the workspace Exports
    /// folder. Returns the written URL, or nil on failure.
    @discardableResult
    func exportConversation(_ id: UUID, format: ExportFormat) -> URL? {
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        // Sanitize exports by default so shared files never leak API keys,
        // JWTs, or email addresses. Turn off via chat.exportSanitize=false.
        let sanitize = UserDefaults.standard.bool(forKey: "chat.exportSanitize") != false
        let exported = sanitize ? sanitizedCopy(of: session) : session

        let fm = DateFormatter()
        fm.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = fm.string(from: Date())
        let base = workspace.rootURL.appendingPathComponent("Exports")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let safeTitle = exported.title
            .replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let url: URL
        switch format {
        case .markdown:
            url = base.appendingPathComponent("\(stamp) \(safeTitle).md")
            var md = "# \(exported.title)\n\n"
            for m in exported.messages {
                let role = m.role == .user ? "**You**" : "**Nexie**"
                md += "## \(role) · \(m.date.formatted(date: .abbreviated, time: .shortened))\n\n\(m.text)\n\n"
            }
            try? md.data(using: .utf8)?.write(to: url, options: .atomic)
        case .json:
            url = base.appendingPathComponent("\(stamp) \(safeTitle).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(exported).write(to: url, options: .atomic)
        }
        return url
    }

    private func sanitizedCopy(of session: ChatSession) -> ChatSession {
        var copy = session
        copy.title = SecretRedactor.redact(session.title)
        copy.messages = session.messages.map { msg in
            var m = msg
            m.text = SecretRedactor.redact(msg.text)
            return m
        }
        copy.botID = session.botID
        copy.presetID = session.presetID
        return copy
    }

    enum ExportFormat {
        case markdown
        case json
    }

    private func runWebResearch(_ query: String) async -> ResearchOutcome {
        // Prefer the local Python research sidecar; fall back to Swift when it
        // is unavailable or returns nothing.
        if await ResearchServiceClient.shared.isReachable() {
            if let result = await ResearchServiceClient.shared.research(query: query, deep: false) {
                return ResearchOutcome(text: result.answer, sources: result.sources,
                                       confidence: result.confidence)
            }
        }
        return await runWebResearchSwift(query)
    }

    /// Original Swift web-research implementation (kept as the offline/fallback
    /// path and for when the Python sidecar isn't running). Also scores the
    /// answer's evidence so the chat can show source chips offline too.
    private func runWebResearchSwift(_ query: String) async -> ResearchOutcome {
        // Fetch a few extra pages so the authoritative source (the retailer's
        // own terms/promotions page) is likely to be captured, not just the
        // top-3 search hits.
        let rawResults = await web.searchAsync(query, fetchPages: true, maxFetch: 5)
        guard !rawResults.isEmpty else { return .empty }

        // Drop search hits that have no topical connection to the query, so
        // unrelated pages never leak into the answer, then promote the
        // retailer's own domain and keep the strongest few sources.
        let relevant = Self.relevantResults(query, results: rawResults)
        let results = Array(Self.prioritizeOfficialPages(query: query, results: relevant).prefix(4))
        guard !results.isEmpty else { return .empty }
        let sources = results.map { ResearchSource(title: $0.title, url: $0.url, snippet: $0.snippet) }

        // Pass the FULL cleaned body text (not 400-char snippets) so the model
        // can quote exact terms, dates, exclusions and durations. For JS-rendered
        // pages the real content sits after the nav, so trim each body to its
        // relevant region. Official domain pages get the most room.
        let sourceLines: [String] = results.enumerated().map { i, r in
            let body = Self.relevantTermsRegion(query, body: self.cleanPageText(r.snippet),
                                                maxChars: i == 0 ? 6000 : 2200)
            let shown = body.isEmpty ? String(r.snippet.prefix(300)) : body
            return "• \(r.title) (\(r.url)): \(shown)"
        }
        let sourcesText = sourceLines.joined(separator: "\n")
        let prompt = LLMMessage(role: "system", content: """
            You are a precise research assistant. Answer ONLY the user's question DIRECTLY and nothing \
            unrelated. Lead with a one or two sentence direct answer that re-states what was asked. Then, \
            only if the facts genuinely need it, support it with a couple of short "•" bullet lines \
            (exact values, dates, names). Do NOT invent sections, do NOT pad with extra angles, and do \
            NOT include a "Takeaway" label — the direct answer up top IS the takeaway. Quote the EXACT \
            wording from a source with an inline cite like [1] only where it supports the point. Date \
            ranges fully, e.g. "Runs from 25 August 2026 through midnight on 31 August 2026". If a source \
            doesn't actually answer the question, ignore it entirely. If the sources cannot answer the \
            question, say so in one sentence instead of guessing.

            WEB SOURCES:
            \(sourcesText)
            """)
        let q = LLMMessage(role: "user", content: query)
        let out = await llm.complete(messages: [prompt, q])
        if !out.isEmpty {
            let confidence = EvidenceScorer.confidence(text: out, sourceCount: sources.count, marinated: false)
            return ResearchOutcome(text: out, sources: sources, confidence: confidence)
        }
        // No model connected — synthesize a structured Perplexity-style answer
        // from the results we already fetched, so research-class questions get
        // a comprehensive reply even fully offline (no second search needed).
        let cleaned = results.map { (title: $0.title, url: $0.url,
                                     body: Self.relevantTermsRegion(query, body: self.cleanPageText($0.snippet),
                                                                     maxChars: 9000)) }
        let text = Self.structuredAnswer(for: query, sources: cleaned)
        return ResearchOutcome(text: text, sources: sources,
                               confidence: EvidenceScorer.confidence(text: text, sourceCount: sources.count,
                                                                     marinated: false))
    }

    /// Deep research: runs two search passes (a broad first pass, then a refined
    /// second angle derived from the query), merges and de-duplicates sources,
    /// and synthesizes a thorough, sectioned, cited answer. Falls back to the
    /// single-pass/offline formatter if anything fails so a reply always returns.
    private func runDeepResearch(_ query: String) async -> ResearchOutcome {
        // Prefer the local Python research sidecar; fall back to Swift when it
        // is unavailable or returns nothing.
        if await ResearchServiceClient.shared.isReachable() {
            if let result = await ResearchServiceClient.shared.research(query: query, deep: true) {
                return ResearchOutcome(text: result.answer, sources: result.sources,
                                       confidence: result.confidence)
            }
        }
        return await runDeepResearchSwift(query)
    }

    /// Original Swift deep-research implementation (kept as the offline/fallback
    /// path and for when the Python sidecar isn't running).
    private func runDeepResearchSwift(_ query: String) async -> ResearchOutcome {
        // Pass 1 — broad sweep for more sources.
        let pass1 = await web.searchAsync(query, fetchPages: true, maxFetch: 8)

        // Pass 2 — a separate angle so we genuinely gather more than round one.
        let refined = Self.deepRefineQuery(query)
        var merged = pass1
        if refined != query {
            let pass2 = await web.searchAsync(refined, fetchPages: true, maxFetch: 5)
            // Keep only results we haven't already seen (dedupe by URL).
            let seenPaths = Set(merged.map { $0.url })
            merged += pass2.filter { !seenPaths.contains($0.url) }
        }
        guard !merged.isEmpty else { return .empty }

        let relevant = Self.relevantResults(query, results: merged)
        let results = Array(Self.prioritizeOfficialPages(query: query, results: relevant).prefix(6))
        guard !results.isEmpty else { return .empty }
        let sources = results.map { ResearchSource(title: $0.title, url: $0.url, snippet: $0.snippet) }

        let sourceLines: [String] = results.enumerated().map { i, r in
            let body = Self.relevantTermsRegion(query, body: self.cleanPageText(r.snippet),
                                                maxChars: i == 0 ? 7000 : 2800)
            let shown = body.isEmpty ? String(r.snippet.prefix(300)) : body
            return "• \(r.title) (\(r.url)): \(shown)"
        }
        let sourcesText = sourceLines.joined(separator: "\n")
        let prompt = LLMMessage(role: "system", content: """
            You are a deep research assistant but your FIRST job is staying on-topic. Lead with a \
            one or two line bottom-line takeaway that directly answers the user's exact question. Then, \
            only where it genuinely helps, add a short structured body using clearly labelled sections \
            ("## Key points", "## Comparisons", "## Bottom line"). NEVER pad: only add a section if it \
            has concrete, relevant content about the question. Cover other angles ONLY if they are \
            directly relevant to what was asked — otherwise skip them. Cite each fact inline as [1], [2], \
            etc., matching the numbered WEB SOURCES below, only where a source genuinely supports the \
            point. Ignore any source that doesn't actually answer the question. End with the bottom-line \
            recommendation. If the sources cannot answer the question, say so in one sentence rather \
            than guessing.

            WEB SOURCES:
            \(sourcesText)
            """)
        let q = LLMMessage(role: "user", content: query)
        let out = await llm.complete(messages: [prompt, q])
        if !out.isEmpty {
            return ResearchOutcome(text: out, sources: sources,
                                   confidence: EvidenceScorer.confidence(text: out, sourceCount: sources.count,
                                                                         marinated: false))
        }

        // Offline fallback — a structured answer from everything we gathered.
        let cleaned = results.map { (title: $0.title, url: $0.url,
                                     body: Self.relevantTermsRegion(query, body: self.cleanPageText($0.snippet),
                                                                     maxChars: 9000)) }
        let text = Self.structuredAnswer(for: query, sources: cleaned)
        return ResearchOutcome(text: text, sources: sources,
                               confidence: EvidenceScorer.confidence(text: text, sourceCount: sources.count,
                                                                     marinated: false))
    }

    /// Derives a separate follow-up query for the second research pass. Picks
    /// the 2–3 most significant words from the question so the search is a
    /// different angle rather than an exact repeat.
    private static func deepRefineQuery(_ query: String) -> String {
        let forbidden = Set("a an the is are was were to of in on for and or with at by from it its this that be have had has what when where who how which there some into about as not no yes you your their our does do did will would can could so but if they them then than these those out up down off over under again further".split(separator: " "))
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !forbidden.contains(Substring($0)) }
        let picked = Array(words.prefix(3))
        return picked.isEmpty ? query : picked.joined(separator: " ") + " 2026 details"
    }

    /// Drops search hits that share no vocabulary with the query, so unrelated
    /// third-party pages can't leak into the answer. Pages from the query's own
    /// official domain always survive even if their titles don't echo the words.
    private static func relevantResults(_ query: String, results: [WebResult]) -> [WebResult] {
        let qWords = Set(query.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 2 && !["the", "and", "for", "with", "what", "are", "how", "get",
                                        "can", "any", "com", "au", "www", "want", "about"].contains($0) })
        guard !qWords.isEmpty else { return results }
        let queryHost = officialHost(from: query)
        return results.filter { r in
            if let queryHost, let h = URL(string: r.url)?.host?.lowercased(), h.hasSuffix(queryHost) {
                return true
            }
            let text = "\(r.title.lowercased()) \(r.url.lowercased())"
            return qWords.contains { text.contains($0) }
        }
    }

    /// Re-orders search results so pages from the query's own official domain
    /// (e.g. "freedom.com.au") and authoritative pages (titles mentioning
    /// terms/conditions/promotions/offers) come first. Those carry the exact
    /// details a shopper wants; third-party articles are kept but demoted.
    private static func prioritizeOfficialPages(query: String, results: [WebResult]) -> [WebResult] {
        let queryHost = officialHost(from: query)
        guard let queryHost else { return results }
        var official: [WebResult] = []
        var authoritative: [WebResult] = []
        var rest: [WebResult] = []
        for r in results {
            let host = (URL(string: r.url)?.host ?? "").lowercased()
            let isOfficial = host.hasSuffix(queryHost)
            if isOfficial {
                official.append(r)
            } else if r.title.localizedCaseInsensitiveContains("term")
                || r.title.localizedCaseInsensitiveContains("condition")
                || r.title.localizedCaseInsensitiveContains("promotion")
                || (r.title.localizedCaseInsensitiveContains("offer") && !r.title.localizedCaseInsensitiveContains("code")) {
                authoritative.append(r)
            } else {
                rest.append(r)
            }
        }
        return official + authoritative + rest
    }

    /// Extracts an official host (e.g. "freedom.com.au") from a query that
    /// names a site like "freedom.com.au" or "www.freedom.com.au". Returns nil
    /// if the query doesn't obviously name a site.
    private static func officialHost(from query: String) -> String? {
        let l = query.lowercased()
        let domainPattern = #"([a-z0-9-]+\.(?:com\.au|co\.uk|co\.nz|\.com|\.org|\.net|\.io|\.co|\.au|\.gov|\.edu))"#
        guard let re = try? NSRegularExpression(pattern: domainPattern, options: [.caseInsensitive]) else { return nil }
        let ns = l as NSString
        guard let m = re.firstMatch(in: l, options: [], range: NSRange(location: 0, length: ns.length)),
              m.range.location != NSNotFound else { return nil }
        return ns.substring(with: m.range).replacingOccurrences(of: "www.", with: "")
    }

    // MARK: - Offline research & image attachments

    /// Detects image file paths mentioned in a message and reads them so a
    /// vision-capable backend can receive them as attachments.
    private func imageAttachments(in text: String) -> [LLMImage] {
        let pattern = #"([^\s]+\.(?:png|jpg|jpeg|gif|heic|webp|tiff|tif|bmp))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var out: [LLMImage] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard out.count < 4, let match else { stop.pointee = true; return }
            let raw = ns.substring(with: match.range(at: 1))
            let path = (raw as NSString).expandingTildeInPath
            let ext = (path as NSString).pathExtension.lowercased()
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
            let mime: String
            switch ext {
            case "png": mime = "image/png"
            case "gif": mime = "image/gif"
            case "heic": mime = "image/heic"
            case "webp": mime = "image/webp"
            default: mime = "image/jpeg"
            }
            out.append(LLMImage(data: data, mimeType: mime))
        }
        return out
    }

    /// Offline, instant answer for trivial factual queries (date/time/day) so a
    /// simple question like "what's the date?" is answered immediately without
    /// waiting on the slow local model or a web round-trip. Returns nil when the
    /// query is anything richer and should go through the normal pipeline.
    private func instantReply(for userText: String) -> String? {
        let l = userText.lowercased()

        // Must be a short, now-oriented question about date/time/day.
        let now = ["today", "now", "current"].contains { l.contains($0) }
        guard now, userText.split(separator: " ").count <= 8 else { return nil }
        // Word-boundary matching (not substring) so "day" inside "today" or
        // "date" inside "update" don't falsely trigger an instant answer.
        let padded = " " + l + " "
        let asksDate = padded.contains(" date ")
        let asksTime = padded.contains(" time ")
        let asksDay = padded.contains(" day ")
        // Ignore holiday/special-day phrasing (memorial day, Valentine's day…).
        let holidayWords = ["holiday", "valentine", "memorial", "independence", "labor"]
        guard !holidayWords.contains(where: { l.contains($0) }) else { return nil }
        guard asksDate || asksTime || asksDay else { return nil }

        let nowD = Date()
        let f = DateFormatter()
        // JARVIS-style favour a courteous, polished greeting on the fast path.
        let honor = AssistantSettings.shared.style == .jarvis ? "Sir, " : ""
        if asksDate && asksTime {
            f.dateFormat = "EEEE, MMMM d, yyyy — h:mm a"
            return "\(honor)It's \(f.string(from: nowD))."
        }
        if asksDate {
            f.dateFormat = "EEEE, MMMM d, yyyy"
            return "\(honor)Today is \(f.string(from: nowD))."
        }
        if asksTime {
            f.dateFormat = "h:mm a"
            return "\(honor)It's currently \(f.string(from: nowD))."
        }
        if asksDay {
            f.dateFormat = "EEEE"
            return "\(honor)Today is \(f.string(from: nowD))."
        }
        return nil
    }

    /// Mirrors the brain sidecar's location-phrase list so a location question
    /// is caught even when that sidecar is offline.
    private let locationPhrases = [
        "my location", "where am i", "where i am", "where am i right now",
        "my position", "current location", "find my location", "my current location",
        "what's my location", "what is my location", "where do i live",
        "which city am i in", "what city am i in", "what country am i in",
        "where am i located", "am i in the philippines", "what time zone am i in",
        "my exact location",
    ]

    private func asksForLocation(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        return locationPhrases.contains { normalized.contains($0) }
    }

    /// Builds the answer to a "where am I?" question: precise Core Location
    /// first, approximate IP-derived fix second, clear guidance last.
    private func locationReply() async -> String {
        if let place = await LocationService.shared.currentLocationDescription() {
            return "You're in \(place)."
        }
        let geo = await ResearchServiceClient.shared.geoip()
        if !geo.isEmpty {
            return "Location access is off, so here's an approximate fix from your network: you're in \(geo). For a precise one, enable location for Nexie in System Settings \u{203a} Privacy & Security \u{203a} Location Services, then ask me again."
        }
        return "I can't determine your location right now. Enable location for Nexie in System Settings \u{203a} Privacy & Security \u{203a} Location Services, then ask me again."
    }

    /// Heuristic: does this prompt genuinely need live info from the web?
    /// Kept deliberately conservative so everyday questions (dates, how-to's,
    /// "what is", "today") are answered directly and naturally instead of being
    /// hijacked into a web search + citation-heavy Perplexity-style reply.
    private func looksLikeResearch(_ q: String) -> Bool {
        let l = q.lowercased()
        // Any weather query needs live current conditions — always research it.
        let weatherWords = ["weather", "forecast", "temperature", "rain", "rainfall",
                            "raining", "sunny", "cloudy", "wind", "humid", "humidity",
                            "snow", "storm", "cold", "hot", "degrees", "forecast"]
        if weatherWords.contains(where: { l.contains($0) }) { return true }

        // A URL or domain is an unambiguous request for live page content.
        let domains = [".com", ".co", ".au", ".org", ".net", ".io", ".gov", ".edu", "www.", "http"]
        if domains.contains(where: l.contains) { return true }

        // Explicit research/web verbs.
        let resealVerbs = ["web research", "look it up", "look up", "google it", "search the web",
                           "search for", "find current", "find the latest", "current price",
                           "current price of", "how much does", "how much is", "promo code"]
        if resealVerbs.contains(where: l.contains) { return true }

        // Live/commercial/dated signal words that require fresh sources.
        let commerceWords = ["pricing", "price of", "check price", "cost of", "price tag",
                             "promotion", "promo", "discount", "sale today", "deals", "offer",
                             "in stock", "stockists", "stock now", "availability",
                             "compare", "vs ", "versus", "pros and cons",
                             "specs", "specifications", "requirements", "system requirements",
                             "release date", "launch date", "release", "latest news", "breaking news",
                             "score", "rating", "rankings", "reviews", "review of", "weather",
                             "price", "best price", "cheapest", "where to buy", "buy "]
        if commerceWords.contains(where: l.contains) { return true }

        // Explicit "news/current/recent" framing.
        let currentWords = ["current exchange rate", "exchange rate", "stock price", "share price",
                            "crypto price", "bitcoin price", "oil price", "fuel price",
                            "latest version", "newest version", "new release", "current version"]
        if currentWords.contains(where: l.contains) { return true }

        return false
    }

    /// Web-lookup summary that works without any model connected: searches,
    /// fetches pages, extracts the cleanest facts, and formats the result the
    /// way Perplexity/Gemini do — an opening summary, structured sections,
    /// inline source citations `[1]`, `[2]`, and a closing takeaway.
    private func runOfflineResearch(_ query: String) async -> String {
        let results = await web.searchAsync(query, fetchPages: true, maxFetch: 4)
        guard !results.isEmpty else { return "" }
        let cleaned = results.map { (r: WebResult) -> (title: String, url: String, body: String) in
            (r.title, r.url, Self.relevantTermsRegion(query, body: self.cleanPageText(r.snippet), maxChars: 9000))
        }
        return Self.structuredAnswer(for: query, sources: cleaned)
    }

    /// Removes scraped-HTML noise (nav/footer boilerplate, injected script
    /// comments, cookie banners, endless menu links) so the extracted text is
    /// clean enough to quote as an answer, and collapses whitespace.
    private func cleanPageText(_ raw: String) -> String {
        var t = raw
        // Drop injected source-comment/CSS-insider garbage that has no content value.
        t = t.replacingOccurrences(of: #"MUST stay[^.]*\."#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(no type=|type=""module""|async|defer)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "oauth-transport-guard.js", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"Skip to (Header|Main Content|Footer|main content)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "Submit a request Sign in", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"Article(s)? in this section"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"Table of Contents"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }

    /// Formats the cleaned sources into a focused Perplexity-style structured
    /// answer. The layout follows the question's topic: promotional queries get
    /// the deal breakdown (headline, offers, terms, best pick, follow-ups);
    /// everything else gets a direct opening paragraph, key points, and sources.
    /// Every factual claim carries an inline `[n]` citation where relevant.
    static func structuredAnswer(for query: String, sources: [(title: String, url: String, body: String)]) -> String {
        let nonEmpty = sources.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else {
            let fallback = sources.prefix(3).map { "• \($0.title)\n  \($0.url)" }.joined(separator: "\n\n")
            return "Here's what I found for “\(query)”:\n\n\(fallback)"
        }

        let promo = isPromotional(query)
        var lines = [String]()
        lines.append(Self.firstParagraph(query, sources: nonEmpty))
        lines.append("")

        if promo {
            let promos = Self.promotionBullets(nonEmpty)
            if !promos.isEmpty {
                lines.append("## Current promotions")
                lines.append(Self.bullets(promos))
                lines.append("")
            }
            let terms = Self.termSentences(nonEmpty)
            if !terms.isEmpty {
                lines.append("## Main terms and conditions")
                lines.append("Across these offers, the retailer applies broadly similar conditions:")
                lines.append(Self.bullets(terms))
                lines.append("")
            }
        } else {
            let facts = Self.topFacts(nonEmpty, limit: 4)
            if !facts.isEmpty {
                lines.append("## Key points")
                lines.append(Self.bullets(facts))
                lines.append("")
            }
        }

        // When a query explicitly asks for the full terms & conditions or the
        // official terms page is among the sources, quote the full cleaned body
        // of that authoritative source so nothing is left out.
        if let full = Self.fullDetailsBlock(query, sources: nonEmpty) {
            lines.append("## Full details")
            lines.append(full)
            lines.append("")
        }

        if promo {
            let offers = Self.offerFacts(nonEmpty)
            if !offers.isEmpty {
                lines.append("## Best pick")
                lines.append(Self.bestPick(query, sources: nonEmpty, offers: offers))
                lines.append("")
            }
            lines.append(Self.closingOfferNote(query, sources: nonEmpty))
            lines.append("")
        }

        lines.append("## Sources")
        var seenHosts = Set<String>()
        var shown = 0
        for (i, s) in sources.enumerated() where !s.title.isEmpty {
            if shown >= 5 { break }
            let host = (URL(string: s.url)?.host ?? "").replacingOccurrences(of: "www.", with: "")
            if !host.isEmpty {
                guard seenHosts.insert(host).inserted else { continue }
            }
            lines.append("[\(i + 1)] \(s.title) — \(s.url)")
            shown += 1
        }
        return lines.joined(separator: "\n")
    }

    /// True when the question clearly asks about deals, promotions, sales or
    /// pricing, so the answer can take the deal-shaped layout.
    private static func isPromotional(_ query: String) -> Bool {
        let l = query.lowercased()
        let strongPromo = ["deal", "promo", "promotion", "discount", "sale", "voucher", "coupon"]
        let hasWord = { (w: String) -> Bool in
            l.range(of: "\\b\(NSRegularExpression.escapedPattern(for: w))\\b", options: .regularExpression) != nil
        }
        return strongPromo.contains { l.contains($0) }
            || (hasWord("offer") && (l.contains("current ") || hasWord("off") || l.contains("on sale")))
            || (hasWord("price") && (hasWord("off") || l.contains("deal")))
            || l.contains("how much is")
    }

    /// Returns the full cleaned body of the most authoritative official/terms
    /// source, when the query asks for complete terms or such a source exists.
    /// Gives the reader the complete original wording (dates, exclusions,
    /// quantity limits) rather than just the extracted bullets.
    private static func fullDetailsBlock(_ query: String, sources: [(title: String, url: String, body: String)]) -> String? {
        let wantFullTerms = ["terms", "condition", "duration", "detail", "full", "exact", "all the terms"].contains {
            query.lowercased().contains($0)
        }
        let candidates = sources.filter { s in
            let t = s.title.lowercased()
            let b = s.body.lowercased()
            return t.contains("term") || t.contains("condition") || t.contains("promotion")
                || b.contains("terms & conditions") || b.contains("not available in conjunction")
                || b.contains("not available with any other")
        }
        // Prefer the candidate with the most substantive body text.
        guard let best = (candidates.isEmpty ? sources : candidates)
            .max(by: { $0.body.count < $1.body.count }) else { return nil }
        let body = best.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 120 else { return nil }
        // Only surface it when actually useful: either the query wants full
        // terms, or the body itself reads like a terms/conditions list.
        // A numbered clause start looks like "1. 'At Least 30% Off…'" — not
        // version numbers like "1.6".
        let numberedClause = #"1\.\s*[‘’"'“”]?\s*[A-Z]"#
        let bodyLower = body.lowercased()
        let looksLikeTerms = body.range(of: numberedClause, options: .regularExpression) != nil
            || bodyLower.contains("terms & conditions")
            || bodyLower.contains("excludes")
            || bodyLower.contains("not available")
        guard wantFullTerms || looksLikeTerms else { return nil }
        let shown = body.count > 2200 ? String(body.prefix(2200)) + "…" : body
        return "• \(best.title)\n\(shown)"
    }

    /// Trims a large (possibly nav-dominant, JS-rendered) page body down to the
    /// region that actually answers a terms/details question. Rendered retail
    /// pages keep the full site menu FIRST and the real content (numbered
    /// terms, dates, exclusions) AFTER, so raw prefixing would cut the answer
    /// out. Anchor on the numbered clause start or the last terms-style heading
    /// with content behind it.
    private static func relevantTermsRegion(_ query: String, body: String, maxChars: Int = 6000) -> String {
        let l = query.lowercased()
        let wantsTerms = ["term", "condition", "duration", "detail", "exact", "full", "exclusion", "fine print", "eligib"].contains {
            l.contains($0)
        }
        if !wantsTerms {
            return String(body.prefix(1500))
        }
        let ns = body as NSString
        guard ns.length > 0 else { return body }
        let lower = body.lowercased() as NSString

        // 1) Numbered clause start (e.g. `1. 'At Least 30% Off Storewide' is
        //    available from 2/9/26…`). Whitespace is collapsed so anchor on a
        //    leading space + "1." + optional quote + uppercase.
        let clausePat = #"^\s*1\.\s*[‘’"'“”]?\s*[A-Z]|1\.\s*[‘’"'“”]?\s*[A-Z]"#
        if let re = try? NSRegularExpression(pattern: clausePat),
           let m = re.firstMatch(in: body, options: [], range: NSRange(location: 0, length: ns.length)),
           m.range.location != NSNotFound {
            let start = m.range.location
            let len = min(ns.length - start, maxChars)
            if len >= 120 {
                return ns.substring(with: NSRange(location: start, length: len))
            }
        }

        // 2) Fallback: the LAST terms-style heading that still has content after it.
        let anchors = ["terms & conditions", "full terms and conditions", "promotions & offers"]
        var best: Int?
        for anchor in anchors {
            var searchRange = NSRange(location: 0, length: lower.length)
            while searchRange.length > 0 {
                let r = lower.range(of: anchor, options: .caseInsensitive, range: searchRange)
                if r.location == NSNotFound { break }
                let following = ns.length - (r.location + r.length)
                if following >= 150 { best = r.location + r.length }
                searchRange = NSRange(location: r.location + r.length,
                                      length: ns.length - (r.location + r.length))
            }
        }
        if let best {
            let len = min(ns.length - best, maxChars)
            return "…" + ns.substring(with: NSRange(location: best, length: len))
        }
        return String(body.prefix(1500))
    }

    /// Builds a focused headline that directly answers the user's query from
    /// the strongest signal, instead of dumping a wall of scraped page text.
    /// Falls back to 2–3 of the most informative relevant sentences when the
    /// query isn't deal-shaped.
    private static func firstParagraph(_ query: String, sources: [(title: String, url: String, body: String)]) -> String {
        let l = query.lowercased()
        let offers = offerFacts(sources)

        // Deal/pricing queries: lead with the concrete headline offer + scope.
        // Trigger only on clear promotional intent so generic questions that
        // merely contain "offer"/"price" don't get a deal-shaped headline.
        if offers.count >= 1 && Self.isPromotional(query) {
            let headline = Self.normalizeDeal(offers.first!).lowercased()
            let subject = Self.subjectPhrase(query)
            let scope = Self.offerScope(query, sources: sources)
            let expiry = Self.nearestExpiry(sources)
            var line: String
            if let scope, let expiry {
                line = "The main current deal on \(subject) \(scope) is \(headline), \(expiry)."
            } else if let scope {
                line = "The main current deal on \(subject) \(scope) is \(headline)."
            } else if let expiry {
                line = "The main current deal on \(subject) is \(headline), \(expiry)."
            } else {
                line = "The main current deal on \(subject) is \(headline)."
            }
            return titlize(line)
        }

        // General queries: pull the most relevant, non-boilerplate sentences as a
        // direct opening paragraph.
        let best = Self.mostRelevantSentences(query, sources: sources, limit: 3)
        let lead = best.isEmpty
            ? "The fetched pages are live but didn't state a clear answer to your exact question."
            : best.joined(separator: " ")
        return titlize(lead)
    }

    /// A clean noun phrase for the subject of the query (e.g. "Freedom",
    /// "freedom.com.au" → "Freedom Furniture"), dropping leading "what's the
    /// current deal on" style wrappers.
    private static func subjectPhrase(_ query: String) -> String {
        var s = query
        for prefix in ["whats the current deal on", "what's the current deal on", "what is the current deal on",
                       "whats the deal on", "what's the deal on", "current deal on", "what are the current",
                       "whats the current", "what's the current", "current offers at", "what is the current offer on"] {
            if s.lowercased().hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "?.!, "))
        if s.isEmpty { return "this retailer" }
        // "freedom.com.au" → "Freedom Furniture" style label.
        let clean = s.replacingOccurrences(of: "www.", with: "")
        let domain = clean
            .replacingOccurrences(of: #"\.(com\.au|\.com|\.co|\.net|\.org|\.au)$"#, with: "", options: .regularExpression)
        let words = domain.split(separator: ".").first.map(String.init) ?? domain
        return words.isEmpty ? "this retailer" : words.capitalized
    }

    /// The product category (e.g. "sofas", "furniture", "mattresses") that the
    /// offer centres on, if it's stated in the query or any source. Used to
    /// build "…on Freedom sofas is <deal>…".
    private static func offerScope(_ query: String, sources: [(title: String, url: String, body: String)]) -> String? {
        let categories = ["sofas", "sofa", "furniture", "mattresses", "mattress", "homewares",
                          "outdoor furniture", "outdoor", "rugs", "bedroom", "dining", "chairs", "occasional"]
        let l = query.lowercased()
        // Prefer the most specific category mentioned in the query.
        for cat in categories where l.contains("\(cat) off") || l.contains(" on \(cat)") {
            let c = cat == "sofa" ? "sofas" : (cat == "mattress" ? "mattresses" : cat)
            return c
        }
        for cat in categories where l.contains(cat) {
            let c = cat == "sofa" ? "sofas" : (cat == "mattress" ? "mattresses" : cat)
            return c
        }
        // Otherwise fall back to the most-touted category across the sources.
        let joined = sources.map { $0.body.lowercased() }.joined(separator: " ")
        for cat in ["sofas", "mattresses", "homewares", "outdoor", "furniture", "rugs"] where joined.contains("all \(cat)") || joined.contains(" \(cat) until ") {
            return cat
        }
        if joined.contains("all sofas") || joined.contains("sofas until") { return "sofas" }
        return nil
    }

    /// Pulls the freshest expiry date mentioned (e.g. "until midnight on
    /// 31 August 2026") so the headline signals urgency like Perplexity.
    /// Returns the first clearly-stated "runs until <date>" style mention.
    private static func nearestExpiry(_ sources: [(title: String, url: String, body: String)]) -> String? {
        let pat = #"((?:until|by|ends?|expires?|valid)\s+[^.]{0,40}(?:20\d{2}))"#
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        for s in sources {
            for m in matches(pat, in: s.body) {
                let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count < 12 { continue }
                // Capitalize month names so "31 august 2026" reads "31 August 2026".
                var fixed = trimmed
                for month in months {
                    fixed = fixed.replacingOccurrences(of: " \(month) ", with: " \(month.capitalized) ")
                }
                return fixed
            }
        }
        return nil
    }

    /// Ranks sentences in each source by how relevant they are to the query
    /// (shared vocabulary), skipping boilerplate, and returns the top few that
    /// are informative without being a wall of text.
    private static func mostRelevantSentences(_ query: String, sources: [(title: String, url: String, body: String)], limit: Int) -> [String] {
        let qWords = Set(query.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.count > 2 && !["the", "and", "for", "with", "from", "what", "are", "you", "not", "off", "how"].contains($0) })
        let boiler = ["subscribe", "log in", "sign in", "menu", "close", "skip to content", "my account",
                      "saved articles", "search for", "view search results", "newsletter", "facebook",
                      "instagram", "pinterest", "privacy", "terms", "cookie"]
        var scored: [(score: Int, text: String)] = []
        for s in sources {
            let sentences = s.body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .split(whereSeparator: { $0.isPunctuation && $0 != "." && $0 != "%" && $0 != "$" && $0 != "£" })
                .map(String.init)
            for sent in sentences {
                let t = sent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.count >= 40, t.count <= 320 else { continue }
                let low = t.lowercased()
                if boiler.contains(where: { low.contains($0) }) { continue }
                let words = low.split(whereSeparator: { !$0.isLetter && $0 != "%" }).map(String.init)
                let score = words.filter { qWords.contains($0) }.count
                if score >= 1 { scored.append((score, t)) }
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.text.count < $1.text.count }
        let top = scored.prefix(limit).map { $0.text }
        var out = top
        // If nothing scored, fall back to the first 1–2 real sentences (split on a
        // period followed by whitespace, which keeps decimals like "1.6"
        // intact instead of breaking them apart).
        if out.isEmpty {
            for s in sources {
                let parts = s.body
                    .replacingOccurrences(of: #"\.(?=\s)"#, with: ".¶", options: .regularExpression)
                    .split(separator: "¶")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 15 }
                if !parts.isEmpty {
                    out = Array(parts.prefix(2))
                    break
                }
            }
        }
        return out
    }

    /// Concise, topic-scoped bullet points for non-deal questions: the most
    /// informative non-boilerplate sentences, trimmed so each fits a bullet.
    private static func topFacts(_ sources: [(title: String, url: String, body: String)], limit: Int) -> [String] {
        let boiler = ["subscribe", "log in", "sign in", "menu", "close", "skip to content",
                      "my account", "newsletter", "cookie", "facebook", "instagram"]
        var facts = [String]()
        for s in sources {
            let chunks = s.body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .split(whereSeparator: { $0.isPunctuation && $0 != "." && $0 != "%" && $0 != "$" && $0 != "£" })
                .map(String.init)
            for c in chunks {
                let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.count >= 30, t.count <= 220 else { continue }
                let low = t.lowercased()
                if boiler.contains(where: { low.contains($0) }) { continue }
                if !facts.contains(where: { $0 == t || $0.contains(t) || t.contains($0) }) {
                    facts.append(t)
                }
                if facts.count >= limit { return facts }
            }
        }
        return facts
    }

    /// The Perplexity-style single best pick: highlight the freshest / most
    /// prominent offer as the headline choice.
    private static func bestPick(_ query: String, sources: [(title: String, url: String, body: String)], offers: [String]) -> String {
        let l = query.lowercased()
        var note = "Go with the freshest headline offer above — the one with the nearest expiry is usually the most prominent current promotion."
        if let expiry = nearestExpiry(sources) {
            note = "If you're after one pick, choose the offer \(expiry) — that's the headline, time-sensitive deal. The other discounts still run, but they're broader and less urgent."
        } else if let first = offers.first {
            note = "If you want the single headline deal right now, it's “\(first.lowercased())” — the most clearly stated current offer. The others are broader and run longer."
        }
        if l.contains("term") || l.contains("condition") || l.contains("promotion") || l.contains("eligible") {
            note += " Confirm the item is in the eligible range and no clearance/gift-card exclusions apply before you buy."
        }
        return note
    }

    /// Sentence-level markdown bullets for the Perplexity-style "Current
    /// promotions" section: pairs each promotion phrase with its active date
    /// range, e.g. "20–50% off all sofas — runs from 25 August 2026 through
    /// midnight on 31 August 2026".
    private static func promotionBullets(_ sources: [(title: String, url: String, body: String)], limit: Int = 6) -> [String] {
        let offerPat = #"(?i)% off|\bup to \d{1,3}([-–]\d{1,3})?\s?%|save up to \$?\d[\d,]*"#
        let datePat = #"(?:from|available from|runs from|starting)\s+[^.;]{0,90}?(?:until|to|through|–)\s+(?:midnight on\s+)?[^.;]{0,45}?(?:19|20)\d{2}"#
        var out = [String]()
        for s in sources {
            for sentence in sentenceParts(s.body) {
                guard sentence.count <= 260,
                      sentence.range(of: offerPat, options: .regularExpression) != nil else { continue }
                let offer = Self.offerPhrase(sentence)
                if offer.isEmpty { continue }
                if out.contains(where: {
                    let a = offer.lowercased(), b = $0.lowercased()
                    return a == b || a.contains(b) || b.contains(a)
                }) { continue }
                var bullet = offer
                if let raw = matches(datePat, in: sentence).first {
                    let date = cleanDate(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                    bullet += " — \(date)"
                }
                out.append(bullet)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Slices a promotion sentence down to its offer part. Prefers a quoted
    /// offer title ("1. '20-50% off all sofas' is available…" → "20-50% off
    /// all sofas"); otherwise starts at the percentage/savings phrase and stops
    /// at the first date intro, comma, tilde or similar, folding a short
    /// leading title back in ("Flash Sale At Least 30% Off Storewide").
    private static func offerPhrase(_ sentence: String) -> String {
        let pat = #"(?i)(% off|\bup to \d{1,3}([-–]\d{1,3})?\s?%|save up to \$?\d[\d,]*)"#
        let cutters = [" Promotional ", " and up to ", " is available ", " available from ", " from ",
                       " for ", " until ", " through ", ", ", ";", ":", " – ", " — "]
        // Prefer a quoted offer title: "1. '20-50% off all sofas' is available…"
        if let re = try? NSRegularExpression(pattern: #"["'“”‘’]([^"'“”‘’]{3,140})["'“”‘’]"#),
           let m = re.firstMatch(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)) {
            let title = (sentence as NSString).substring(with: m.range(at: 1))
            if title.range(of: #"%|save|up to"#, options: .regularExpression) != nil {
                return Self.cleanOffer(title, cutters: cutters)
            }
        }
        guard let re = try? NSRegularExpression(pattern: pat),
              let m = re.firstMatch(in: sentence,
                                    range: NSRange(location: 0, length: (sentence as NSString).length)) else { return "" }
        let start = m.range.location
        let top = min(sentence.count, start + 120)
        let slice = String(sentence[sentence.index(sentence.startIndex, offsetBy: start)..<sentence.index(sentence.startIndex, offsetBy: top)])
        var candidate = slice
        // When the sentence leads with a short title ("Flash Sale At Least 30%"),
        // fold it back in so bullets read fully rather than starting at "% off".
        if slice.hasPrefix("%") {
            let pre = String(sentence[..<sentence.index(sentence.startIndex, offsetBy: start)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let lpre = pre.lowercased()
            let hasLetter = pre.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
            if pre.count >= 5 && pre.count <= 45 && hasLetter
                && ["." , ":", "/"].allSatisfy({ !pre.contains($0) })
                && !lpre.contains(" from ") && !lpre.contains(" until ") {
                candidate = pre + slice
            }
        }
        return Self.cleanOffer(candidate, cutters: cutters)
    }

    /// Trims an offer fragment at the earliest cutter (" and up to ", " is
    /// available ", date intros, commas…), then strips stray quote marks so
    /// bullets read as natural phrases.
    private static func cleanOffer(_ slice: String, cutters: [String]) -> String {
        var best = slice
        var bestDist = Int.max
        for cut in cutters {
            if let r = slice.range(of: cut) {
                let d = slice.distance(from: slice.startIndex, to: r.lowerBound)
                if d < bestDist { bestDist = d; best = String(slice[..<r.lowerBound]) }
            }
        }
        var t = best.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, "ˈ'’“”‘’[".contains(last) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Makes a scraped date range read naturally: "available from …" →
    /// "runs from …", month names capitalized.
    private static func cleanDate(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = t.lowercased()
        for (hit, rep) in [("available from ", "runs from "), ("running from ", "runs from "),
                           ("starts ", "runs from ")] where lead.hasPrefix(hit) {
            t = rep + String(t.dropFirst(hit.count))
            break
        }
        return capitalizeMonths(t)
    }

    /// Full-sentence term bullets: sentences that state a real requirement,
    /// exclusion, payment rule or limit — never bare fragments like "excluded".
    private static func termSentences(_ sources: [(title: String, url: String, body: String)], limit: Int = 8) -> [String] {
        let keys = ["not available", "in conjunction", "cannot be combined", "cannot be used", "not be used",
                    "not valid", "exclud", "while stocks last", "normal retail quantit", "new orders",
                    "100% payment", "full payment", "payment at the", "based on the", "recommended retail",
                    "retail price", "r.r.p", "rrp", "standard terms", "gift card", "does not apply",
                    "not applicable", "clearance", "subject to availability", "quantities only"]
        let boiler = ["subscribe", "sign in", "log in", "menu", "cookie", "my account", "newsletter"]
        var out = [String]()
        for s in sources {
            for sentence in sentenceParts(s.body) {
                let l = sentence.lowercased()
                guard l.count <= 170, keys.contains(where: { l.contains($0) }) else { continue }
                // Skip numbered promotion clauses ("1. 'At Least 30% Off …'")
                // and any sentence that is itself an offer announcement — it
                // belongs in Current promotions, not the terms.
                if l.contains("% off") { continue }
                if l.range(of: #"^\s*\d+\.\s*["'“”‘’]?.{0,8}% off|^\s*\d+\.\s*["'“”‘’]?.{0,12}save up to"#, options: .regularExpression) != nil { continue }
                if boiler.contains(where: { l.contains($0) }) { continue }
                if out.contains(where: {
                    let a = sentence, b = $0
                    return a == b || a.contains(b) || b.contains(a)
                }) { continue }
                out.append(sentence)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Splits page text into sentences on "." + whitespace, protecting
    /// decimals and version numbers ("1.6") and numbered clause intros
    /// ("1. 'At Least …'") from being torn apart.
    private static func sentenceParts(_ body: String) -> [String] {
        return body
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\d)\.(?=\s)"#, with: ".¶", options: .regularExpression)
            .split(separator: "¶")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 15 }
    }

    /// Closes the deal-shaped answer the way Perplexity does: a natural
    /// invitation that maps the named product categories to their offer.
    private static func closingOfferNote(_ query: String, sources: [(title: String, url: String, body: String)]) -> String {
        let subject = subjectPhrase(query)
        let bodies = sources.map { $0.body.lowercased() }.joined(separator: " ")
        let categories: [(String, String)] = [("sofas", "sofas"), ("mattresses", "mattresses"), ("outdoor", "outdoor furniture"),
                                              ("bedroom", "bedroom furniture"), ("homewares", "homewares"), ("rugs", "rugs"),
                                              ("dining", "dining furniture"), ("casegoods", "casegoods")]
        var found: [String] = []
        for (needle, label) in categories where bodies.contains(needle) {
            found.append(label)
            if found.count >= 3 { break }
        }
        let list = found.isEmpty ? "which item" : found.joined(separator: ", ")
        if !subject.isEmpty && subject.lowercased() != "this retailer" {
            return "If you tell me what you're looking to buy (\(list)), I'll map the \(subject) promotion that applies and the effective discount and conditions for that category."
        }
        return "If you tell me what you're looking to buy (\(list)), I'll point you to the promotion that applies and the exact conditions for that category."
    }

    /// Extracts short, actionable "offer" bullets: keywords that signal active
    /// promotions, percentages, dates, and product categories.
    private static func offerFacts(_ sources: [(title: String, url: String, body: String)]) -> [String] {
        var facts = [String]()
        let patterns = [
            #"up to \d{1,3}\s?% (?=off|discount|saving)"#,
            #"\d{1,3}\s?% off"#,
            #"save (up to )?\$?\d[\d,]*(\.\d+)?( %|%)?"#,
            #"save \$?[\d,]+"#,
            #"(from|until|ends|runs|valid)( [a-z]+ )?\d{1,2} \w+ 20\d\d"#,
            #"10% back"#,
            #"free delivery"#
        ]
        let datePat = #"(\d{1,2}[/ .]\d{1,2}[/ .]\d{2,4}|\d{1,2} \w+ 20\d\d|\d{1,2} \w{3} \d{2,4})"#
        for s in sources {
            for p in patterns {
                for m in matches(p, in: s.body).prefix(3) {
                    let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !facts.contains(trimmed) { facts.append(trimmed) }
                }
            }
            // Capture the date range a promotion spans, the single most useful
            // factual clinch for shoppers.
            let dates = matches(datePat, in: s.body).prefix(2)
            if dates.count >= 2 {
                let range = "Offer period: \(dates[0]) – \(dates[1])"
                if !facts.contains(range) { facts.append(range) }
            }
        }
        return facts
    }

    private static func bullets(_ items: [String]) -> String {
        guard !items.isEmpty else { return "• None clearly stated in the sources I could fetch." }
        return items.enumerated().map { "• \($0.element)" }.joined(separator: "\n")
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        let all = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return all.map { ns.substring(with: $0.range) }
    }

    /// Capitalizes month names inside a date phrase so scraped lowercase
    /// "31 august 2026" reads naturally as "31 August 2026".
    private static func capitalizeMonths(_ s: String) -> String {
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        var fixed = s
        for month in months {
            fixed = fixed.replacingOccurrences(of: " \(month) ", with: " \(month.capitalized) ")
        }
        return fixed
    }

    /// Makes a raw offer fragment read naturally in a headline, e.g. "Up to
    /// 50%" → "up to 50% off" and "50% off" stays as-is. Downcases so it can
    /// embed mid-sentence.
    private static func normalizeDeal(_ frag: String) -> String {
        var t = frag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("up to ") || t.lowercased().hasPrefix("up ") || t.lowercased().hasPrefix("upto ") {
            t = t.replacingOccurrences(of: #"(?i)^up\s?to\s*"#, with: "", options: .regularExpression)
            t = "up to \(t)"
        }
        if (t.contains("%") && !t.lowercased().contains(" off") && !t.lowercased().contains(" discount") && !t.lowercased().contains(" saving") && !t.lowercased().contains(" back")) {
            t += " off"
        } else if t.lowercased().hasPrefix("save ") && !t.contains("on ") && !t.contains("until ") {
            t += " on furniture"
        }
        return t
    }

    private static func titlize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "The sources I fetched cover the current status, but the pages have updated their wording." }
        let first = String(t.prefix(1)).uppercased()
        let rest = String(t.dropFirst())
        var first2 = first + rest
        if !first2.hasSuffix(".") { first2 += "." }
        return first2
    }

    private func streamFromLocal(_ history: [LLMMessage], research: String, sessionID: UUID,
                                 images: [LLMImage] = [], messageIndex: Int) async -> String {
        var messages = history
        if !research.isEmpty {
            messages.append(LLMMessage(role: "system",
                                       content: "Context from web research. Answer the user's question directly, using only what is relevant and without repeating unrelated sources:\n\(research)"))
        }
        let msgIdx = messageIndex

        // Report live generation progress to the UI (percentage of max_tokens).
        responseTokens = 0
        responsePercent = 0
        isResponding = true

        // Batch UI publication while streaming: mutating + republishing the
        // conversation on every token thrashes SwiftUI and spikes CPU. We only
        // flush to the published array every `flushEvery` tokens.
        var pendingText = ""
        var sinceFlush = 0
        let flushEvery = 16
        let maxTokens = Double(LLMService.maxTokens)

        let full = await llm.streamChat(messages: messages, images: images) { [weak self] token in
            guard let self else { return }
            pendingText.append(token)
            sinceFlush += 1
            self.responseTokens = pendingText.count
            self.responsePercent = min(1.0, Double(pendingText.count) / maxTokens)
            guard sinceFlush >= flushEvery else { return }
            sinceFlush = 0
            self.writeStreaming(pendingText, sessionID: sessionID, messageIndex: msgIdx)
        }
        isResponding = false
        responsePercent = 0
        // Final flush — replaces the placeholder with the exact final text.
        if let i = self.sessions.firstIndex(where: { $0.id == sessionID }),
           self.sessions[i].messages.indices.contains(msgIdx) {
            if full.isEmpty {
                self.sessions[i].messages.remove(at: msgIdx)
            } else {
                self.sessions[i].messages[msgIdx].text = full
            }
        }
        return full
    }

    /// Streams a reply from a configured cloud LLM provider, reporting live
    /// progress to the UI exactly like the local path.
    private func streamFromProvider(_ history: [LLMMessage], research: String, sessionID: UUID,
                                    images: [LLMImage] = [], provider: CloudProviderStore.Provider,
                                    messageIndex: Int) async -> String {
        var messages = history
        if !research.isEmpty {
            messages.append(LLMMessage(role: "system",
                                       content: "Context from web research. Answer the user's question directly, using only what is relevant and without repeating unrelated sources:\n\(research)"))
        }
        let msgIdx = messageIndex

        responseTokens = 0
        responsePercent = 0
        isResponding = true

        var pendingText = ""
        var sinceFlush = 0
        let flushEvery = 16
        let maxTokens = Double(LLMService.maxTokens)

        let full = await cloud.streamChat(messages: messages, images: images) { [weak self] token in
            guard let self else { return }
            pendingText.append(token)
            sinceFlush += 1
            self.responseTokens = pendingText.count
            self.responsePercent = min(1.0, Double(pendingText.count) / maxTokens)
            guard sinceFlush >= flushEvery else { return }
            sinceFlush = 0
            self.writeStreaming(pendingText, sessionID: sessionID, messageIndex: msgIdx)
        }
        isResponding = false
        responsePercent = 0
        if let i = self.sessions.firstIndex(where: { $0.id == sessionID }),
           self.sessions[i].messages.indices.contains(msgIdx) {
            if full.isEmpty {
                self.sessions[i].messages.remove(at: msgIdx)
            } else {
                self.sessions[i].messages[msgIdx].text = full
            }
        }
        return full
    }

    /// Fallback chain used when a configured cloud provider fails: local LLM,
    /// then offline research, then the rule-based engine. Writes any streamed
    /// reply into the caller-provided placeholder (`messageIndex`).
    private func localOrFallback(text: String, research: String, history: [LLMMessage],
                                 images: [LLMImage], sessionID: UUID, messageIndex: Int,
                                 offlineReply: String = "") async -> String {
        if await self.llm.isReachable() {
            return await self.streamFromLocal(history, research: research,
                                              sessionID: sessionID, images: images,
                                              messageIndex: messageIndex)
        }
        if self.looksLikeResearch(text) || !research.isEmpty {
            let offline = await self.runOfflineResearch(text)
            if !offline.isEmpty { return offline }
        }
        return offlineReply.isEmpty ? self.fallback.generateReply(to: text) : offlineReply
    }

    @MainActor
    private func writeStreaming(_ text: String, sessionID: UUID, messageIndex: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[i].messages.indices.contains(messageIndex) else { return }
        sessions[i].messages[messageIndex].text = text
    }

    // MARK: - Message helpers

    /// Deletes every message after the given one, rolling the conversation
    /// back to that point (used by the "Revert to here" chat action).
    func revert(to messageID: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeID }),
              let pos = sessions[idx].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let removed = sessions[idx].messages.count - (pos + 1)
        guard removed > 0 else { return }
        sessions[idx].messages.removeSubrange((pos + 1)...)
        persist()
    }

    /// Deletes a single message from the active session.
    func deleteMessage(_ messageID: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeID }) else { return }
        sessions[idx].messages.removeAll { $0.id == messageID }
        persist()
    }

    private func append(_ message: ChatMessage, to id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].messages.append(message)
    }

    private func append(streaming: String, to id: UUID) {
        append(ChatMessage(role: .assistant, text: streaming), to: id)
    }

    private func indexOfLastMessage(_ id: UUID) -> Int {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return 0 }
        let hasPlaceholder = sessions[idx].messages.last?.role == .assistant
        return hasPlaceholder ? (sessions[idx].messages.count - 1) : 0
    }

    private func historyFor(_ id: UUID, limit: Int = 12, memoryContext: String = "") -> [LLMMessage] {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return [] }
        let messages = Array(sessions[idx].messages.suffix(limit * 2))
        let query = messages.last?.role == .user ? messages.last!.text : ""
        var out: [LLMMessage] = []
        out.append(LLMMessage(role: "system", content: baseSystemInstruction()))
        // Speak in the user's chosen language (Filipino/Tagalog, etc.).
        out.append(LLMMessage(role: "system", content: LanguageSettings.current.instruction))
        if computerControl {
            out.append(LLMMessage(role: "system", content: AgentExecutor.instructions))
            out.append(LLMMessage(role: "system", content: SelfImprovementService.agentGuidance))
        }
        // Only surface remembered facts that are relevant to this window's
        // question, so earlier chats don't leak unrelated topics in here.
        if !memoryFacts.isEmpty {
            let relevant = relevantMemoryFacts(for: query)
            if !relevant.isEmpty {
                out.append(LLMMessage(role: "system",
                                      content: "Remembered facts relevant to this question:\n- " +
                                        relevant.joined(separator: "\n- ")))
            }
        }
        // Inject the user's profile, relevant long-term memory, and any matching
        // skills/knowledge so the agent "remembers" across chats.
        if let profile = ProfileStore.shared.activeProfile, !profile.name.isEmpty {
            out.append(LLMMessage(role: "system",
                                  content: "You are helping \(profile.contextLine)"))
            out.append(LLMMessage(role: "system", content: detailInstruction(profile.detailLevel)))
            out.append(LLMMessage(role: "system", content: assistantStyleInstruction()))
        }
        out.append(LLMMessage(role: "system", content: answerModeInstruction()))
        // Inject the session's task-specific bot, if one is selected.
        if let session = sessions.first(where: { $0.id == id }),
           let bot = BotStore.shared.bot(withID: session.botID) {
            out.append(LLMMessage(role: "system", content: bot.prompt))
        }
        // Inject the session's applied prompt preset, if one is selected.
        if let session = sessions.first(where: { $0.id == id }),
           session.presetID != nil,
           let preset = PresetStore.shared.preset(withID: session.presetID) {
            out.append(LLMMessage(role: "system",
                                  content: "Follow this user-applied preset instruction:\n\(preset.systemPrompt)"))
        }
        let context = memoryContext.isEmpty ? knowledge.contextForPrompt(query) : memoryContext
        if !context.isEmpty {
            out.append(LLMMessage(role: "system", content: context))
        }
        for m in messages {
            out.append(LLMMessage(role: m.role.apiRole, content: m.text))
        }
        return out
    }

    /// The standing behaviour/format instruction injected into every window so
    /// answers stay direct, on-topic, and neatly formatted.
    private func baseSystemInstruction() -> String {
        """
        You are Nexie, a friendly, focused local assistant. Answer the user's question directly and \
        only about that topic, using the conversation in this window as your context. Keep answers \
        concise and natural — no citation markers like [1], no "Takeaway:" labels, and no dumping \
        every possible fact. Say what they need in plain sentences; use a short bulleted list only \
        when it genuinely helps (e.g. steps, a few options, pros and cons). \
        Do NOT bring up unrelated subjects, other chats, or extra links. Never pad your answer with \
        an "I can also..." list of capabilities.

        Brevity rules:
        - Prefer short answers unless the user explicitly asks for more detail.
        - For simple factual questions (date, time, day, quick definitions, simple conversions), \
        answer in 1-2 sentences by default.
        - Do NOT add extra sections (moon phase, zodiac, holidays, birthstones, long summaries) \
        unless the user explicitly asks for them.
        - If the user seems to want more detail (e.g. "tell me more about today"), you may expand \
        with related info.
        - When in doubt, err on the side of brevity. The user can always ask for "more details".

        Formatting rules:
        - Always use Markdown when listing multiple items.
        - Use bullet lists (- item) for things like: time zone, day of year / week number, \
        moon phase, holidays, date formats.
        - Use short paragraphs, not giant blocks of text.
        - For simple questions (date, time, day), answer in 1-2 sentences. Do NOT add sections \
        like "Key details", "Date formats", or "Takeaway". Do NOT invent citations like [1].

        Date/time questions:
        - For "What's the date today?", "What time is it?", or "What day is it?", answer briefly, \
        e.g. "It's Friday, September 4, 2026. It's currently 9:19 AM in Asia/Manila." (Use the \
        real current time.)
        - Only add the full breakdown (day of year, week number, moon phase, holidays, date \
        formats) if the user explicitly asks for more, e.g. "Tell me everything about today", \
        "What's the moon phase?", or "Any holidays this week?".
        """
    }

    /// Appends a user-chosen "answer detail level" preference to the prompt so
    /// it can be tuned in Settings without changing the model.
    private func detailInstruction(_ level: DetailLevel) -> String {
        let detail: String
        switch level {
        case .brief:
            detail = """
            The user prefers very short answers.
            - For simple questions (date, time, day, quick facts), answer in 1 sentence when possible.
            - Avoid extra sections unless explicitly requested.
            """
        case .normal:
            detail = """
            The user prefers normal detail.
            - For simple questions, 1-3 sentences is usually enough.
            - Add extra info (moon phase, holidays, etc.) only if clearly relevant or requested.
            """
        case .detailed:
            detail = """
            The user likes detailed answers.
            - You may include related info like moon phase, holidays, zodiac, etc. when relevant.
            - Still avoid unnecessary verbosity for very simple questions.
            """
        }
        return "User preference:\n\(detail)"
    }

    /// Injects instructions that set the depth/structure of an answer based on
    /// the chosen Answer mode (Quick / Research / Deep).
    private func answerModeInstruction() -> String {
        switch answerMode {
        case .quick:
            return """
            Answer mode: Quick.
            - Give the shortest correct answer that directly satisfies the question.
            - No web research, no citations, no section headers.
            - 1-3 sentences; use a short bullet list only if the facts genuinely need it.
            """
        case .research:
            return """
            Answer mode: Research.
            - You have live web research results. Use them to answer accurately and cite sources inline as [1], [2], etc.
            - Open with a one-line direct answer, then a short, structured explanation.
            - Keep it focused; don't pad with unrelated sections.
            """
        case .deep:
            return """
            Answer mode: Deep.
            - You have live web research results. Use them and cite sources inline as [1], [2], etc.
            - Provide a thorough, structured answer: a direct takeaway up front, then organized sections.
            - Include comparisons, trade-offs, or a small table when it genuinely helps.
            - End with a concise bottom-line recommendation.
            """
        }
    }

    /// Injects the user-selected "assistant style" (Jarvis-like / analyst /
    /// buddy) into the prompt. Reads the shared AssistantSettings so the choice
    /// made in Settings applies to every reply.
    private func assistantStyleInstruction() -> String {
        let base = "You are Nexie, a local desktop assistant for a customer-service professional in the Philippines. You help with enquiries, research, writing, and everyday tasks."
        let style: String
        switch AssistantSettings.shared.style {
        case .jarvis:
            style = """
            Personality and style (JARVIS):
            - Be the archetypal JARVIS: calm, refined, quietly confident, and ever so slightly dry in humour. You are professional but never stiff, and you treat the user with polished courtesy (you may address them as "sir" or "madam" sparingly, e.g. "Very good, sir.").
            - Above all: be direct and on-task. Answer exactly what was asked, nothing padded, no waffle.
            - Keep replies short and punchy. For simple questions (date, time, quick facts) use ONE sentence when possible, max two.
            - Sound effortless: prefer plain, clean sentences over bullet-heavy reports, unless the user wants a list or comparison. When a list genuinely helps, keep it tight.
            - Be quietly proactive. If the request suggests an obvious next step, offer it in one short line (e.g. "Shall I draft that up for you?" or "I can run that through research if you like.").
            - Use natural, assured phrasing and occasional understated wit — but never make it about yourself, and never break character into a big disclaimer.
            - Do NOT say things like "Here is a detailed report" for simple queries, and do not bury the answer under filler.
            """
        case .analyst:
            style = """
            Personality and style:
            - Provide thorough, structured answers with sections and bullet points.
            - Include relevant details, caveats, and sources.
            """
        case .buddy:
            style = """
            Personality and style:
            - Friendly, casual tone.
            - Still accurate, but more conversational and less formal.
            """
        }
        let user = ProfileStore.shared.activeProfile
        let roleLine = (user?.tagline.isEmpty == false) ? (user!.tagline) : "works in customer service / e-commerce support"
        return """
        \(base)


        \(style)


        User context:
        - Location: Philippines (Asia/Manila).
        - Works in customer service / e-commerce support, often handling furniture and retail enquiries.
        - Role: \(roleLine)
        - Prefers clear, step-by-step instructions when learning technical tasks.
        """
    }

    /// The subset of remembered facts that share vocabulary with the current
    /// question, so prior conversations outside this window stay out of the way.
    private func relevantMemoryFacts(for query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        let qWords = Set(query.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 2 })
        guard !qWords.isEmpty else { return [] }
        return memoryFacts.filter { fact in
            let f = fact.lowercased()
            return qWords.contains { f.contains($0) }
        }
    }

    private func trimTitle(_ session: inout ChatSession, from first: String) {
        let words = first.split(separator: " ").prefix(6).joined(separator: " ")
        session.title = words.isEmpty ? "Chat" : String(words)
    }

    // MARK: - Memory (simple fact extraction)

    func remember(conversation: String) {
        // Very light heuristic memory: keeep short declarative sentences.
        for line in conversation.split(separator: "\n") {
            let s = String(line)
            guard s.count < 120, s.contains(" ") else { continue }
            if !memoryFacts.contains(s) {
                memoryFacts.append(s)
            }
        }
        if memoryFacts.count > 40 {
            memoryFacts.removeFirst(memoryFacts.count - 40)
        }
        saveMemory()
    }

    func addMemoryFact(_ fact: String) {
        guard !memoryFacts.contains(fact) else { return }
        memoryFacts.append(fact)
        saveMemory()
    }

    func clearMemory() {
        memoryFacts.removeAll()
        saveMemory()
    }

    private func loadMemory() {
        let url = workspace.rootURL.appendingPathComponent("memory.json")
        if let data = try? Data(contentsOf: url),
           let facts = try? JSONDecoder().decode([String].self, from: data) {
            memoryFacts = facts
        }
    }

    private func saveMemory() {
        let url = workspace.rootURL.appendingPathComponent("memory.json")
        if let data = try? JSONEncoder().encode(memoryFacts) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
