import SwiftUI

/// The conversational tone Nexie uses. Set globally in Settings and injected
/// into the chat system prompt so the same choice drives every reply.
enum AssistantStyle: String, CaseIterable, Identifiable {
    case jarvis = "Jarvis-like"
    case analyst = "Detailed analyst"
    case buddy = "Friendly buddy"

    var id: String { rawValue }
}

/// App-wide settings for conversational voice (the "Jarvis" feel): which voice
/// speaks replies, how fast, the assistant style, and a fast-mode toggle. Kept
/// separate from user Profiles so the voice/style apply to every conversation.
@MainActor
final class AssistantSettings: ObservableObject {
    static let shared = AssistantSettings()

    @AppStorage("assistant.style") var styleRaw: String = AssistantStyle.jarvis.rawValue
    @AppStorage("assistant.jarvisVoice") var jarvisVoice: String = "am_adam"
    @AppStorage("assistant.jarvisSpeed") var jarvisSpeed: Double = 1.05
    @AppStorage("assistant.fastVoiceMode") var fastVoiceMode: Bool = false
    /// Off by default: a fresh install starts with genuinely empty stores.
    /// Only when enabled do Activity/Approval/Automation show sample data.
    @AppStorage("app.demoMode") var demoMode: Bool = false

    var style: AssistantStyle {
        get { AssistantStyle(rawValue: styleRaw) ?? .jarvis }
        set { styleRaw = newValue.rawValue }
    }

    /// Speed to use for spoken replies. When fast mode is on, force a slightly
    /// higher floor so replies come out snappier (may reduce naturalness).
    var effectiveSpeed: Double {
        fastVoiceMode ? max(jarvisSpeed, 1.2) : max(jarvisSpeed, 0.5)
    }

    /// The jarvis voice if it happens to be a kokoro on-device voice, or the
    /// macOS `say` fallback. SpeechEngine handles routing transparently.
    var speakingVoice: String { jarvisVoice }
}