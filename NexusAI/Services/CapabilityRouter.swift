import Foundation

/// A feature the agent can be asked to perform.
enum AppFeature: String, CaseIterable, Codable, Sendable, Identifiable {
    case chat
    case research
    case deepResearch
    case memory
    case brain
    case location
    case image
    case video
    case speech
    case vision
    case computerControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Personal chat"
        case .research: return "Web research"
        case .deepResearch: return "Deep research"
        case .memory: return "Long-term memory"
        case .brain: return "Intent brain"
        case .location: return "Location awareness"
        case .image: return "Image generation"
        case .video: return "Video generation"
        case .speech: return "Speech"
        case .vision: return "Vision / multimodal"
        case .computerControl: return "Computer control"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .research: return "magnifyingglass"
        case .deepResearch: return "scope"
        case .memory: return "brain.head.profile"
        case .brain: return "waveform.path"
        case .location: return "location.circle"
        case .image: return "photo.on.rectangle.angled"
        case .video: return "film"
        case .speech: return "waveform"
        case .vision: return "eye"
        case .computerControl: return "cursorarrow.click.2"
        }
    }

    /// UserDefaults key (e.g. `nexie.disable.chat`) that force-disables the
    /// feature regardless of what is reachable at runtime.
    static func disableKey(for feature: AppFeature) -> String {
        "nexie.disable.\(feature.rawValue)"
    }
}

/// A backend that can fulfil a feature.
enum CapabilityProvider: String, CaseIterable, Codable, Sendable {
    case local
    case cloud
    case sidecarResearch
    case sidecarMemory
    case sidecarBrain
    case builtIn
    case unavailable

    var label: String {
        switch self {
        case .local: return "Local model"
        case .cloud: return "Cloud provider"
        case .sidecarResearch: return "Research sidecar"
        case .sidecarMemory: return "Memory sidecar"
        case .sidecarBrain: return "Brain sidecar"
        case .builtIn: return "Built-in"
        case .unavailable: return "Unavailable"
        }
    }

    var icon: String {
        switch self {
        case .local: return "cpu"
        case .cloud: return "cloud"
        case .sidecarResearch: return "dot.radiowaves.left.and.right"
        case .sidecarMemory: return "internaldrive"
        case .sidecarBrain: return "brain"
        case .builtIn: return "gearshape"
        case .unavailable: return "xmark.octagon"
        }
    }
}

/// A scored routing option for a feature.
struct CapabilityCandidate: Equatable, Sendable {
    let provider: CapabilityProvider
    let score: Int
    let reason: String
}

/// Runtime facts collected live: connectivity, local model, cloud provider,
/// negotiated sidecars, and profile-flag overrides.
struct RuntimeCapabilities: Equatable, Sendable {
    var online = false
    var localModel = false
    var cloud = false
    var mediaReady = true
    var visionReady = false
    var speech = true
    var computerControl = true
    var researchSidecar = false
    var memorySidecar = false
    var brainSidecar = false
    var disabled: Set<AppFeature> = []

    /// Reads the `nexie.disable.*` profile flags from UserDefaults.
    static func loadFlags() -> Set<AppFeature> {
        Set(AppFeature.allCases.filter {
            UserDefaults.standard.bool(forKey: AppFeature.disableKey(for: $0))
        })
    }
}

/// Deterministic feature-flag scoring and capability routing.
///
/// Every `score` is a pure function of the runtime facts, so routing is
/// reproducible and testable. A feature with no candidate above
/// `minimumScore` routes to `.unavailable`.
enum CapabilityRouter {
    /// Below this a candidate is not trusted to deliver the feature.
    static let minimumScore = 40

    static func candidates(for feature: AppFeature) -> [CapabilityProvider] {
        switch feature {
        case .chat: return [.local, .cloud]
        case .research, .deepResearch: return [.sidecarResearch, .builtIn]
        case .memory: return [.sidecarMemory, .builtIn]
        case .brain: return [.sidecarBrain, .builtIn]
        case .location: return [.builtIn, .sidecarResearch]
        case .image: return [.local, .cloud]
        case .video: return [.builtIn]
        case .speech: return [.builtIn]
        case .vision: return [.local, .cloud]
        case .computerControl: return [.builtIn]
        }
    }

