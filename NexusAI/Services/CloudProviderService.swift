import Foundation

/// Cloud LLM providers for the Chat assistant (OpenAI, Google Gemini, Anthropic
/// Claude, OpenRouter, and any OpenAI-compatible endpoint). Local (on-device)
/// models remain the default; a cloud provider is only used when the user
/// configures one. This mirrors how tools like Ollama let you plug in a key and
/// check the connection.
@MainActor
final class CloudProviderStore: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable, Codable {
        case local = "Local (on-device)"
        case openai = "OpenAI"
        case google = "Google Gemini"
        case anthropic = "Anthropic Claude"
        case openrouter = "OpenRouter"
        case custom = "Custom (OpenAI-compatible)"

        var id: String { rawValue }

        /// Whether the provider speaks the OpenAI chat/completions wire format.
        var isOpenAICompatible: Bool { self != .anthropic }

        var defaultBaseURL: String {
            switch self {
            case .openai:    return "https://api.openai.com/v1"
            case .google:    return "https://generativelanguage.googleapis.com/v1beta/openai"
            case .anthropic: return "https://api.anthropic.com"
            case .openrouter:return "https://openrouter.ai/api/v1"
            case .custom:    return ""
            case .local:     return ""
            }
        }

        var defaultModel: String {
            switch self {
            case .openai:    return "gpt-4o-mini"
            case .google:    return "gemini-2.0-flash"
            case .anthropic: return "claude-3-5-sonnet-latest"
            case .openrouter:return "openai/gpt-4o-mini"
            case .custom, .local: return ""
            }
        }

