import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    var text: String
    let date: Date
    /// Sources backing a research answer (Phase 9 evidence), rendered as
    /// clickable chips under the message.
    var sources: [ResearchSource] = []
    /// 0–100 verdict confidence for research answers (nil = not measured).
    var researchConfidence: Int? = nil

    init(id: UUID = UUID(), role: Role, text: String, date: Date = Date(),
         sources: [ResearchSource] = [], researchConfidence: Int? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.sources = sources
        self.researchConfidence = researchConfidence
    }

    enum Role: String, Codable {
        case user, assistant

        var isUser: Bool { self == .user }

        var apiRole: String { rawValue }
    }

    // Older saved chats predate sources/researchConfidence; decode them with
    // defaults so history is never dropped and never crashes.
    private enum CodingKeys: String, CodingKey {
        case id, role, text, date, sources, researchConfidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        sources = try c.decodeIfPresent([ResearchSource].self, forKey: .sources) ?? []
        researchConfidence = try c.decodeIfPresent(Int.self, forKey: .researchConfidence)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(date, forKey: .date)
        try c.encode(sources, forKey: .sources)
        try c.encodeIfPresent(researchConfidence, forKey: .researchConfidence)
    }
}

@MainActor
final class ChatEngine: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isTyping = false

    private var pendingReplies: [String] = []

    init() {
        messages = [
            ChatMessage(role: .assistant,
                        text: "Hello! I'm your local Nexie assistant. I run fully on this Mac. Ask me to summarize, plan, explain, explore files, or help with a task.",
                        date: Date())
        ]
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: trimmed, date: Date()))
        isTyping = true

        let reply = generateReply(to: trimmed)
        // Simulate a short "thinking" delay before streaming the reply.
        pendingReplies = reply.map { String($0) }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await deliverPending()
        }
    }

    private func deliverPending() async {
        while !pendingReplies.isEmpty {
            if messages.last?.role == .user {
                messages.append(ChatMessage(role: .assistant, text: "", date: Date()))
            }
            let char = pendingReplies.removeFirst()
            messages[messages.count - 1].text.append(char)
            try? await Task.sleep(nanoseconds: 18_000_000)
        }
        isTyping = false
    }

    func clear() {
        pendingReplies.removeAll()
        messages = [ChatMessage(role: .assistant,
                                text: "Conversation cleared. Ask me anything.",
                                date: Date())]
        isTyping = false
    }

    /// Rolls the conversation back to (and including) the given message.
    func revert(to messageID: UUID) {
        guard let pos = messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard messages.count > pos + 1 else { return }
        messages.removeSubrange((pos + 1)...)
        pendingReplies.removeAll()
        isTyping = false
    }

    /// Deletes a single message from the timeline.
    func deleteMessage(_ messageID: UUID) {
        messages.removeAll { $0.id == messageID }
        pendingReplies.removeAll()
        isTyping = false
    }

    // MARK: - Reply generation (rule-based, fully offline)

    func generateReply(to prompt: String) -> String {
        let p = prompt.lowercased()

        if p.contains("hello") || p.contains("hi ") || p == "hi" || p.contains("hey") {
            return "Hello! How can I help you today? I can summarize documents, plan tasks, explain concepts, or explore files on this Mac."
        }

        if p.contains("who are you") || p.contains("what are you") {
            return "I'm Nexie, a local-first assistant built to run entirely on your Mac. I keep your data and memory on-device. My model, tools, and identity all live here — nothing leaves your machine unless you choose to connect a cloud provider."
        }

        if p.contains("memory") {
            return "I maintain three layers of memory: your identity, pinned facts, and per-session episodes. At the end of each conversation I distill what matters, score it by salience, and store a compact slice so I can recall it later without bloating my context."
        }

        if p.contains("offline") || p.contains("privacy") {
            return "Everything runs locally on your Mac. Your chats, files, and memory never leave the device unless you explicitly connect a cloud model. I also offer a privacy filter that scrubs personal data before it goes to any external service."
        }

        if p.contains("plan") {
            return "Here's a simple planning approach: 1) Define the clear end goal. 2) Break it into small, verifiable steps. 3) Decide which step to start with. 4) Execute against a checklist and verify each step before moving on. Want me to draft a concrete plan for a specific task?"
        }

        if p.contains("summarize") || p.contains("summary") {
            return "I can summarize text, documents, or folders. Open the Files panel and connect a folder, then paste the content here and I'll produce a concise summary with the key points."
        }

        if p.contains("help") {
            return "Sure. I can help with: summarizing or explaining text, planning multi-step tasks, exploring and inspecting your files, monitoring system health, and managing automations. Use the sidebar to switch between these workspaces."
        }

        if p.contains("time") || p.contains("date") {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a, EEEE, MMM d"
            return "It's \(formatter.string(from: Date()))."
        }

        if p.contains("thank") {
            return "You're welcome! Let me know if there's anything else I can do."
        }

        if p.contains("bye") || p.contains("goodbye") {
            return "Goodbye! I'll be here in the sidebar whenever you need me."
        }

        if p.contains("file") || p.contains("folder") || p.contains("workspace") {
            return "You can browse files and your on-disk Workspace from the sidebar. Ask me about a specific file or folder and I'll inspect it. For a live lookup (like checking a website or its pricing), turn on 'Deep web research' above the send box and I'll fetch current sources."
        }

        if p.contains("website") || p.contains("site") || p.contains(".com") || p.contains(".au")
            || p.contains("promotion") || p.contains("terms") || p.contains("pricing") {
            return "I'll check that for you. Turn on 'Deep web research' above the send box and I'll pull the current page and its exact terms, then answer directly."
        }

        return """
        I can't answer that accurately from local rules alone, and I won't guess or drift off-topic.

        To get exactly what you need:
        • Turn on \"Deep web research\" above the send box for live topics (pricing, news, a website, terms) — I'll fetch current sources and answer directly.
        • Select a text model in the Models tab for open-ended or complex reasoning.
        • Or rephrase your question around one clear goal, and I'll keep the answer focused on that.
        """
    }
}
