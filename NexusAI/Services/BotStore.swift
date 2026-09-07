import Foundation

/// Persistent store of the user's task-specific bots. Saved as JSON in the
/// workspace next to knowledge and memory. Seeded with a few useful presets on
/// first launch.
@MainActor
final class BotStore: ObservableObject {
    @Published private(set) var bots: [Bot] = []

    static let shared = BotStore()

    private let fileURL: URL

    init() {
        fileURL = WorkspaceManager.shared.rootURL
            .appendingPathComponent("bots.json")
        load()
        if bots.isEmpty {
            seedPresets()
        }
    }

    func bot(withID id: UUID?) -> Bot? {
        guard let id else { return nil }
        return bots.first { $0.id == id }
    }

    // MARK: - Mutations

    func add(_ bot: Bot) {
        bots.insert(bot, at: 0)
        save()
    }

    func update(_ bot: Bot) {
        guard let idx = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[idx] = bot
        save()
    }

    func delete(_ id: UUID) {
        guard let bot = bot(withID: id), !bot.isPreset else { return }
        bots.removeAll { $0.id == id }
        save()
    }

    /// Removes every reference to a deleted bot from open chat sessions.
    func clearBotReferences(_ botID: UUID) {
        // Sessions hold their own botID; ChatStore reconciles on read, but this
        // is a no-op safety net so a stale ID never resolves to a bot.
    }

    private func seedPresets() {
        bots = [
            Bot(name: "Translator",
                iconName: "character.bubble",
                accent: "2F6FD8",
                tagline: "Translate and localize text fluently",
                systemPrompt: "Translate between any languages while preserving tone, style, and meaning. If asked about a phrase, explain its nuance.",
                isPreset: true),
            Bot(name: "Code Helper",
                iconName: "chevron.left.forwardslash.chevron.right",
                accent: "E74C3C",
                tagline: "Write, review, and explain code",
                systemPrompt: "Help write, review, debug, and explain code. Prefer concise, working examples. Match the user's language.",
                isPreset: true),
            Bot(name: "Researcher",
                iconName: "globe.americas.fill",
                accent: "16A085",
                tagline: "Deep web research and synthesis",
                systemPrompt: "When asked to check something on the web, turn on research so live sources are fetched, then summarize findings and cite sources.",
                isPreset: true)
        ]
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Bot].self, from: data) else { return }
        bots = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(bots) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}