        /// Where to get a key (for a "Get a key" link); nil if not applicable.
        var keyLink: URL? {
            switch self {
            case .openai:    return URL(string: "https://platform.openai.com/api-keys")
            case .google:    return URL(string: "https://aistudio.google.com/app/apikey")
            case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
            case .openrouter:return URL(string: "https://openrouter.ai/keys")
            default:         return nil
            }
        }
    }

    @Published var active: Provider {
        didSet { UserDefaults.standard.set(active.rawValue, forKey: Keys.active) }
    }
    @Published var checking = false
    /// Last connection-check message for the currently active provider.
    @Published var status: String?

    // MARK: - Storage keys
    private enum Keys {
        static let active = "cloudProvider.active"
        static let keyPrefix = "cloudProvider.key."
        static let basePrefix = "cloudProvider.base."
        static let modelPrefix = "cloudProvider.model."
    }

    static let shared = CloudProviderStore()

    private init() {
        let raw = UserDefaults.standard.string(forKey: Keys.active) ?? Provider.local.rawValue
        self.active = Provider(rawValue: raw) ?? .local
    }

    // MARK: - Per-provider config

    func apiKey(for provider: Provider) -> String {
        let name = Keys.keyPrefix + provider.rawValue
        if let stored = try? SecretStore.read(name), !stored.isEmpty { return stored }
        return SecretStore.migrateLegacyIfNeeded(name) ?? ""
    }
    func setApiKey(_ key: String, for provider: Provider) {
        let name = Keys.keyPrefix + provider.rawValue
        if key.isEmpty {
            try? SecretStore.delete(name)
        } else {
            try? SecretStore.save(key, for: name)
        }
    }
    func baseURL(for provider: Provider) -> String {
        let saved = UserDefaults.standard.string(forKey: Keys.basePrefix + provider.rawValue) ?? ""
        return saved.isEmpty ? provider.defaultBaseURL : saved
    }
    func setBaseURL(_ url: String, for provider: Provider) {
        UserDefaults.standard.set(url.isEmpty ? nil : url, forKey: Keys.basePrefix + provider.rawValue)
    }
    func model(for provider: Provider) -> String {
        let saved = UserDefaults.standard.string(forKey: Keys.modelPrefix + provider.rawValue) ?? ""
        return saved.isEmpty ? provider.defaultModel : saved
    }
    func setModel(_ model: String, for provider: Provider) {
        UserDefaults.standard.set(model.isEmpty ? nil : model, forKey: Keys.modelPrefix + provider.rawValue)
    }

    /// True when the given provider has a key (and base URL for custom) so it
    /// can actually be used.
    func isConfigured(_ provider: Provider) -> Bool {
        guard provider != .local else { return true }
        guard !apiKey(for: provider).isEmpty else { return false }
        if provider == .custom { return !baseURL(for: provider).isEmpty }
        return true
    }

    /// The currently-selected provider when it is configured, else nil.
    var effectiveProvider: Provider? {
        active == .local ? nil : (isConfigured(active) ? active : nil)
    }

    // MARK: - Connection check

    /// Verifies the active provider's key by calling a cheap models/list or a
    /// tiny completion. Returns nil on success or a human-readable error.
    func checkConnection() async -> String? {
        guard let provider = effectiveProvider else {
            return "No API key configured for \(active.rawValue)."
        }
        checking = true
        defer { checking = false }
        do {
            if provider.isOpenAICompatible {
                var req = URLRequest(url: URL(string: baseURL(for: provider).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    + "/models")!)
                req.setValue("Bearer \(apiKey(for: provider))", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 15
                let (_, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    return "Connection failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)). Check the key."
                }
            } else {
                // Anthropic: probe with a one-token completion.
                let body: [String: Any] = ["model": model(for: provider), "max_tokens": 1, "messages": [["role": "user", "content": "hi"]]]
                var req = URLRequest(url: URL(string: baseURL(for: provider).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(apiKey(for: provider), forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                req.timeoutInterval = 15
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    return "Connection failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)). Check the key."
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Streaming

    /// Streams a chat completion from the active cloud provider. `onToken` is
    /// called per delta; returns the full text (empty on failure).
    func streamChat(messages: [LLMMessage], images: [LLMImage] = [],
                    onToken: @escaping (String) -> Void) async -> String {
        guard let provider = effectiveProvider else { return "" }
        if provider.isOpenAICompatible {
            return await streamOpenAICompatible(provider, messages: messages, images: images, onToken: onToken)
        } else {
            return await streamAnthropic(provider, messages: messages, images: images, onToken: onToken)
        }
    }

    private func streamOpenAICompatible(_ provider: Provider, messages: [LLMMessage],
                                        images: [LLMImage], onToken: @escaping (String) -> Void) async -> String {
        let base = baseURL(for: provider).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let payload = payload(messages: messages, images: images)
        var body: [String: Any] = [
            "model": model(for: provider),
            "messages": payload,
            "stream": true,
            "max_tokens": 2048
        ]
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey(for: provider))", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return ""
            }
            var full = ""
            for try await line in bytes.lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("data:") else { continue }
                let payloadStr = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payloadStr == "[DONE]" { break }
                guard let d = payloadStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let first = choices.first else { continue }
                if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String {
                    full += content
                    onToken(content)
                }
            }
            return full
        } catch {
            return ""
        }
    }

    private func streamAnthropic(_ provider: Provider, messages: [LLMMessage],
                                 images: [LLMImage], onToken: @escaping (String) -> Void) async -> String {
        let base = baseURL(for: provider).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Anthropic uses system separately — split it out.
        var system: String?
        var claudeMessages: [[String: Any]] = []
        for m in messages {
            if m.role == "system" {
                system = (system.map { "\($0)\n" } ?? "") + m.content
            } else {
                claudeMessages.append(["role": m.role, "content": m.content])
            }
        }
        var body: [String: Any] = [
            "model": model(for: provider),
            "max_tokens": 2048,
            "stream": true,
            "messages": claudeMessages
        ]
        if let system { body["system"] = system }

        var req = URLRequest(url: URL(string: base + "/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey(for: provider), forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return "" }
            var full = ""
            for try await line in bytes.lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("data:") else { continue }
                guard let d = String(t.dropFirst(5)).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      obj["type"] as? String == "content_block_delta",
                      let delta = obj["delta"] as? [String: Any],
                      let content = delta["text"] as? String else { continue }
                full += content
                onToken(content)
            }
            return full
        } catch {
            return ""
        }
    }

    /// Builds the OpenAI-compatible `messages` array, folding images into the
    /// last user message as `[text, image_url…]` parts like the local service.
    private func payload(messages: [LLMMessage], images: [LLMImage]) -> [[String: Any]] {
        let attachIndex: Int? = images.isEmpty ? nil : messages.lastIndex { $0.role == "user" }
        var out: [[String: Any]] = []
        for (i, m) in messages.enumerated() {
            if i == attachIndex {
                var parts: [[String: Any]] = [["type": "text", "text": m.content]]
                for img in images {
                    let b64 = img.data.base64EncodedString()
                    parts.append(["type": "image_url",
                                  "image_url": ["url": "data:\(img.mimeType);base64,\(b64)"]])
                }
                out.append(["role": m.role, "content": parts])
            } else {
                out.append(["role": m.role, "content": m.content])
            }
        }
        return out
    }
}
