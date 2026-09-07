import Foundation

// Phase 10: capability routing. Pure-table scoring, thresholding, feature
// flags, and version/capability negotiation are deterministic and tested here.

var failures = 0

@main
struct CapabilityHarness {
    static func main() {
        var runtime = RuntimeCapabilities()
        runtime.online = true
        runtime.localModel = true
        runtime.cloud = true
        runtime.researchSidecar = true
        runtime.memorySidecar = true
        runtime.brainSidecar = true

        check(CapabilityRouter.score(.local, for: .chat, in: runtime).score == 80,
              "chat prefers local model at 80 when running")
        var offlineModel = runtime
        offlineModel.localModel = false
        check(CapabilityRouter.score(.local, for: .chat, in: offlineModel).score == 0,
              "chat local → 0 when model down")
        check(CapabilityRouter.score(.cloud, for: .chat, in: runtime).score == 90,
              "chat cloud at 90 when configured")

        check(CapabilityRouter.route(.research, in: runtime).provider == .sidecarResearch,
              "research routes to negotiated sidecar")
        check(CapabilityRouter.route(.research, in: runtime).score == 92,
              "research sidecar score 92")
        var offlineResearch = runtime
        offlineResearch.online = false
        check(CapabilityRouter.route(.research, in: offlineResearch).provider == .unavailable,
              "offline research has no viable route")
        var sidecarDown = runtime
        sidecarDown.researchSidecar = false
        check(CapabilityRouter.route(.research, in: sidecarDown).provider == .builtIn,
              "unnegotiated research falls back to built-in")
        check(CapabilityRouter.route(.research, in: sidecarDown).score == 58,
              "built-in research fallback 58")

        check(CapabilityRouter.route(.memory, in: runtime).provider == .sidecarMemory,
              "memory routes to negotiated sidecar")
        var memoryDown = runtime
        memoryDown.memorySidecar = false
        check(CapabilityRouter.route(.memory, in: memoryDown).provider == .builtIn,
              "memory falls back to KnowledgeStore")
        check(CapabilityRouter.route(.memory, in: memoryDown).score == 55,
              "memory built-in 55")

        check(CapabilityRouter.route(.brain, in: runtime).provider == .sidecarBrain,
              "brain routes to negotiated sidecar")
        check(CapabilityRouter.route(.location, in: runtime).provider == .builtIn,
              "location prefers built-in 80 over geoip fallback")
        check(CapabilityRouter.route(.location, in: runtime).score == 80,
              "location score 80")

        check(CapabilityRouter.route(.image, in: runtime).provider == .local,
              "image routes to local diffusion backend")
        check(CapabilityRouter.route(.image, in: runtime).score == 85,
              "image score 85")
        check(CapabilityRouter.route(.video, in: runtime).provider == .builtIn,
              "video routes to built-in pipeline")
        check(CapabilityRouter.route(.speech, in: runtime).provider == .builtIn,
              "speech routes to built-in TTS/STT")
        check(CapabilityRouter.route(.computerControl, in: runtime).provider == .builtIn,
              "computer control routes to built-in")

        var noVision = runtime
        noVision.visionReady = false
        check(CapabilityRouter.route(.vision, in: noVision).provider == .cloud,
              "vision uses cloud multimodal provider when local vision absent")
        var noVisionNoCloud = noVision
        noVisionNoCloud.cloud = false
        check(CapabilityRouter.route(.vision, in: noVisionNoCloud).provider == .unavailable,
              "vision unavailable without local vision or cloud")

        var flagged = runtime
        flagged.disabled = [.research, .speech, .image]
        check(CapabilityRouter.route(.research, in: flagged).score == 0
                && CapabilityRouter.route(.research, in: flagged).provider == .unavailable,
              "disabled research routes to unavailable")
        check(CapabilityRouter.route(.speech, in: flagged).score == 0,
              "disabled speech scores 0")
        check(CapabilityRouter.route(.image, in: flagged).score == 0,
              "disabled image scores 0")
        check(CapabilityRouter.isAvailable(.chat, in: flagged),
              "chat still available when research disabled")

        let overview = CapabilityRouter.overview(in: runtime)
        check(overview.count == AppFeature.allCases.count,
              "overview covers every feature")

        check(CapabilityRouter.compare("1.1.0", "1.1.0") == .orderedSame,
              "1.1.0 equals 1.1.0")
        check(CapabilityRouter.compare("1.1.0", "1.2.0") == .orderedAscending,
              "1.1.0 less than 1.2.0")
        check(CapabilityRouter.compare("1.10.0", "1.9.0") == .orderedDescending,
              "multi-digit component compares numerically (1.10 > 1.9)")
        check(CapabilityRouter.compare("1.0.9", "1.0.10") == .orderedAscending,
              "1.0.9 less than 1.0.10")
        check(CapabilityRouter.satisfies(version: "1.2.0", operator: ">=", minimum: "1.1.0"),
              "1.2.0 satisfies >=1.1.0")
        check(CapabilityRouter.satisfies(version: "1.1.0", operator: ">=", minimum: "1.1.0"),
              "1.1.0 satisfies >=1.1.0")
        check(!CapabilityRouter.satisfies(version: "1.0.9", operator: ">=", minimum: "1.1.0"),
              "1.0.9 fails >=1.1.0")
        check(CapabilityRouter.compare("1.3.0", "1.3.0") == .orderedSame
                && CapabilityRouter.compare("1.3.0", "1.3.1") == .orderedAscending,
              "even-odd tail versions compare correctly")

        let required = Set(["web_research", "deep_research"])
        check(CapabilityRouter.complies(version: "1.1.0",
                                        minimumVersion: "1.1.0",
                                        capabilities: Set(["web_research", "deep_research", "geoip"]),
                                        required: required),
              "negotiation passes with matching version + required caps")
        check(!CapabilityRouter.complies(version: "1.1.0",
                                         minimumVersion: "1.1.0",
                                         capabilities: Set(["web_research"]),
                                         required: required),
              "negotiation fails when a required capability is missing")
        check(!CapabilityRouter.complies(version: "1.0.9",
                                         minimumVersion: "1.1.0",
                                         capabilities: Set(["web_research", "deep_research"]),
                                         required: required),
              "negotiation fails on stale version")

        let unavailable = CapabilityCandidate(provider: .unavailable, score: 0, reason: "x")
        check(unavailable.score < CapabilityRouter.minimumScore,
              "unavailable candidate never clears minimum score")

        if failures == 0 {
            print("Capability: all checks passed")
        } else {
            print("Capability: \(failures) check(s) FAILED")
        }
        exit(failures == 0 ? 0 : 1)
    }
}

func check(_ cond: Bool, _ message: String) {
    if cond {
        print("PASS \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}