import Foundation

/// The bundled local sidecars the app can negotiate with at runtime.
enum SidecarKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case research
    case memory
    case brain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .research: return "nexie-research"
        case .memory: return "nexie-memory"
        case .brain: return "nexie-brain"
        }
    }

    var port: Int {
        switch self {
        case .research: return 8765
        case .memory: return 8766
        case .brain: return 8767
        }
    }

    /// Minimum sidecar version the app will accept.
    var minVersion: String { "1.1.0" }

    /// Capability names the app requires each sidecar to advertise.
    var requiredCapabilities: Set<String> {
        switch self {
        case .research: return ["web_research", "deep_research"]
        case .memory: return ["context_build", "semantic_search"]
        case .brain: return ["intent_classification"]
        }
    }
}

/// Negotiates with the sidecars' `/version` + `/capabilities` endpoints so the
/// agent knows which features are genuinely available at runtime instead of
/// assuming they are.
@MainActor
final class SidecarNegotiator: ObservableObject {
    static let shared = SidecarNegotiator()

    struct Profile: Equatable, Identifiable, Sendable {
        let kind: SidecarKind
        var reachable = false
        var version: String?
        var capabilities: Set<String> = []
        var probedAt: Date?

        var id: String { kind.id }

        var negotiated: Bool {
            guard let version else { return false }
            return CapabilityRouter.complies(version: version,
                                             minimumVersion: kind.minVersion,
                                             capabilities: capabilities,
                                             required: kind.requiredCapabilities)
        }
    }

    @Published private(set) var profiles: [SidecarKind: Profile] = [:]
    @Published private(set) var lastProbe: Date?

    /// Freshness window: repeated probes within this are served from cache.
    static let probeTTL: TimeInterval = 20

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        for kind in SidecarKind.allCases {
            profiles[kind] = Profile(kind: kind)
        }
    }

    func profile(_ kind: SidecarKind) -> Profile {
        profiles[kind] ?? Profile(kind: kind)
    }

    func isReachable(_ kind: SidecarKind) -> Bool {
        profile(kind).reachable
    }

    func isNegotiated(_ kind: SidecarKind) -> Bool {
        profile(kind).negotiated
    }

    /// Probes every sidecar concurrently and publishes the fresh profiles.
    /// Skipped when a probe happened within `probeTTL` unless `force`. The
    /// card and the app call this on appearance without force; the
    /// "Re-negotiate" button forces a live round.
    func probeAll(force: Bool = false) async {
        if !force, let lastProbe, Date().timeIntervalSince(lastProbe) < Self.probeTTL {
            return
        }
        var next: [SidecarKind: Profile] = [:]
        let session = self.session
        await withTaskGroup(of: (SidecarKind, Profile).self) { group in
            for kind in SidecarKind.allCases {
                group.addTask {
                    let profile = await Self.probe(kind, using: session)
                    return (kind, profile)
                }
            }
            for await (kind, profile) in group {
                next[kind] = profile
            }
        }
        for kind in SidecarKind.allCases {
            if let profile = next[kind] {
                profiles[kind] = profile
            }
        }
        lastProbe = Date()
    }

    private nonisolated static func probe(_ kind: SidecarKind,
                                          using session: URLSession) async -> Profile {
        var profile = Profile(kind: kind)
        guard let url = URL(string: "http://127.0.0.1:\(kind.port)/version") else {
            return profile
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Bearer \(SidecarAuth.token)", forHTTPHeaderField: "Authorization")

        let version: String?
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return profile
            }
            version = json["version"] as? String
        } catch {
            return profile
        }
        guard let version else { return profile }
        profile.reachable = true
        profile.version = version

        guard let capsURL = URL(string: "http://127.0.0.1:\(kind.port)/capabilities") else {
            profile.probedAt = Date()
            return profile
        }
        var capsRequest = URLRequest(url: capsURL)
        capsRequest.timeoutInterval = 3
        capsRequest.setValue("Bearer \(SidecarAuth.token)", forHTTPHeaderField: "Authorization")
        if let (data, response) = try? await session.data(for: capsRequest),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = json["capabilities"] as? [String: Any] {
            profile.capabilities = Set(raw.filter { $0.value as? Bool == true }.keys)
        }
        profile.probedAt = Date()
        return profile
    }
}