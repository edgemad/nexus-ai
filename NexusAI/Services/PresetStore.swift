import Foundation

/// Persistent store of the user's reusable prompt presets. Saved as JSON in
/// the workspace root, seeded with a couple of handy defaults on first launch.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [PromptPreset] = []

    static let shared = PresetStore()

    private let fileURL: URL

    init() {
        fileURL = WorkspaceManager.shared.rootURL
            .appendingPathComponent("presets.json")
        load()
        if presets.isEmpty {
            seedPresets()
        }
    }

    func preset(withID id: UUID?) -> PromptPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    // MARK: - Mutations

    @discardableResult
    func add(_ preset: PromptPreset) -> PromptPreset {
        presets.insert(preset, at: 0)
        save()
        return preset
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    private func seedPresets() {
        presets = [
            PromptPreset(name: "Concise",
                         systemPrompt: "Prefer short, direct answers. Skip filler and markdown unless it helps clarity. Use bullet points only when the answer genuinely benefits from them."),
            PromptPreset(name: "Detailed explainer",
                         systemPrompt: "Explain thoroughly and step by step. Define any jargon you use and include concrete examples. Aim for depth over brevity."),
            PromptPreset(name: "Code reviewer",
                         systemPrompt: "Review code for correctness, security, performance, and style. Point out real problems with line-level notes and suggest concise fixes.")
        ]
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PromptPreset].self, from: data) else { return }
        presets = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(presets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}