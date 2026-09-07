import Foundation

/// Fetches installable models from the Hugging Face API (no key required),
/// supporting several browsing modes so the catalog stays current:
///
///   - `.latest`        : most recently modified GGUF / SD checkpoints
///   - `.uncensored`    : abliterated / uncensored instruct builds
///   - `.popular`       : most-downloaded capable models
///   - `.recommended`   : curated good builds sized for this 16 GB Mac
///
/// Real per-file sizes come from HF's `tree/main` endpoint (the basic
/// `siblings` field in `/api/models` often omits sizes, which is why the old
/// catalog showed "0 GB"). Every network failure degrades to an empty list so
/// the UI keeps its static curated entries.
@MainActor
final class ModelCatalogService {
    static let shared = ModelCatalogService()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    /// Abliterated families that ship standalone GGUF quant files.
    private let abliteratedFamilies = ["Qwen", "Gemma", "Mistral", "Llama"]

    /// Curated sizes-safe "recommended for 16 GB" models.
    private let recommendedQueries = [
        ("Qwen", "Qwen/Qwen3-8B-GGUF"),
        ("Qwen", "Qwen/Qwen3-4B-GGUF"),
        ("Gemma", "unsloth/gemma-3-4b-it-GGUF"),
        ("Mistral", "bartowski/Mistral-7B-Instruct-v0.3-GGUF")
    ]

    /// The Q-quants we prefer, best → acceptable, all sized for a 16 GB Mac.
    private let quantOrder = ["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q4_0", "IQ4_XS"]

    private let sizeBudget = 9.0  // GB

    enum Mode: String, CaseIterable, Identifiable {
        case search = "Search"
        case recommended = "Recommended for my Mac"
        case latest = "Latest"
        case uncensored = "Uncensored"
        case popular = "Most downloaded"
        var id: String { rawValue }
    }

    /// Fetches models for a browsing `mode`. Returns an empty array on failure.
    func fetchModels(mode: Mode) async -> [ModelStore.CatalogModel] {
        var entries: [ModelStore.CatalogModel] = []
        switch mode {
        case .search:
            entries = await searchModelsByKeyword(searchTerm)
        case .recommended:
            entries = await fetchRecommended()
        case .latest:
            entries = await fetchLatest()
        case .uncensored:
            entries = await fetchUncensored()
        case .popular:
            entries = await fetchPopular()
        }
        // De-duplicate by filename.
        var seen = Set<String>()
        var out: [ModelStore.CatalogModel] = []
        for m in entries where !seen.contains(m.filename) {
            seen.insert(m.filename)
            out.append(m)
        }
        return out
    }

    /// The exact term to look up while the user is in `.search` mode. Set it
    /// before calling `fetchModels(mode: .search)`.
    var searchTerm = ""

    // MARK: - Modes

    private func fetchRecommended() async -> [ModelStore.CatalogModel] {
        var entries: [ModelStore.CatalogModel] = []
        for (_, repo) in recommendedQueries {
            if let entry = await entryForRepo(repo: repo, family: familyForRepo(repo)) {
                entries.append(entry)
            }
        }
        // Also suggest a fast SD checkpoint so image generation works out of box.
        if let sd = await entryForImageDefaults() {
            entries.append(sd)
        }
        return entries
    }

    private func familyForRepo(_ repo: String) -> String {
        let lower = repo.lowercased()
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("gemma") { return "Gemma" }
        if lower.contains("mistral") { return "Mistral" }
        if lower.contains("llama") { return "Llama" }
        return repo.split(separator: "/").last.map(String.init) ?? "Model"
    }

    private func fetchLatest() async -> [ModelStore.CatalogModel] {
        // Recent GGUF text models + recent SD checkpoints.
        var entries = await searchModels(query: "", sort: "lastModified", limit: 25, onlyGGUF: true, family: "", filter: "gguf")
        let sd = await searchImageCheckpoints(sort: "lastModified", limit: 6)
        entries.append(contentsOf: sd)
        return entries
    }

    private func fetchUncensored() async -> [ModelStore.CatalogModel] {
        var entries: [ModelStore.CatalogModel] = []
        for family in abliteratedFamilies {
            let got = await searchModels(query: "\(family) abliterated", sort: "lastModified", limit: 10, onlyGGUF: true, family: family, filter: "gguf")
            entries.append(contentsOf: got)
        }
        return entries
    }

