import Foundation

/// Optional cloud integration with MiniMax H3 (Hailuo-03), an omni-modal
/// generation model that produces short video clips (4–15s) up to 2K with
/// native stereo audio — voice, sound effects and music all generated in the
/// same forward pass.
///
/// The project's own Movie Studio synthesizes everything on-device (Stable
/// Diffusion keyframes + Ken Burns + a procedural score). When a MiniMax API
/// key is configured, this service can instead drive the same "prompt → movie"
/// flow through H3: text-to-video returns a real, moving, sound-carrying clip.
///
/// H3 is a hosted, asynchronous API: you create a task, then poll for the
/// result URL, then download it. It is not a local model, so it requires an
/// optional API key — see Settings → MiniMax H3.
struct MiniMaxService {
    /// Where the user's API key is stored (Settings → MiniMax H3).
    static let apiKeyKey = "miniMaxH3ApiKey"

    /// Base URL for the MiniMax platform. The international domain is used by
    /// default; users in mainland China can point to api.minimax.cn instead.
    static var baseURL: URL { URL(string: "https://api.minimaxi.com")! }

    /// The model ID for H3, and its faster sibling.
    enum Model: String { case h3 = "MiniMax-H3", h3Max = "MiniMax-H3-Max" }

    /// The current API key, if the user has configured one. Stored in the
    /// macOS Keychain; legacy UserDefaults copies are migrated on first read.
    static var apiKey: String {
        get {
            if let stored = try? SecretStore.read(apiKeyKey), !stored.isEmpty { return stored }
            return SecretStore.migrateLegacyIfNeeded(apiKeyKey) ?? ""
        }
        set {
            if newValue.isEmpty {
                try? SecretStore.delete(apiKeyKey)
            } else {
                try? SecretStore.save(newValue, for: apiKeyKey)
            }
        }
    }

    static var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Public API

