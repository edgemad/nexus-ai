import Foundation

/// Talks to a local llama.cpp `llama-server` over its OpenAI-compatible API.
@MainActor
final class LLMService: ObservableObject {
    @Published private(set) var isStreaming = false
    @Published var lastError: String?

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:8080/v1")! }

    /// Upper bound for the streaming completion length; used both as the
    /// request's `max_tokens` and, exposed to callers, as the denominator for a
    /// determinate "generation percent" indicator.
    static let maxTokens = 2048

    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 4
        do {
            let (_, resp) = try await session.data(for: request)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Streamed completion. `onToken` is called on each delta; returns full text.
    /// Optional `images` are attached to the last user message as data URLs so
    /// vision-capable backends (e.g. llava) can see them.
    func streamChat(messages: [LLMMessage], images: [LLMImage] = [], temperature: Double = 0.7,
                    onToken: @escaping (String) -> Void) async -> String {
        isStreaming = true
        defer { isStreaming = false }

        let payload = self.payload(messages: messages, images: images)
        var body: [String: Any] = [
            "model": "local",
            "messages": payload,
            "temperature": temperature,
            "stream": true
        ]
        body["max_tokens"] = LLMService.maxTokens

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var full = ""
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            lastError = error.localizedDescription
            return full
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            lastError = "llama-server returned an error. Is the text model loaded?"
            return full
        }

        do {
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let first = choices.first else { continue }
                if let delta = first["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    full += content
                    onToken(content)
                } else if let finish = first["finish_reason"] as? String,
                          finish == "stop" {
                    break
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        return full
    }

    /// Non-streaming single-shot completion (used for web-search synthesis).
    func complete(messages: [LLMMessage]) async -> String {
        let body: [String: Any] = [
            "model": "local",
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": 0.3,
            "stream": false,
            "max_tokens": 1024
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await session.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return "" }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let content = msg["content"] as? String {
                return content
            }
        } catch {
            lastError = error.localizedDescription
        }
        return ""
    }

    /// Builds the OpenAI-compatible `messages` array. Any attached images are
    /// folded into the last user message as `[text, image_url…]` content parts.
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

struct LLMMessage {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// An attached image, sent to vision-capable backends as a base64 data URL.
struct LLMImage {
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.data = data
        self.mimeType = mimeType
    }
}
