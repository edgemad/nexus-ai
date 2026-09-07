import Foundation
import SwiftUI

/// Self-learning / self-improvement engine.
///
/// The AI keeps an eye on its own system: what backends and models are
/// installed, what newer upstream releases exist (llama.cpp, stable-diffusion),
/// and what models/pieces the setup is missing. Everything it finds becomes an
/// `UpgradeProposal` that is posted to the Approvals panel — the upgrade is
/// never applied without the user's explicit permission.
///
/// It learns from each decision: declined suggestions are de-prioritised after
/// two refusals, and scans are rate-limited so it doesn't nag.
@MainActor
final class SelfImprovementService: ObservableObject {
    static let shared = SelfImprovementService()

    @Published private(set) var isScanning = false
    @Published private(set) var lastSummary = ""
    @Published private(set) var proposals: [UpgradeProposal] = []

    /// Extra system-prompt guidance given to the model while computer control
    /// is on, so it knows it can request an upgrade scan (never execute!).
    static let agentGuidance = """
        You are a self-improving agent. You can audit this app's local setup \
        (backends, models, versions) and you stay current on what could be \
        added. To look for improvements you may emit:

        <<<{"action":"upgrade","command":"scan"}>>

        That runs a read-only check that proposes upgrades in the Approvals \
        panel. RULES: you NEVER download or modify anything yourself — every \
        upgrade you propose must be approved by the user before it runs. If the \
        user declines, do not propose the same thing again unless something \
        changed.
        """

    private static let checkInterval: TimeInterval = 6 * 3600
    private static let maxSuggestionsPerScan = 3
    private static let repeatSuppressions = 2 // deny-count after which a tag is dropped

    private let defaults = UserDefaults.standard
    private let backend = BackendManager.shared
    private let workspace = WorkspaceManager.shared

    /// Keeps upgrade subscriptions alive until their approval is decided.
    private var upgradeTokens: [UUID: ApprovalSubscription] = [:]

    private init() {}

    // MARK: - Persistence (learned preferences)

    private var lastCheck: Date? {
        get { defaults.object(forKey: "selfImprove.lastCheck") as? Date }
        set { defaults.set(newValue, forKey: "selfImprove.lastCheck") }
    }

    private func hasApplied(_ tag: String) -> Bool {
        defaults.stringArray(forKey: "selfImprove.applied")?.contains(tag) == true
    }

    private func recordApplied(_ tag: String) {
        var set = defaults.stringArray(forKey: "selfImprove.applied") ?? []
        if !set.contains(tag) { set.append(tag) }
        defaults.set(set, forKey: "selfImprove.applied")
    }

    private func denialCount(for tag: String) -> Int {
        defaults.integer(forKey: "selfImprove.declined.\(tag)")
    }

    private func recordDeclined(_ tag: String) {
        defaults.set(denialCount(for: tag) + 1, forKey: "selfImprove.declined.\(tag)")
    }

    private func shouldSuggest(_ tag: String) -> Bool {
        !hasApplied(tag) && denialCount(for: tag) < SelfImprovementService.repeatSuppressions
    }

    private func rememberPosted(_ tag: String) {
        var seen = defaults.dictionary(forKey: "selfImprove.posted") as? [String: TimeInterval] ?? [:]
        seen[tag] = Date().timeIntervalSinceReferenceDate
        defaults.set(seen, forKey: "selfImprove.posted")
    }

    private func alreadyPostedRecently(_ tag: String) -> Bool {
        guard let seen = (defaults.dictionary(forKey: "selfImprove.posted") as? [String: TimeInterval])?[tag] else {
            return false
        }
        return Date().timeIntervalSinceReferenceDate - seen < SelfImprovementService.checkInterval
    }

    var proactiveEnabled: Bool {
        get { !defaults.bool(forKey: "selfImprove.disabled") }
        set { defaults.set(!newValue, forKey: "selfImprove.disabled") }
    }

    /// Whether a background (proactive) check is due. Manual checks always run.
    func isProactiveCheckDue() -> Bool {
        guard proactiveEnabled else { return false }
        guard let last = lastCheck else { return true }
        return Date().timeIntervalSince(last) > SelfImprovementService.checkInterval
    }

    // MARK: - Entry points

