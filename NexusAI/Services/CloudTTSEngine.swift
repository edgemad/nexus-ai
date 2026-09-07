import Foundation

/// The language the assistant should reply in and (for cloud TTS) speak in.
/// Used to drive Filipino/Tagalog, Cebuano, and all major languages — the
/// on-device engines don't support most of these, so a cloud provider is needed
/// for speech in those languages.
enum LanguageSettings {
    struct Language: Identifiable, Hashable, Equatable {
        let name: String
        let code: String      // locale-ish code for speech, "" = auto
        let instruction: String // what to tell the chat model
        var id: String { name }
    }

    /// Supported languages for the reply + speech setting.
    static let all: [Language] = [
        Language(name: "English", code: "", instruction: "Reply in English."),
        Language(name: "Filipino (Tagalog)", code: "fil", instruction: "Reply in Filipino/Tagalog."),
        Language(name: "Cebuano", code: "ceb", instruction: "Reply in Cebuano."),
        Language(name: "Waray", code: "war", instruction: "Reply in Waray."),
        Language(name: "Spanish", code: "es", instruction: "Reply in Spanish."),
        Language(name: "French", code: "fr", instruction: "Reply in French."),
        Language(name: "German", code: "de", instruction: "Reply in German."),
        Language(name: "Italian", code: "it", instruction: "Reply in Italian."),
        Language(name: "Portuguese", code: "pt", instruction: "Reply in Portuguese."),
        Language(name: "Chinese (Simplified)", code: "zh", instruction: "Reply in Simplified Chinese."),
        Language(name: "Japanese", code: "ja", instruction: "Reply in Japanese."),
        Language(name: "Korean", code: "ko", instruction: "Reply in Korean."),
        Language(name: "Hindi", code: "hi", instruction: "Reply in Hindi."),
        Language(name: "Arabic", code: "ar", instruction: "Reply in Arabic."),
        Language(name: "Russian", code: "ru", instruction: "Reply in Russian."),
        Language(name: "Dutch", code: "nl", instruction: "Reply in Dutch."),
        Language(name: "Swedish", code: "sv", instruction: "Reply in Swedish."),
        Language(name: "Turkish", code: "tr", instruction: "Reply in Turkish."),
        Language(name: "Indonesian", code: "id", instruction: "Reply in Indonesian."),
        Language(name: "Vietnamese", code: "vi", instruction: "Reply in Vietnamese."),
        Language(name: "Thai", code: "th", instruction: "Reply in Thai.")
    ]

    private static let key = "preferredLanguage"

    @MainActor static var current: Language {
        let name = UserDefaults.standard.string(forKey: key) ?? "English"
        return all.first { $0.name == name } ?? all[0]
    }
    @MainActor static func set(_ language: Language) {
        UserDefaults.standard.set(language.name, forKey: key)
    }
}

/// Cloud text-to-speech using an OpenAI-compatible `/v1/audio/speech` endpoint.
/// Unlike the bundled local engines (kokoro / macOS `say`), OpenAI TTS supports
/// a very broad set of languages — including Filipino/Tagalog and 50+ major
/// languages — because the model auto-detects the input language. We reuse the
/// API key + base URL configured in the AI Providers panel, so no extra setup.
@MainActor
final class CloudTTSEngine {
    /// Curated voices (OpenAI tts-1 / tts-1-hd).
    static let voices: [(id: String, label: String)] = [
        ("alloy", "Alloy (neutral)"),
        ("echo", "Echo (warm)"),
        ("fable", "Fable (British)"),
        ("onyx", "Onyx (deep)"),
        ("nova", "Nova (bright)"),
        ("shimmer", "Shimmer (soft)")
    ]

    /// Whether a cloud provider with a key is currently available.
    static var isConfigured: Bool {
        CloudProviderStore.shared.effectiveProvider != nil
    }

    /// Synthesizes `text` to audio and writes it to `outputURL`. `voice` is the
    /// OpenAI voice id. Returns the audio Data on success (used for in-memory
    /// playback so the clip isn't persisted). The model auto-detects the
    /// language from the text, so this speaks Tagalog, Cebuano-ish, and most
    /// major languages. Uses `tts-1-hd` — the higher-fidelity model — so speech
    /// (especially non-English) sounds more natural.
    static func speak(text: String, voice: String = "alloy", to outputURL: URL) async -> Data? {
        guard isConfigured, let provider = CloudProviderStore.shared.effectiveProvider else {
            return nil
        }
        let base = CloudProviderStore.shared.baseURL(for: provider)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var body: [String: Any] = [
            "model": "tts-1-hd",
            "input": text,
            "voice": voice,
            "response_format": "mp3",
            "speed": 1.0
        ]
        // Some custom/OpenAI-compatible servers need output_format instead.
        body["response_format"] = "mp3"

        var req = URLRequest(url: URL(string: base + "/audio/speech")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(CloudProviderStore.shared.apiKey(for: provider))",
                     forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                return nil
            }
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: outputURL)
            return data
        } catch {
            return nil
        }
    }
}
