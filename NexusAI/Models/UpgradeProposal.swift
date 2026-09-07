import Foundation

/// An upgrade the AI discovered on its own (newer backend, a model that would
/// fit the setup, or a missing piece of the local install). Proposals never
/// apply themselves — every one is surfaced for the user's explicit approval.
struct UpgradeProposal: Identifiable, Codable {
    let id: UUID
    let title: String
    let summary: String
    let detail: String
    /// Stable tag used for learning (e.g. "llama.cpp b5076", "hf:mradermacher/…").
    let sourceTag: String
    let category: Category
    let icon: String
    /// Shell steps to apply, each still passes the destructive-command guard.
    var steps: [String] = []
    /// Optional model download (streamed through BackendManager, never loaded
    /// into RAM).
    var downloadURL: String? = nil
    var downloadFilename: String? = nil
    var createdAt: Date

    enum Category: String, Codable, CaseIterable {
        case backend = "Backend"
        case model = "Model"
        case feature = "Feature"
        case tooling = "Tooling"

        var icon: String {
            switch self {
            case .backend: return "cpu"
            case .model: return "brain"
            case .feature: return "sparkles"
            case .tooling: return "wrench.and.screwdriver"
            }
        }
    }

    init(id: UUID = UUID(), title: String, summary: String, detail: String,
         sourceTag: String, category: Category, icon: String? = nil,
         steps: [String] = [], downloadURL: String? = nil,
         downloadFilename: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.summary = summary
        self.detail = detail
        self.sourceTag = sourceTag
        self.category = category
        self.icon = icon ?? category.icon
        self.steps = steps
        self.downloadURL = downloadURL
        self.downloadFilename = downloadFilename
        self.createdAt = createdAt
    }
}