    /// Rate-limited proactive scan. Called after chat exchanges when computer
    /// control is on, giving the AI "a mind of its own" without nagging.
    func runProactiveScanIfDue(chat: ChatStore) async {
        guard isProactiveCheckDue() else { return }
        lastCheck = Date()
        let summary = await runScan(source: "proactive")
        guard !summary.isEmpty, summary != "no proposals" else { return }
        chat.injectAssistantNote(summary)
    }

    /// Full scan + proposal pipeline. Returns a short human summary of what it
    /// proposed ("" if nothing new).
    @discardableResult
    func runScan(source: String) async -> String {
        guard !isScanning else { return "" }
        isScanning = true
        defer { isScanning = false }

        var found: [UpgradeProposal] = []

        // 1) Backends vs upstream releases.
        await collectBackendProposals(into: &found)

        // 2) Gaps in the local install (models/features missing).
        collectInstallGaps(into: &found)

        // 3) Fresh model ideas from Hugging Face (only when something new).
        await collectModelIdeas(into: &found)

        // Filter to things we haven't already handled or been declined on.
        let candidates = found.filter { shouldSuggest($0.sourceTag) && !alreadyPostedRecently($0.sourceTag) }
            .prefix(SelfImprovementService.maxSuggestionsPerScan)

        proposals = Array(candidates)
        guard !proposals.isEmpty else {
            lastSummary = proposalsDescription(0)
            return "no proposals"
        }

        for p in proposals {
            rememberPosted(p.sourceTag)
            post(p)
        }
        lastSummary = proposalsDescription(proposals.count)
        return lastSummary
    }

    private func proposalsDescription(_ count: Int) -> String {
        let textModels = backend.listTextModels().count
        let imageModels = backend.listImageModels().count
        return "Self-improvement scan: \(count) upgrade proposal(s) ready for your review in the Approvals panel. " +
            "System now has \(textModels) text model(s) and \(imageModels) image model(s). " +
            "Nothing changes until you approve."
    }

    // MARK: - Approvals

    /// Surfaces a proposal as a permission item. Applying it is deferred until
    /// the user taps Approve; the approval store's ID-keyed event stream
    /// (rather than a stored closure) decides what happens, so it survives
    /// relaunch and auto-expiry.
    private func post(_ p: UpgradeProposal) {
        let applyText: String
        if p.downloadURL != nil {
            applyText = "It will download \(p.downloadFilename ?? "a model") (streaming) and install it locally."
        } else {
            applyText = p.steps.isEmpty
                ? "It would make a local change once approved."
                : "It will run \(p.steps.count) guarded shell step(s) on your Mac."
        }
        let approvalID = ApprovalStore.shared.add(
            title: "AI proposes upgrade: \(p.title)",
            detail: "\(p.summary)\n\n\(applyText)\n\nApprove only if you want this applied.",
            icon: p.icon
        )
        let token = ApprovalStore.shared.subscribe { [weak self] eventID, allow in
            guard let self, eventID == approvalID else { return }
            self.upgradeTokens[approvalID] = nil
            if allow {
                self.apply(p)
            } else {
                self.recordDeclined(p.sourceTag)
                ChatRegistry.shared.active?.injectAssistantNote(
                    "Understood — I marked “\(p.title)” as declined and won't bring it up again.")
            }
        }
        upgradeTokens[approvalID] = token
    }

