import Foundation

/// Result of a brain intent call: how the current user message should be routed.
@MainActor
struct BrainIntentResult {
    var instantAnswer: String
    var needsResearch: Bool
    var reason: String
    var needsLocation: Bool
    var offlineReply: String
}

/// Thin Swift client for the local Python "nexie-brain" sidecar.  The routing
/// heuristics (instant date/time answers, research triggers, offline rule-based
/// replies) live in the Python service so the SwiftUI app stays thin.  When the
/// sidecar is offline every method degrades gracefully to empty/no, letting the
/// caller fall back to the built-in Swift versions.
///
/// The service is stdlib-only Python and runs at http://127.0.0.1:8767.
@MainActor
final class BrainServiceClient {
    static let shared = BrainServiceClient()

    let baseURL = URL(string: "http://127.0.0.1:8767")!

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["Authorization": "Bearer \(SidecarAuth.token)"]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 8
        return URLSession(configuration: cfg)
    }()

    /// True when the brain sidecar is up and responding on /health.
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

    /// Classify how to route the given user message.  Returns empty/no values
    /// when the sidecar is unavailable (cheap: connection-refused is instant).
    func intent(query: String, style: String = "standard") async -> BrainIntentResult {
        guard !query.isEmpty else { return BrainIntentResult(instantAnswer: "", needsResearch: false, reason: "", needsLocation: false, offlineReply: "") }
        var request = URLRequest(url: baseURL.appendingPathComponent("intent"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["query": query, "style": style]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, resp) = try await session.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return BrainIntentResult(instantAnswer: "", needsResearch: false, reason: "", needsLocation: false, offlineReply: "")
            }
            return BrainIntentResult(
                instantAnswer: obj["instant_answer"] as? String ?? "",
                needsResearch: obj["needs_research"] as? Bool ?? false,
                reason: obj["reason"] as? String ?? "",
                needsLocation: obj["needs_location"] as? Bool ?? false,
                offlineReply: obj["offline_reply"] as? String ?? ""
            )
        } catch {
            return BrainIntentResult(instantAnswer: "", needsResearch: false, reason: "", needsLocation: false, offlineReply: "")
        }
    }
}