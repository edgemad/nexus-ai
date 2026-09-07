import Foundation

/// A task-specific assistant ("bot") the user can create and attach to a chat.
/// Bots are pure configuration — a persona, an accent, and a system prompt that
/// steers how the model behaves for the conversation. They're stored locally
/// and applied whenever a session has one selected.
struct Bot: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var iconName: String
    var accent: String          // hex color, e.g. "2F6FD8"
    var tagline: String         // one-line purpose shown in the picker
    var systemPrompt: String    // steering instructions injected as a system message
    var isPreset: Bool          // built-in bots can't be deleted

    init(id: UUID = UUID(),
         name: String,
         iconName: String = "sparkles",
         accent: String = "2F6FD8",
         tagline: String = "",
         systemPrompt: String = "",
         isPreset: Bool = false) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.accent = accent
        self.tagline = tagline
        self.systemPrompt = systemPrompt
        self.isPreset = isPreset
    }

    /// The full system message sent to the model when this bot is active.
    var prompt: String {
        var p = "You are \(name), a focused assistant."
        if !tagline.isEmpty {
            p += " Purpose: \(tagline)."
        }
        if !systemPrompt.isEmpty {
            p += " Instructions: \(systemPrompt)"
        }
        return p
    }
}