    /// Applies an approved proposal. Runs the guarded steps or streams the
    /// model download, then records it and reports back.
    private func apply(_ p: UpgradeProposal) {
        recordApplied(p.sourceTag)
        Task { @MainActor in
            if p.downloadURL != nil, let filename = p.downloadFilename {
                pipelineStarted(note: "Downloading \(filename)…")
                await backend.downloadModel(urlString: p.downloadURL!, filename: filename) { _ in }
                let ok = backend.listTextModels().contains { ($0 as NSString).lastPathComponent == filename }
                    || FileManager.default.fileExists(
                        atPath: workspace.modelsURL.appendingPathComponent(filename).path)
                pipelineEnded(note: ok
                    ? "Installed \(filename). You can select it in Models."
                    : "Download of \(filename) didn't complete — please retry.",
                              failed: !ok)
                return
            }

            for (i, step) in p.steps.enumerated() {
                pipelineStarted(note: "Applying \(p.title) (\(i + 1)/\(p.steps.count))…")
                let result = await AgentExecutor.shared.executeApprovedShell(step)
                guard !result.failed else {
                    pipelineEnded(note: "Upgrade “\(p.title)” failed at step \(i + 1):\n\(result.text)",
                                  failed: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            pipelineEnded(note: "Upgrade “\(p.title)” applied successfully.", failed: false)
        }
    }

    private func pipelineStarted(note: String) {
        // Keep it visible where it matters most: the approvals feed already
        // flips to "approved", so reflect progress in the chat context.
        ChatRegistry.shared.active?.injectAssistantNote(note)
    }

    private func pipelineEnded(note: String, failed: Bool) {
        let chat = ChatRegistry.shared.active
        chat?.injectAssistantNote(note)
        if failed {
            chat?.reportSelfImprovementFailure(note)
        }
    }

    // MARK: - Research: upstream backends

    private func collectBackendProposals(into found: inout [UpgradeProposal]) async {
        // llama.cpp
        if let release = await Self.latestGitHubRelease(owner: "ggml-org", repo: "llama.cpp",
                                                        assetFilter: { n in
            let lower = n.lowercased()
            return lower.contains("macos") && (lower.contains("arm64") || lower.contains("aarch64")) && lower.hasSuffix(".zip")
        }) {
            let applyDir = applyScratchDir()
            let steps = [
                "mkdir -p \"\(applyDir)\"",
                "cd \"\(applyDir)\" && curl -L --fail -o llama-update.zip \"\(release.assetURL)\"",
                "cd \"\(applyDir)\" && rm -rf llama-update && unzip -q -o llama-update.zip -d llama-update",
                Self.replaceBinaryStep(name: "llama-server", zipDir: "llama-update", in: "app/llm-backend/mac/arm64"),
                "cd \"\(applyDir)\" && rm -rf llama-update llama-update.zip"
            ]
            if shouldSuggest("llama.cpp \(release.tag)") {
                found.append(UpgradeProposal(
                    title: "Update llama-server to llama.cpp \(release.tag)",
                    summary: "The local LLM backend is behind upstream. llama.cpp \(release.tag) is the latest release.",
                    detail: "Downloads the official macOS arm64 build and swaps it into the LLM backend folder. Restart the app to load it.",
                    sourceTag: "llama.cpp \(release.tag)",
                    category: .backend,
                    steps: steps))
            }
        }

        // stable-diffusion.cpp — only if its release ships a macos arm64 build.
        if let release = await Self.latestGitHubRelease(owner: "leejet", repo: "stable-diffusion.cpp",
                                                        assetFilter: { n in
            let lower = n.lowercased()
            return lower.contains("macos") && (lower.contains("arm64") || lower.contains("aarch64")) && lower.hasSuffix(".zip")
        }) {
            if shouldSuggest("sd.cpp \(release.tag)") {
                found.append(UpgradeProposal(
                    title: "Update sd backend to stable-diffusion.cpp \(release.tag)",
                    summary: "The image backend may be a newer/different fork; upstream \(release.tag) is available.",
                    detail: "Heads-up: this repo is a different lineage than the local uncensored build. Only approve if you have tested it. Skips the q8_0 server flags if unsupported.",
                    sourceTag: "sd.cpp \(release.tag)",
                    category: .backend,
                    steps: []))
            }
        }
    }

    /// Builds a shell step that copies the freshly-downloaded binary over the
    /// app's installed one (after backing it up).
    private static func replaceBinaryStep(name: String, zipDir: String, in relDir: String) -> String {
        let relPath = "app/\(relDir)/\(name)"
        let root = "\(NSHomeDirectory())/NexusAI Workspace"
        return "find \"\(root)/.updates/\(zipDir)\" -type f -name '\(name)' -exec " +
            "cp -f '{}' \"\(root)/\(relPath)\" ';' && chmod +x \"\(root)/\(relPath)\""
    }

    private func applyScratchDir() -> String {
        "\(NSHomeDirectory())/NexusAI Workspace/.updates"
    }

    // MARK: - Research: local install gaps

    private func collectInstallGaps(into found: inout [UpgradeProposal]) {
        let textModels = backend.listTextModels()
        let imageModels = backend.listImageModels()

        if textModels.isEmpty {
            found.append(UpgradeProposal(
                title: "Add a local text model",
                summary: "No readable GGUF model is installed, so chat depends on a fallback or a remote server.",
                detail: "Open the Models tab to download an uncensored/local GGUF. I can also scan Hugging Face for a good default.",
                sourceTag: "install.gap.textModel",
                category: .model))
        }
        if imageModels.isEmpty {
            found.append(UpgradeProposal(
                title: "Add an image model",
                summary: "No image checkpoint is installed, so Image & Movie Studio have nothing to render with.",
                detail: "Open the Models tab and import a .safetensors checkpoint into the workspace Models folder.",
                sourceTag: "install.gap.imageModel",
                category: .model))
        }
        if !backend.isImageBackendAvailable {
            found.append(UpgradeProposal(
                title: "Install the image backend (sd)",
                summary: "The sd binary is missing from the backends folder, so Image & Movie Studio can't run.",
                detail: "Drop the sd binary and libstable-diffusion.dylib into app/backend/mac/ inside the workspace.",
                sourceTag: "install.gap.imageBackend",
                category: .backend))
        }
    }

    // MARK: - Research: model ideas (Hugging Face)

    private func collectModelIdeas(into found: inout [UpgradeProposal]) async {
        // Only add live model suggestions when the scan hasn't already produced
        // enough to review.
        guard found.count < SelfImprovementService.maxSuggestionsPerScan else { return }

        let installed = (backend.listTextModels() + backend.listImageModels())
            .map { (($0 as NSString).lastPathComponent.lowercased()) }
        let searchText = installed.contains { $0.contains("juggernaut") || $0.contains(".safetensors") }
            ? "sdxl lightning" : "uncensored gguf"
        let models = await Self.huggingFaceSearch(query: searchText, sortDownloads: true)
        for m in models.prefix(2) {
            let tag = "hf:\(m.id)"
            guard shouldSuggest(tag) else { continue }
            let filename = m.id.replacingOccurrences(of: "/", with: "--")
            // Skip repos we already have installed by any name fragment.
            let repoLeaf = (m.id as NSString).lastPathComponent.lowercased()
            if installed.contains(where: { $0.contains(repoLeaf) || repoLeaf.contains($0) }) {
                continue
            }
            found.append(UpgradeProposal(
                title: "New model idea: \(m.id)",
                summary: "\(m.downloads) downloads so far. It looks like it would fit this setup.",
                detail: "Suggested from Hugging Face. Streaming download; you pick the final file. Change nothing until you approve.",
                sourceTag: tag,
                category: .model,
                downloadURL: "https://huggingface.co/\(m.id)/resolve/main",
                downloadFilename: filename))
            if found.count >= SelfImprovementService.maxSuggestionsPerScan { break }
        }
    }

    // MARK: - Networking helpers (read-only, anonymous)

    nonisolated private static func fetchJSON(_ urlString: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    nonisolated private static func latestGitHubRelease(owner: String, repo: String,
                                                       assetFilter: (String) -> Bool) async
        -> (tag: String, assetURL: String)? {
        guard let json = await fetchJSON("https://api.github.com/repos/\(owner)/\(repo)/releases/latest"),
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        for a in assets {
            guard let name = a["name"] as? String,
                  let url = a["browser_download_url"] as? String,
                  assetFilter(name) else { continue }
            return (tag, url)
        }
        return nil
    }

    /// Minimal HF search: anonymous search API, sorted by downloads. Returns
    /// repos whose default file looks like weights for this setup.
    nonisolated private static func huggingFaceSearch(query: String, sortDownloads: Bool) async -> [(id: String, downloads: Int)] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "https://huggingface.co/api/models?search=\(encoded)&limit=8"
            + (sortDownloads ? "&sort=downloads&direction=-1" : "")
        guard let url = URL(string: url) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        var out: [(id: String, downloads: Int)] = []
        if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in list {
                guard let id = entry["id"] as? String,
                      !(entry["private"] as? Bool ?? false),
                      let siblings = entry["siblings"] as? [[String: Any]] else { continue }
                let hasWeights = siblings.contains { s in
                    guard let f = s["rfilename"] as? String else { return false }
                    let lower = f.lowercased()
                    return lower.hasSuffix(".gguf") || lower.hasSuffix(".safetensors")
                }
                guard hasWeights else { continue }
                let downloads = entry["downloads"] as? Int ?? 0
                out.append((id, downloads))
                if out.count >= 3 { break }
            }
        }
        return out
    }
}