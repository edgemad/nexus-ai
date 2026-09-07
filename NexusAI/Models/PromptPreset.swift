import Foundation

/// A named, reusable instruction template the user can save and apply to any
/// chat. Presets are the "prompt presets" concept — inject an extra system
/// prompt to steer replies without creating a whole bot persona.
struct PromptPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var systemPrompt: String
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         systemPrompt: String,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
    }
}