    static func score(_ provider: CapabilityProvider,
                      for feature: AppFeature,
                      in runtime: RuntimeCapabilities) -> CapabilityCandidate {
        if runtime.disabled.contains(feature) {
            return CapabilityCandidate(provider: provider, score: 0,
                                       reason: "Disabled by profile flag")
        }
        switch (feature, provider) {
        case (.chat, .local):
            return runtime.localModel
                ? .init(provider: .local, score: 80, reason: "Local model running — private, offline-capable")
                : .init(provider: .local, score: 0, reason: "Local model not running")
        case (.chat, .cloud):
            return runtime.cloud
                ? .init(provider: .cloud, score: 90, reason: "Cloud provider configured")
                : .init(provider: .cloud, score: 0, reason: "No cloud provider configured")
        case (.research, .sidecarResearch):
            if !runtime.online {
                return .init(provider: .sidecarResearch, score: 0, reason: "Offline — no web research")
            }
            return runtime.researchSidecar
                ? .init(provider: .sidecarResearch, score: 92, reason: "Research sidecar negotiated (web search + synthesis)")
                : .init(provider: .sidecarResearch, score: 0, reason: "Research sidecar not negotiated")
        case (.research, .builtIn):
            return runtime.online
                ? .init(provider: .builtIn, score: 58, reason: "Built-in web fallback")
                : .init(provider: .builtIn, score: 0, reason: "Offline")
        case (.deepResearch, .sidecarResearch):
            if !runtime.online {
                return .init(provider: .sidecarResearch, score: 0, reason: "Offline — no deep research")
            }
            return runtime.researchSidecar
                ? .init(provider: .sidecarResearch, score: 94, reason: "Deep research sidecar (multi-query synthesis)")
                : .init(provider: .sidecarResearch, score: 0, reason: "Research sidecar not negotiated")
        case (.deepResearch, .builtIn):
            return runtime.online
                ? .init(provider: .builtIn, score: 60, reason: "Multi-query built-in fallback")
                : .init(provider: .builtIn, score: 0, reason: "Offline")
        case (.memory, .sidecarMemory):
            return runtime.memorySidecar
                ? .init(provider: .sidecarMemory, score: 90, reason: "Memory sidecar negotiated (context build + semantic search)")
                : .init(provider: .sidecarMemory, score: 0, reason: "Memory sidecar not negotiated")
        case (.memory, .builtIn):
            return .init(provider: .builtIn, score: 55, reason: "KnowledgeStore long-term memory")
        case (.brain, .sidecarBrain):
            return runtime.brainSidecar
                ? .init(provider: .sidecarBrain, score: 85, reason: "Brain sidecar negotiated (intent classification)")
                : .init(provider: .sidecarBrain, score: 0, reason: "Brain sidecar not negotiated")
        case (.brain, .builtIn):
            return .init(provider: .builtIn, score: 45, reason: "Built-in heuristics")
        case (.location, .builtIn):
            return .init(provider: .builtIn, score: 80, reason: "Core Location + geoip")
        case (.location, .sidecarResearch):
            return runtime.researchSidecar
                ? .init(provider: .sidecarResearch, score: 70, reason: "Web geoip fallback")
                : .init(provider: .sidecarResearch, score: 0, reason: "Research sidecar not negotiated")
        case (.image, .local):
            return runtime.mediaReady
                ? .init(provider: .local, score: 85, reason: "Local diffusion backend")
                : .init(provider: .local, score: 0, reason: "Media pipeline unavailable")
        case (.image, .cloud):
            return runtime.cloud
                ? .init(provider: .cloud, score: 75, reason: "Cloud image provider")
                : .init(provider: .cloud, score: 0, reason: "No cloud provider configured")
        case (.video, .builtIn):
            return runtime.mediaReady
                ? .init(provider: .builtIn, score: 70, reason: "Built-in video pipeline")
                : .init(provider: .builtIn, score: 0, reason: "Media pipeline unavailable")
        case (.speech, .builtIn):
            return runtime.speech
                ? .init(provider: .builtIn, score: 78, reason: "Built-in TTS / STT")
                : .init(provider: .builtIn, score: 0, reason: "Speech disabled")
        case (.vision, .local):
            return runtime.visionReady
                ? .init(provider: .local, score: 80, reason: "Vision-capable local model")
                : .init(provider: .local, score: 0, reason: "No vision-capable local backend")
        case (.vision, .cloud):
            return runtime.cloud
                ? .init(provider: .cloud, score: 70, reason: "Cloud multimodal provider")
                : .init(provider: .cloud, score: 0, reason: "No cloud provider configured")
        case (.computerControl, .builtIn):
            return runtime.computerControl
                ? .init(provider: .builtIn, score: 72, reason: "Approval-gated agent actions")
                : .init(provider: .builtIn, score: 0, reason: "Computer control disabled")
        default:
            return .init(provider: provider, score: 0, reason: "No routing entry")
        }
    }

    /// Best candidate for a feature, or `.unavailable` if none clears the bar.
    static func route(_ feature: AppFeature,
                      in runtime: RuntimeCapabilities) -> CapabilityCandidate {
        let scored = candidates(for: feature)
            .map { score($0, for: feature, in: runtime) }
        let best = scored.max { $0.score < $1.score }
        guard let best, best.score >= minimumScore else {
            let reason = scored.allSatisfy { $0.score == 0 }
                ? (runtime.disabled.contains(feature) ? "Disabled by profile flag" : "No viable provider right now")
                : "Below trust threshold"
            return CapabilityCandidate(provider: .unavailable, score: 0, reason: reason)
        }
        return best
    }

    /// Routed decision for every feature, in `AppFeature` order.
    static func overview(in runtime: RuntimeCapabilities) -> [(feature: AppFeature, candidate: CapabilityCandidate)] {
        AppFeature.allCases.map { ($0, route($0, in: runtime)) }
    }

    static func isAvailable(_ feature: AppFeature,
                            in runtime: RuntimeCapabilities) -> Bool {
        route(feature, in: runtime).score >= minimumScore
    }

    // MARK: - Version / capability negotiation

    static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let av = versionComponents(a)
        let bv = versionComponents(b)
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    /// `satisfies(version: "1.2.0", operator: ">=", minimum: "1.1.0")` → true.
    /// Supported operators: `>=`, `>`, `<=`, `<`, `==`, `=`.
    static func satisfies(version: String, operator op: String, minimum: String) -> Bool {
        switch op {
        case ">=": return compare(version, minimum) != .orderedAscending
        case ">": return compare(version, minimum) == .orderedDescending
        case "<=": return compare(version, minimum) != .orderedDescending
        case "<": return compare(version, minimum) == .orderedAscending
        case "=", "==": return compare(version, minimum) == .orderedSame
        default: return false
        }
    }

    /// Negotiation check: advertised sidecar version satisfies the app's
    /// minimum requirement and every required capability is advertised.
    static func complies(version: String,
                         minimumVersion: String,
                         capabilities: Set<String>,
                         required: Set<String>) -> Bool {
        satisfies(version: version, operator: ">=", minimum: minimumVersion)
            && required.isSubset(of: capabilities)
    }
}