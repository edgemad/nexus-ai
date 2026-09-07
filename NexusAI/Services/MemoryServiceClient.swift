import Foundation

/// Thin Swift client for the local Python "nexie-memory" sidecar.  The heavy
/// lifting (relevance scoring, context building, memory extraction/merge/trim)
/// lives in the Python service; this lets the SwiftUI KnowledgeStore stay as the
/// UI layer and fallback when the sidecar is offline.
///
/// The service is stdlib-only Python and runs at http://127.0.0.1:8766.
@MainActor
final class MemoryServiceClient {
    static let shared = MemoryServiceClient()

    let baseURL = URL(string: "http://127.0.0.1:8766")!

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["Authorization": "Bearer \(SidecarAuth.token)"]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    /// True when the memory sidecar is up and responding on /health.
    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        do {
            let (_, resp) = try await session.data(for: request)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Build a context block for prompt injection (port of contextForPrompt).
    /// Returns (context, matches) so the caller can use the context string
    /// and optionally inspect which items matched.
    func context(query: String) async -> (context: String, matches: [[String: Any]]) {
        guard !query.isEmpty else { return ("", []) }
        var request = URLRequest(url: baseURL.appendingPathComponent("context"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])

        do {
            let (data, resp) = try await session.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ctx = obj["context"] as? String else { return ("", []) }
            let matches = obj["matches"] as? [[String: Any]] ?? []
            return (ctx, matches)
        } catch {
            return ("", [])
        }
    }

    /// Learn durable memories from a chat exchange (port of learnFromConversation).
    /// Returns the number of new items added.
    @discardableResult
    func learn(userText: String, assistantText: String) async -> Int {
        guard !userText.isEmpty || !assistantText.isEmpty else { return 0 }
        var request = URLRequest(url: baseURL.appendingPathComponent("learn"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["user_text": userText, "assistant_text": assistantText]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, resp) = try await session.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
            return obj["count"] as? Int ?? 0
        } catch {
            return 0
        }
    }

    /// Fetch all items (for syncing KnowledgeStore state).
    func items() async -> [[String: Any]] {
        do {
            let (data, resp) = try await session.data(for: URLRequest(url: baseURL.appendingPathComponent("items")))
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return obj["items"] as? [[String: Any]] ?? []
        } catch {
            return []
        }
    }

    /// Add a knowledge/memory item.
    func add(item: [String: Any]) async -> [String: Any]? {
        var request = URLRequest(url: baseURL.appendingPathComponent("add"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["item": item])
        do {
            let (data, resp) = try await session.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["item"] as? [String: Any]
        } catch {
            return nil
        }
    }

    /// Delete an item by ID.
    func delete(id: UUID) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("delete"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id.uuidString])
        _ = try? await session.data(for: request)
    }

    /// Update an item.
    func update(item: [String: Any]) async -> [String: Any]? {
        var request = URLRequest(url: baseURL.appendingPathComponent("update"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["item": item])
        do {
            let (data, resp) = try await session.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["item"] as? [String: Any]
        } catch {
            return nil
        }
    }
}
