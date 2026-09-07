import SwiftUI

/// Live capability scorecard: which features have a viable route right now,
/// which provider serves each, and the negotiated sidecar state.
struct CapabilitiesCard: View {
    var online: Bool

    @ObservedObject private var negotiator = SidecarNegotiator.shared
    @ObservedObject private var backend: BackendManager
    @ObservedObject private var theme = ThemeManager.shared

    @AppStorage("nexie.disable.chat") private var chatOn = true
    @AppStorage("nexie.disable.research") private var researchOn = true
    @AppStorage("nexie.disable.deepResearch") private var deepResearchOn = true
    @AppStorage("nexie.disable.memory") private var memoryOn = true
    @AppStorage("nexie.disable.brain") private var brainOn = true
    @AppStorage("nexie.disable.location") private var locationOn = true
    @AppStorage("nexie.disable.image") private var imageOn = true
    @AppStorage("nexie.disable.video") private var videoOn = true
    @AppStorage("nexie.disable.speech") private var speechOn = true
    @AppStorage("nexie.disable.vision") private var visionOn = true
    @AppStorage("nexie.disable.computerControl") private var computerControlOn = true

    @AppStorage("nexie.cap.mediaReady") private var mediaReady = true
    @AppStorage("nexie.cap.visionReady") private var visionReady = false

    init(online: Bool) {
        self.online = online
        _backend = ObservedObject(wrappedValue: BackendManager.shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ForEach(AppFeature.allCases, id: \.self) { feature in
                featureRow(feature)
            }

            Divider()

            HStack(spacing: 18) {
                Toggle(isOn: $mediaReady) {
                    Text("Media pipeline")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Toggle(isOn: $visionReady) {
                    Text("Vision backend")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
            }
            .font(.caption)

            sidecarRow
        }
        .task {
            await negotiator.probeAll()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Capabilities & routing")
                        .font(.headline)
                    Text("\(routedCount) of \(AppFeature.allCases.count) routed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Scored from live facts: model, cloud, sidecars, network — with profile flags.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Re-negotiate") {
                Task { await negotiator.probeAll(force: true) }
            }
            .controlSize(.small)
        }
    }

    private var routedCount: Int {
        AppFeature.allCases.filter { CapabilityRouter.isAvailable($0, in: runtime) }.count
    }

    private var runtime: RuntimeCapabilities {
        RuntimeCapabilities(online: online,
                            localModel: backend.llmRunning,
                            cloud: CloudProviderStore.shared.effectiveProvider != nil,
                            mediaReady: mediaReady,
                            visionReady: visionReady,
                            speech: true,
                            computerControl: true,
                            researchSidecar: negotiator.isNegotiated(.research),
                            memorySidecar: negotiator.isNegotiated(.memory),
                            brainSidecar: negotiator.isNegotiated(.brain),
                            disabled: disabledFlags)
    }

    private var disabledFlags: Set<AppFeature> {
        var set: Set<AppFeature> = []
        if !chatOn { set.insert(.chat) }
        if !researchOn { set.insert(.research) }
        if !deepResearchOn { set.insert(.deepResearch) }
        if !memoryOn { set.insert(.memory) }
        if !brainOn { set.insert(.brain) }
        if !locationOn { set.insert(.location) }
        if !imageOn { set.insert(.image) }
        if !videoOn { set.insert(.video) }
        if !speechOn { set.insert(.speech) }
        if !visionOn { set.insert(.vision) }
        if !computerControlOn { set.insert(.computerControl) }
        return set
    }

    private func flagBinding(_ feature: AppFeature) -> Binding<Bool> {
        switch feature {
        case .chat: return $chatOn
        case .research: return $researchOn
        case .deepResearch: return $deepResearchOn
        case .memory: return $memoryOn
        case .brain: return $brainOn
        case .location: return $locationOn
        case .image: return $imageOn
        case .video: return $videoOn
        case .speech: return $speechOn
        case .vision: return $visionOn
        case .computerControl: return $computerControlOn
        }
    }

    private func featureRow(_ feature: AppFeature) -> some View {
        let decision = CapabilityRouter.route(feature, in: runtime)
        let available = decision.score >= CapabilityRouter.minimumScore
        return HStack(spacing: 12) {
            Image(systemName: feature.icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(available ? theme.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.subheadline.weight(.medium))
                Text("\(decision.provider.label) — \(decision.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            scoreChip(decision.score)
            Toggle("", isOn: flagBinding(feature))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func scoreChip(_ score: Int) -> some View {
        let color: Color = score >= 70 ? .green : (score >= CapabilityRouter.minimumScore ? .yellow : .gray)
        return Text("\(score)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var sidecarRow: some View {
        HStack(spacing: 8) {
            ForEach(SidecarKind.allCases) { kind in
                let profile = negotiator.profile(kind)
                Label {
                    Text("\(kind.displayName) v\(profile.version ?? "?")")
                        + Text(profile.negotiated ? " · negotiated" : " · not negotiated")
                } icon: {
                    Image(systemName: profile.negotiated ? "checkmark.circle.fill" : "circle.dotted")
                }
                .font(.caption)
                .foregroundStyle(profile.negotiated ? .green : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(profile.negotiated ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
                .clipShape(Capsule())
            }
        }
    }
}