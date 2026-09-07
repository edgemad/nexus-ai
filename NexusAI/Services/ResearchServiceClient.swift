import Foundation

/// Thin Swift client for the local Python "nexie-research" sidecar. The heavy
/// lifting (multi-engine web search, page fetch/extract, relevance ranking,
/// deep two-pass research, Perplexity-style structured synthesis and the local
/// LLM call) lives in the Python service; this lets the SwiftUI app stay thin.
///
/// The service is stdlib-only Python and runs at http://127.0.0.1:8765. When it
/// is not running (or a call fails), methods return nil and the caller falls
/// back to the built-in Swift research pipeline, so nothing breaks offline.
@MainActor
final class ResearchServiceClient {
    static let shared = ResearchServiceClient()

    let baseURL = URL(string: "http://127.0.0.1:8765")!
    /// The local llama-server the Python service uses for synthesis.
    let llmBase = "http://127.0.0.1:8080/v1"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["Authorization": "Bearer \(SidecarAuth.token)"]
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 240
        return URLSession(configuration: cfg)
    }()

    private let quickSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["Authorization": "Bearer \(SidecarAuth.token)"]
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    /// True when the research sidecar is up and responding on /health.
    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        do {
            let (_, resp) = try await session.data(for: request)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Runs web research (deep: two-pass) through the Python sidecar and
    /// returns the synthesized answer with its evidence (sources + confidence),
    /// or `nil` on failure/unavailability.
    func research(query: String, deep: Bool) async -> ResearchResult? {
        guard !query.isEmpty else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent(deep ? "deep" : "research"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["query": query, "llm_base": llmBase]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, resp) = try await session.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = obj["answer"] as? String, !answer.isEmpty else { return nil }
            let rawSources = obj["sources"] as? [[String: Any]] ?? []
            let sources = rawSources.compactMap { s -> ResearchSource? in
                guard let title = s["title"] as? String, let url = s["url"] as? String else { return nil }
                return ResearchSource(title: title, url: url, snippet: s["snippet"] as? String ?? "")
            }
            let confidence = obj["confidence"] as? Int
            let marinated = obj["marinated"] as? Bool ?? false
            return ResearchResult(answer: answer, sources: sources,
                                  confidence: confidence, marinated: marinated)
        } catch {
            return nil
        }
    }

    /// Approximate city-level location derived from the public IP, e.g.
    /// "Imus, Calabarzon, Philippines". Returns "" when offline.
    func geoip() async -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("geoip"))
        request.timeoutInterval = 12
        do {
            let (data, resp) = try await quickSession.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let place = obj["place"] as? String else { return "" }
            return place
        } catch {
            return ""
        }
    }
}