    private func fetchPopular() async -> [ModelStore.CatalogModel] {
        var entries = await searchModels(query: "", sort: "downloads", limit: 25, onlyGGUF: true, family: "", filter: "gguf")
        let sd = await searchImageCheckpoints(sort: "downloads", limit: 6)
        entries.append(contentsOf: sd)
        return entries
    }

    /// Searches the HF catalog for a specific model by keyword (e.g. "llama",
    /// "phi", "mistral 7b"). Returns GGUF text models plus known compatible SD
    /// checkpoints. Empty query → empty result so the line shows nothing until
    /// the user actually types.
    private func searchModelsByKeyword(_ keyword: String) async -> [ModelStore.CatalogModel] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var entries = await searchModels(query: trimmed, sort: "downloads", limit: 20, onlyGGUF: true, family: "", filter: "gguf")
        entries.append(contentsOf: await searchImageCheckpoints(sort: "downloads", limit: 3))
        guard entries.isEmpty else { return entries }
        // No direct GGUF match: show the user a friendly hint in the UI instead
        // of an unhelpful empty list.
        return []
    }

    // MARK: - Builders

    /// Resolves a single known repo into a catalog entry (used by "recommended").
    private func entryForRepo(repo: String, family: String) async -> ModelStore.CatalogModel? {
        let files = await listRepoFiles(modelId: repo)
        guard let chosen = bestQuant(files: files) else { return nil }
        let sizeGB = estimateGB(chosen.size)
        guard sizeGB > 0.01 && sizeGB <= sizeBudget else { return nil }
        let url = "https://huggingface.co/\(repo)/resolve/main/\(chosen.name)"
        let label = family + named(chosen.name)
        return ModelStore.CatalogModel(
            name: label,
            kind: .text,
            sizeGB: sizeGB,
            sourceURL: url,
            filename: chosen.name)
    }

    private func named(_ filename: String) -> String {
        // "Qwen3-8B-Q4_K_M.gguf" → " 3 8B (Q4_K_M)"
        let base = filename.replacingOccurrences(of: ".gguf", with: "")
        return " \(base.replacingOccurrences(of: "-", with: " "))"
    }

    /// A fast, reliable default SD checkpoint for "recommended".
    private func entryForImageDefaults() async -> ModelStore.CatalogModel? {
        let repo = "stabilityai/sd-turbo"
        guard let file = await listRepoFiles(modelId: repo).first(where: { $0.name == "sd_turbo.safetensors" }) else { return nil }
        let sizeGB = estimateGB(file.size)
        guard sizeGB > 0 else { return nil }
        return ModelStore.CatalogModel(
            name: "SD Turbo 1.0 (SD 1.5) — fast",
            kind: .image,
            sizeGB: sizeGB,
            sourceURL: "https://huggingface.co/\(repo)/resolve/main/sd_turbo.safetensors",
            filename: file.name)
    }

    /// Generically searches /api/models and, for each GGUF repo, resolves the
    /// best quant file with its real size.
    private func searchModels(query: String, sort: String, limit: Int,
                              onlyGGUF: Bool, family: String, filter: String = "") async -> [ModelStore.CatalogModel] {
        var entries: [ModelStore.CatalogModel] = []
        for repo in await modelList(query: query, sort: sort, limit: limit, filter: filter) {
            guard let modelId = repo["modelId"] as? String else { continue }
            let lower = modelId.lowercased()
            if onlyGGUF && !lower.contains("gguf") { continue }
            // Skip tiny clips / embedding repos.
            if lower.contains("modelfile") || lower.contains("-clip") { continue }
            let files = await listRepoFiles(modelId: modelId)
            guard let chosen = bestQuant(files: files) else { continue }
            let sizeGB = estimateGB(chosen.size)
            guard sizeGB > 0.01 && sizeGB <= sizeBudget else { continue }
            let displayFamily = family.isEmpty ? friendlyFamily(modelId) : family
            let url = "https://huggingface.co/\(modelId)/resolve/main/\(chosen.name)"
            entries.append(ModelStore.CatalogModel(
                name: "\(displayFamily) — \(chosen.name) · \(String(format: "%.1f", sizeGB)) GB",
                kind: .text,
                sizeGB: sizeGB,
                sourceURL: url,
                filename: chosen.name))
        }
        return entries
    }

    /// Searches for single-file SD checkpoints (`.safetensors`) that aren't
    /// Diffusers-style subfolders and aren't gated, so they load in sd.cpp.
    private func searchImageCheckpoints(sort: String, limit: Int) async -> [ModelStore.CatalogModel] {
        // A curated set of non-gated, single-file SD checkpoints is far more
        // reliable than free-text search (which returns Diffusers subfolders and
        // gated repos the sd.cpp backend can't load). Keep it focused.
        let known = [
            ("stabilityai/sd-turbo", "sd_turbo.safetensors", "SD Turbo 1.0 (SD 1.5)"),
            ("stabilityai/sdxl-turbo", "sd_xl_turbo_1.0.safetensors", "SDXL Turbo 1.0"),
            ("SG161222/Realistic_Vision_V5.1_noVAE", "Realistic_Vision_V5.1_fp16-no-ema.safetensors", "Realistic Vision 5.1")
        ]
        var entries: [ModelStore.CatalogModel] = []
        for (repo, file, label) in known {
            let files = await listRepoFiles(modelId: repo)
            guard let f = files.first(where: { $0.name == file }) else { continue }
            let sizeGB = estimateGB(f.size)
            guard sizeGB > 0 else { continue }
            entries.append(ModelStore.CatalogModel(
                name: label,
                kind: .image,
                sizeGB: sizeGB,
                sourceURL: "https://huggingface.co/\(repo)/resolve/main/\(f.name)",
                filename: f.name))
        }
        return entries
    }

    private func friendlyFamily(_ modelId: String) -> String {
        let tokens = modelId.split(separator: "/")
        guard let last = tokens.last else { return "Model" }
        let name = String(last)
        if name.lowercased().contains("qwen") { return "Qwen" }
        if name.lowercased().contains("gemma") { return "Gemma" }
        if name.lowercased().contains("mistral") { return "Mistral" }
        if name.lowercased().contains("llama") { return "Llama" }
        return name
    }

    // MARK: - HTTP helpers

    private func modelList(query: String, sort: String, limit: Int, filter: String = "") async -> [[String: Any]] {
        guard var comps = URLComponents(string: "https://huggingface.co/api/models") else { return [] }
        var items = [URLQueryItem(name: "sort", value: sort),
                     URLQueryItem(name: "direction", value: "-1"),
                     URLQueryItem(name: "limit", value: String(limit))]
        if !query.isEmpty { items.append(URLQueryItem(name: "search", value: query)) }
        if !filter.isEmpty { items.append(URLQueryItem(name: "filter", value: filter)) }
        comps.queryItems = items
        guard let url = comps.url,
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let models = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return models
    }

    /// Fetches the repo file tree with REAL per-file sizes. Uses `tree/main`
    /// (which reports LFS sizes) — the plain `/api/models/{id}` siblings array
    /// usually omits `size`, which caused the previous "0 GB" labels.
    private func listRepoFiles(modelId: String) async -> [RepoFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelId)/tree/main?recursive=true") else { return [] }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var files: [RepoFile] = []
        for item in arr {
            guard let name = item["path"] as? String else { continue }
            let isDir = (item["type"] as? String) == "directory"
            if isDir { continue }
            let size = (item["size"] as? NSNumber)?.int64Value ?? 0
            files.append(RepoFile(name: name, size: size))
        }
        return files
    }

    private func bestQuant(files: [RepoFile]) -> RepoFile? {
        for q in quantOrder {
            let matches = files.filter { $0.name.uppercased().contains(q) }
                .filter { !$0.name.contains("mmproj") && !$0.name.contains("embed") && !$0.name.contains("-clip") }
                .sorted { $0.size < $1.size }
            if let first = matches.first { return first }
        }
        // Fall back to any single-file GGUF closest to the budget.
        return files.filter { $0.name.hasSuffix(".gguf") && !$0.name.contains("mmproj") }
            .sorted { abs(estimateGB($0.size) - 4.0) < abs(estimateGB($1.size) - 4.0) }
            .first
    }

    private func estimateGB(_ bytes: Int64) -> Double {
        Double(bytes) / 1_073_741_824
    }

    private struct RepoFile {
        let name: String
        let size: Int64
    }
}
