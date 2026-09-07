import Foundation
import SwiftUI

/// The type of a stored knowledge item.
enum KnowledgeType: String, Codable, CaseIterable, Identifiable {
    case skill = "Skill"
    case knowledge = "Knowledge"
    case memory = "Memory"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .skill: return "sparkles"
        case .knowledge: return "book"
        case .memory: return "brain"
        }
    }

    var tint: Color {
        switch self {
        case .skill: return .purple
        case .knowledge: return .blue
        case .memory: return .green
        }
    }
}

/// The semantic kind of a memory (borrowed from the reference project's taxonomy).
enum MemoryKind: String, Codable, CaseIterable, Identifiable {
    case fact = "Fact"
    case preference = "Preference"
    case skill = "Skill"
    case correction = "Correction"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .fact: return .blue
        case .preference: return Color(red: 0.22, green: 0.70, blue: 0.46)
        case .skill: return .purple
        case .correction: return .orange
        }
    }
}

/// A single item in the agent's persistent knowledge base.
struct KnowledgeItem: Identifiable, Codable, Equatable {
    let id: UUID
    var type: KnowledgeType
    var title: String
    var content: String
    var tags: [String]
    var source: String        // where it came from (manual, "chat reflection", a file, etc.)
    var createdAt: Date
    var updatedAt: Date

    /// For memories, a semantic kind (fact / preference / skill / correction).
    var memoryKind: MemoryKind?
    /// For skills, a short description used so the agent knows when to apply it.
    var skillDescription: String?
    /// For knowledge entries, the bundle name / topic they belong to.
    var topic: String?

    init(id: UUID = UUID(),
         type: KnowledgeType,
         title: String,
         content: String,
         tags: [String] = [],
         source: String = "manual",
         memoryKind: MemoryKind? = nil,
         skillDescription: String? = nil,
         topic: String? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.tags = tags
        self.source = source
        self.createdAt = Date()
        self.updatedAt = Date()
        self.memoryKind = memoryKind
        self.skillDescription = skillDescription
        self.topic = topic
    }

    // MARK: - Simple keyword scoring for retrieval

    /// Scores how relevant this item is to a query using token overlap.
    /// Higher is more relevant; used to pull context into the chat prompt.
    func relevance(to query: String) -> Double {
        let haystack = "\(title) \(content) \(tags.joined(separator: " ")) \(skillDescription ?? "") \(topic ?? "")"
            .lowercased()
        let tokens = Set(
            query.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 }
        )
        guard !tokens.isEmpty else { return 0 }
        var matched = 0
        for token in tokens {
            if haystack.contains(token) { matched += 1 }
        }
        return Double(matched) / Double(tokens.count)
    }
}

/// Persistent, local store of the agent's skills, knowledge base, and memory.
/// Saved as JSON in the workspace so everything is inspectable and portable.
@MainActor
final class KnowledgeStore: ObservableObject {
    @Published private(set) var items: [KnowledgeItem] = []

    static let shared = KnowledgeStore()

    private let fileURL: URL

    init() {
        fileURL = WorkspaceManager.shared.rootURL
            .appendingPathComponent("knowledge.json")
        load()
    }

    // MARK: - Queries

    var skills: [KnowledgeItem] { items.filter { $0.type == .skill } }
    var knowledge: [KnowledgeItem] { items.filter { $0.type == .knowledge } }
    var memories: [KnowledgeItem] { items.filter { $0.type == .memory } }

    func search(_ query: String) -> [KnowledgeItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        // Score every item and keep the strongest few that match.
        let scored = items.map { ($0, $0.relevance(to: q)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        return scored.prefix(6).map { $0.0 }
    }

    /// The context block to inject into an assistant prompt for a fresh query:
    /// relevant long-term memories plus matching knowledge/skills.
    func contextForPrompt(_ query: String) -> String {
        let relevant = search(query)
        let remembered = relevant.filter { $0.type == .memory }
        let learned = relevant.filter { $0.type != .memory }

        var blocks: [String] = []
        if !remembered.isEmpty {
            let lines = remembered.map { item -> String in
                let kind = item.memoryKind?.rawValue.lowercased() ?? "memory"
                return "- [\(kind)] \(item.content)"
            }
            blocks.append("Long-term memories about the user:\n" + lines.joined(separator: "\n"))
        }
        if !learned.isEmpty {
            let lines = learned.map { item -> String in
                var s = "• \(item.title): \(item.content)"
                if let desc = item.skillDescription, !desc.isEmpty {
                    s += " (apply when: \(desc))"
                }
                return s
            }
            blocks.append("Relevant skills and knowledge to apply:\n" + lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Mutations

    func add(_ item: KnowledgeItem) {
        items.insert(item, at: 0)
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func update(_ item: KnowledgeItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        var copy = item
        copy.updatedAt = Date()
        items[idx] = copy
        save()
    }

    /// Speaks from a chat exchange — records durable memories (fact, preference,
    /// skill, correction) so the assistant remembers across conversations.
    func learnFromConversation(userText: String, assistantText: String) {
        var extracted: [KnowledgeItem] = []

        let user = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty && user.count <= 220 {
            extracted.append(KnowledgeItem(
                type: .memory,
                title: "Recall",
                content: user,
                source: "chat reflection",
                memoryKind: .fact
            ))
        }

        // Light heuristic memory: keep short, declarative sentences from the reply.
        for line in assistantText.split(separator: "\n") {
            let s = String(line)
            guard !s.isEmpty, s.count < 140, s.contains(" ") else { continue }
            let lower = s.lowercased()
            let kind: MemoryKind
            if lower.contains("prefer") || lower.contains("like to") || lower.contains("would rather") {
                kind = .preference
            } else if lower.contains("learn") || lower.contains("can ") || lower.contains("I know") {
                kind = .skill
            } else if lower.contains("don't") || lower.contains("should not") || lower.contains("avoid") {
                kind = .correction
            } else {
                kind = .fact
            }
            extracted.append(KnowledgeItem(
                type: .memory,
                title: "Memory",
                content: s,
                source: "chat reflection",
                memoryKind: kind
            ))
        }

        // Merge: drop near-duplicates (same content) and cap total memory size.
        for item in extracted {
            let isDuplicate = memories.contains { existing in
                existing.content.lowercased() == item.content.lowercased()
            }
            if isDuplicate { continue }
            items.append(item)
        }
        trimMemoryIfNeeded()
        save()
    }

    private func trimMemoryIfNeeded() {
        let mems = memories
        if mems.count > 80 {
            let excess = mems.count - 80
            // Remove oldest memories by created date.
            let oldest = mems.sorted { $0.createdAt < $1.createdAt }.prefix(excess)
            let ids = Set(oldest.map { $0.id })
            items.removeAll { ids.contains($0.id) }
        }
    }

    func clearAll() {
        items.removeAll()
        save()
    }

    // MARK: - Persistence

    /// Reload items from disk (e.g. after the Python memory sidecar writes).
    func reload() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([KnowledgeItem].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