    /// Verifies the configured key is usable by hitting the models list
    /// endpoint (fast, cheap, no generation needed). Returns nil on success,
    /// or a human-readable error message.
    static func validateKey() async -> String? {
        guard isConfigured else { return "Enter a MiniMax API key first." }
        let url = baseURL.appendingPathComponent("v1/models")
        do {
            try await send(makeRequest(url: url, method: "GET"))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Generates a short H3 clip from a text prompt (native 2K + stereo audio).
    /// Blocks until H3 finishes, then returns the downloaded local file URL.
    ///
    /// - Parameters:
    ///   - prompt: the video description.
    ///   - duration: clip length in seconds (4–15).
    ///   - resolution: "2K" or "768P".
    ///   - ratio: "16:9", "9:16", "1:1", "4:3", "3:4", "21:9".
    ///   - progress: called repeatedly with a 0...1 fraction as the task polls.
    @MainActor
    static func generateVideo(prompt: String, duration: Int = 6, resolution: String = "768P",
                              ratio: String = "16:9", progress: @escaping (Double) -> Void) async throws -> URL {
        guard isConfigured else {
            throw MiniMaxError.notConfigured
        }
        let body: [String: Any] = [
            "model": Model.h3.rawValue,
            "content": [["type": "text", "text": prompt]],
            "resolution": resolution,
            "duration": duration,
            "ratio": ratio
        ]
        let createURL = baseURL.appendingPathComponent("v2/video_generation")
        var req = makeRequest(url: createURL, method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let taskID: String
        do {
            let obj = try await send(req)
            guard let id = obj["task_id"] as? String, !id.isEmpty else {
                throw MiniMaxError.badResponse
            }
            taskID = id
        }

        // Poll for the finished clip.
        let queryURL = baseURL
            .appendingPathComponent("v2/query/video_generation")
            .appendingPathComponent(taskID)
        progress(0.05)
        for attempt in 0...300 {
            if Task.isCancelled { throw MiniMaxError.cancelled }
            progress(0.05 + 0.8 * Double(attempt) / 300.0)

            var poll = makeRequest(url: queryURL, method: "GET")
            poll.timeoutInterval = 30
            let obj = try await send(poll)
            guard let task = obj["task"] as? [String: Any] else {
                throw MiniMaxError.badResponse
            }
            let status = task["status"] as? String ?? ""
            if status == "failed" {
                let msg = (task["error"] as? [String: Any])?["message"] as? String
                throw MiniMaxError.failed(msg ?? "H3 reported a failure")
            }
            let resultURL = (task["content"] as? [String: Any])?["url"] as? String

            if status == "succeeded", let resultURL {
                progress(0.9)
                guard let url = URL(string: resultURL) else { throw MiniMaxError.badResponse }
                var dl = URLRequest(url: url)
                dl.timeoutInterval = 120
                let (data, resp) = try await URLSession.shared.data(for: dl)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw MiniMaxError.http("Download failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1))")
                }
                // Save to the transient media cache (auto-cleaned), so the
                // generated movie is only available while the app runs.
                let outURL = TempMediaCache.shared.url(ext: "mp4")
                try data.write(to: outURL)
                progress(1.0)
                return outURL
            }

            try await Task.sleep(nanoseconds: 3_000_000_000) // 3s
        }
        throw MiniMaxError.timeout
    }

    // MARK: - TTS (natural multilingual speech)

    /// MiniMax Speech 2.8 HD — unlike OpenAI's American-accented voices, this
    /// natively supports Tagalog/Cebuano-style prosody and, with `language_boost`,
    /// produces natural, local-sounding Filipino without the foreign "twang".
    enum TTS {
        static let model = "speech-2.8-hd"

        /// A small set of system voices that handle multilingual (incl. Filipino).
        static let voiceChoices: [(id: String, label: String)] = [
            ("female-shaonv", "Female (Clear)"),
            ("male-qn-qingse", "Male (Deep)"),
            ("female-chengshu", "Female (Mature)"),
            ("male-chengshu", "Male (Mature)")
        ]

        /// Maps the app's language code to MiniMax's `language_boost` value.
        /// Filipino/Cebuano/Waray all use the Filipino boost for natural prosody.
        static func languageBoost(for code: String) -> String {
            switch code.lowercased() {
            case "fil", "ceb", "war": return "Filipino"
            case "es": return "Spanish"
            case "fr": return "French"
            case "de": return "German"
            case "it": return "Italian"
            case "pt": return "Portuguese"
            case "zh": return "Chinese"
            case "ja": return "Japanese"
            case "ko": return "Korean"
            case "hi": return "Hindi"
            case "ar": return "Arabic"
            case "ru": return "Russian"
            case "nl": return "Dutch"
            case "sv": return "Swedish"
            case "tr": return "Turkish"
            case "id": return "Indonesian"
            case "vi": return "Vietnamese"
            case "th": return "Thai"
            case "en", "": return "English"
            default: return "auto"
            }
        }

        /// Synthesizes `text` in the given language to MP3 audio Data (in-memory).
        static func speak(text: String, voice: String = "female-shaonv",
                          languageCode: String = "fil") async -> Data? {
            guard isConfigured else { return nil }
            var body: [String: Any] = [
                "model": model,
                "text": text,
                "voice_setting": [
                    "voice_id": voice,
                    "speed": 1.0,
                    "vol": 1.0,
                    "pitch": 0
                ],
                "audio_setting": [
                    "sample_rate": 32000,
                    "bitrate": 128000,
                    "format": "mp3",
                    "channel": 1
                ],
                "language_boost": languageBoost(for: languageCode)
            ]

            var req = makeRequest(url: baseURL.appendingPathComponent("v1/t2a_v2"), method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let obj = try? await send(req) else { return nil }

            if let audio = obj["audio"] as? String, let d = Data(base64Encoded: audio) {
                return d
            }
            if let audioFile = obj["audio_file"] as? String, let d = Data(base64Encoded: audioFile) {
                return d
            }
            if let dataObj = obj["data"] as? [String: Any] {
                if let audio = dataObj["audio"] as? String, let d = Data(base64Encoded: audio) {
                    return d
                }
                if let urlStr = dataObj["audio_url"] as? String, let url = URL(string: urlStr),
                   let (d, _) = try? await URLSession.shared.data(from: url) {
                    return d
                }
            }
            return nil
        }
    }

    // MARK: - Networking

    private static func makeRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MiniMaxError.http("Unexpected response (\(status))")
            }
            if status != 200 {
                var msg = "HTTP \(status)"
                if let err = obj["error"] as? [String: Any],
                   let m = err["message"] as? String,
                   let code = err["type"] as? String {
                    msg = "\(code): \(m)"
                } else if let rawErr = obj["base_resp"] as? [String: Any],
                          let sm = rawErr["status_msg"] as? String {
                    msg = sm
                }
                throw MiniMaxError.http(msg)
            }
            return obj
        } catch let error as MiniMaxError {
            throw error
        } catch {
            throw MiniMaxError.http(error.localizedDescription)
        }
    }
}

enum MiniMaxError: LocalizedError {
    case notConfigured
    case badResponse
    case timeout
    case cancelled
    case failed(String)
    case http(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No MiniMax API key set. Add it in Settings → MiniMax H3."
        case .badResponse:
            return "MiniMax returned an unexpected response."
        case .timeout:
            return "MiniMax H3 did not finish within the expected time."
        case .cancelled:
            return "Generation cancelled."
        case .failed(let msg):
            return "MiniMax H3 failed: \(msg)"
        case .http(let msg):
            return "MiniMax request error: \(msg)"
        }
    }
}
