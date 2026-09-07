import Foundation
import SwiftUI

/// Catalog of available/installable models and the currently-selected model.
@MainActor
final class ModelStore: ObservableObject {
    struct CatalogModel: Identifiable {
        let id = UUID()
        let name: String
        let kind: ModelKind
        let sizeGB: Double
        let sourceURL: String
        let filename: String
    }

    enum ModelKind: String, CaseIterable, Identifiable {
        case text = "Text (GGUF)"
        case image = "Image (SD)"
        var id: String { rawValue }
    }

    /// A single in-flight (or finished) model download with live progress.
    struct DownloadTask: Identifiable, Equatable {
        let id = UUID()
        let modelName: String
        let filename: String
        var progress: Double
        var isComplete: Bool
        var failed: Bool

        var percent: Int { Int((progress * 100).rounded()) }
    }

    @Published var selectedTextModelPath: String?
    @Published var selectedImageModelPath: String?
    @Published private(set) var installedTextModels: [String] = []
    @Published private(set) var installedImageModels: [String] = []
    @Published private(set) var downloads: [DownloadTask] = []
    @Published var lastError: String?
    @Published private(set) var catalog: [CatalogModel]
    @Published private(set) var isRefreshingCatalog = false
    /// Which browsing mode the "Available to download" catalog is showing.
    @Published var catalogMode: ModelCatalogService.Mode = .recommended
    /// Live text input for the catalog's "Search a specific model" line. When
    /// `catalogMode` is `.search`, typing refreshes the list for the exact term.
    @Published var catalogSearchText = "" { didSet { handleSearchTextChange() } }

    /// True only while at least one download is actively in progress.
    /// (Completed/failed tasks linger in `downloads` until dismissed, so they
    /// must NOT count here — otherwise every row's actions get disabled after
    /// the first completed download.)
    var downloading: Bool { downloads.contains { !$0.isComplete } }
    var downloadProgress: Double {
        guard !downloads.isEmpty else { return 0 }
        return downloads.map(\.progress).reduce(0, +) / Double(downloads.count)
    }

    private let backend: BackendManager

    init(backend: BackendManager) {
        self.backend = backend
        // Curated catalog — current-gen (2025/26) single-file GGUF models,
        // verified to download from open repos, sized for a 16 GB Apple Silicon
        // Mac. The 4B models sip RAM and feel instant; 8B is the balanced
        // quality pick. Image checkpoints are added by file import.
        catalog = [
            CatalogModel(name: "Qwen 3 4B (Q4_K_M) — Fast & light", kind: .text, sizeGB: 2.5,
                         sourceURL: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
                         filename: "Qwen3-4B-Q4_K_M.gguf"),
            CatalogModel(name: "Qwen 3 8B (Q4_K_M) — Balanced", kind: .text, sizeGB: 5.0,
                         sourceURL: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
                         filename: "Qwen3-8B-Q4_K_M.gguf"),
            CatalogModel(name: "Gemma 3 4B (Q4_K_M) — Fast & light", kind: .text, sizeGB: 3.2,
                         sourceURL: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
                         filename: "gemma-3-4b-it-Q4_K_M.gguf"),
            CatalogModel(name: "Qwen 2.5 7B (Q3_K_M) — Budget 7B", kind: .text, sizeGB: 3.5,
                         sourceURL: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q3_k_m.gguf",
                         filename: "qwen2.5-7b-instruct-q3_k_m.gguf"),
            CatalogModel(name: "SD Turbo 1.0 (SD 1.5) — 0.66 GB · fast", kind: .image, sizeGB: 0.66,
                         sourceURL: "https://huggingface.co/stabilityai/sd-turbo/resolve/main/sd_turbo.safetensors",
                         filename: "sd_turbo.safetensors"),
            CatalogModel(name: "SDXL Turbo 1.0 — 6.5 GB · best quality", kind: .image, sizeGB: 6.5,
                         sourceURL: "https://huggingface.co/stabilityai/sdxl-turbo/resolve/main/sd_xl_turbo_1.0.safetensors",
                         filename: "sd_xl_turbo_1.0.safetensors"),
            CatalogModel(name: "Realistic Vision 5.1 (SD 1.5) — 2.0 GB", kind: .image, sizeGB: 2.0,
                         sourceURL: "https://huggingface.co/SG161222/Realistic_Vision_V5.1_noVAE/resolve/main/Realistic_Vision_V5.1_fp16-no-ema.safetensors",
                         filename: "Realistic_Vision_V5.1_fp16-no-ema.safetensors")
        ]
        refreshInstalled()

        // Auto-select the first installed text & image models so Chat and
        // Image Studio are ready immediately without manual selection.
        if selectedTextModelPath == nil, let first = installedTextModels.first {
            selectedTextModelPath = first
            UserDefaults.standard.set(first, forKey: "selectedTextModelPath")
        }
        // Restore a previously persisted image-model selection if it still exists.
        if let saved = UserDefaults.standard.string(forKey: "selectedImageModelPath"),
           FileManager.default.fileExists(atPath: saved),
           installedImageModels.contains(saved) {
            selectedImageModelPath = saved
        } else if selectedImageModelPath == nil, let first = installedImageModels.first {
            selectedImageModelPath = first
            UserDefaults.standard.set(first, forKey: "selectedImageModelPath")
        }

        // Freshen the catalog with the latest uncensored HF models on launch.
        refreshCatalogFromNetwork()
    }

    var selectedModelName: String? {
        selectedTextModelPath.map { ($0 as NSString).lastPathComponent }
    }

    func refreshInstalled() {
        installedTextModels = backend.listTextModels()
        installedImageModels = backend.listImageModels()
    }

    /// Queries Hugging Face for models in the currently-selected catalog
    /// `mode` and replaces the "Available to download" list. Preserves the
    /// static curated entries below the fresh ones.
    func refreshCatalogFromNetwork() {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        let mode = catalogMode
        if mode == .search {
            ModelCatalogService.shared.searchTerm = catalogSearchText
        }
        Task {
            let fresh = await ModelCatalogService.shared.fetchModels(mode: mode)
            // Keep the static curated entries, then prepend the fresh ones.
            if !fresh.isEmpty {
                self.catalog = fresh + self.catalog.filter { $0.kind == .image }
            }
            self.isRefreshingCatalog = false
        }
    }

    /// Switches the catalog browsing mode and immediately refreshes the list.
    func setCatalogMode(_ mode: ModelCatalogService.Mode) {
        guard mode != catalogMode else { return }
        catalogMode = mode
        if mode != .search {
            // Leaving search: clear it so the catalog returns to normal.
            catalogSearchText = ""
        }
        refreshCatalogFromNetwork()
    }

    /// Live search-as-you-type for the catalog's search line.
    private func handleSearchTextChange() {
        guard catalogMode == .search else { return }
        // Debounce lightly so we don't fire a HF request per keystroke.
        searchTask?.cancel()
        let term = catalogSearchText
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.catalogSearchText == term else { return }
            self.isRefreshingCatalog = true
            ModelCatalogService.shared.searchTerm = term
            let fresh = await ModelCatalogService.shared.fetchModels(mode: .search)
            if !fresh.isEmpty {
                self.catalog = fresh
            } else if !term.trimmingCharacters(in: .whitespaces).isEmpty {
                // Keep the list clear but avoid wiping the static curated rows
                // the user might still want to see.
                self.catalog = Array(self.catalog.filter { $0.kind == .image })
            }
            self.isRefreshingCatalog = false
        }
        searchTask = task
    }
    private var searchTask: Task<Void, Never>?

    /// Convenience for the Models view's manual "Check for updates" button.
    func checkForLatestModels() {
        refreshCatalogFromNetwork()
    }

    func selectTextModel(_ path: String) {
        selectedTextModelPath = path
        UserDefaults.standard.set(path, forKey: "selectedTextModelPath")
        backend.startOrEnsureLLM(modelPath: path)
    }

    func selectImageModel(_ path: String) {
        selectedImageModelPath = path
        UserDefaults.standard.set(path, forKey: "selectedImageModelPath")
    }

    func download(_ model: CatalogModel) {
        guard !model.sourceURL.isEmpty else {
            lastError = "This model has no download source. Try another entry."
            return
        }
        // Skip if this exact file is already downloading in parallel.
        guard !downloads.contains(where: { $0.filename == model.filename && !$0.isComplete }) else { return }
        startDownload(model: model)
    }

    private func startDownload(model: CatalogModel) {
        var task = DownloadTask(modelName: model.name, filename: model.filename,
                                progress: 0, isComplete: false, failed: false)
        // If this exact file is already installed, mark it complete immediately.
        let alreadyInstalled = installedTextModels.contains { ($0 as NSString).lastPathComponent == model.filename }
            || installedImageModels.contains { ($0 as NSString).lastPathComponent == model.filename }
        downloads.append(task)

        if alreadyInstalled {
            downloads[downloads.count - 1].isComplete = true
            downloads[downloads.count - 1].progress = 1
            return
        }

        Task {
            if model.kind == .text {
                await backend.downloadModel(urlString: model.sourceURL, filename: model.filename) { fraction in
                    if let idx = self.downloads.firstIndex(where: { $0.id == task.id }) {
                        self.downloads[idx].progress = fraction
                    }
                }
            } else {
                await backend.downloadImageModel(urlString: model.sourceURL, filename: model.filename) { fraction in
                    if let idx = self.downloads.firstIndex(where: { $0.id == task.id }) {
                        self.downloads[idx].progress = fraction
                    }
                }
            }
            let installed = (model.kind == .text
                ? self.backend.listTextModels()
                : self.backend.listImageModels())
                .contains { ($0 as NSString).lastPathComponent == model.filename }
            if let idx = self.downloads.firstIndex(where: { $0.id == task.id }) {
                self.downloads[idx].isComplete = true
                self.downloads[idx].failed = !installed
                self.downloads[idx].progress = installed ? 1 : 0
                if !installed {
                    self.lastError = "Download of \(model.filename) failed. Check the connection and try again."
                } else if model.kind == .image, self.selectedImageModelPath == nil {
                    // Newly installed first image model → auto-select it.
                    self.selectedImageModelPath = installedFile(for: model)
                    UserDefaults.standard.set(self.selectedImageModelPath, forKey: "selectedImageModelPath")
                }
            }
            self.refreshInstalled()
        }
    }

    private func installedFile(for model: CatalogModel) -> String? {
        let list = model.kind == .text ? backend.listTextModels() : backend.listImageModels()
        return list.first { ($0 as NSString).lastPathComponent == model.filename }
    }

    /// Removes a finished download entry from the panel.
    func dismissDownload(_ id: UUID) {
        downloads.removeAll { $0.id == id }
    }

    func addImageModelFromFile() {
        if let path = backend.importImageModel() {
            selectedImageModelPath = path
        }
        refreshInstalled()
    }

    // MARK: - Deletion

    /// Deletes the given installed text model. If it was the active selection,
    /// the selection falls back to the next remaining model (or nil).
    func deleteTextModel(_ path: String) {
        if backend.deleteModel(at: path) {
            installedTextModels.removeAll { $0 == path }
            if selectedTextModelPath == path {
                selectedTextModelPath = installedTextModels.first
                if let sel = selectedTextModelPath {
                    UserDefaults.standard.set(sel, forKey: "selectedTextModelPath")
                } else {
                    UserDefaults.standard.removeObject(forKey: "selectedTextModelPath")
                }
            }
        }
    }

    /// Deletes the given installed image model. If it was the active selection,
    /// the selection falls back to the next remaining model (or nil).
    func deleteImageModel(_ path: String) {
        if backend.deleteModel(at: path) {
            installedImageModels.removeAll { $0 == path }
            if selectedImageModelPath == path {
                selectedImageModelPath = installedImageModels.first
                if let sel = selectedImageModelPath {
                    UserDefaults.standard.set(sel, forKey: "selectedImageModelPath")
                } else {
                    UserDefaults.standard.removeObject(forKey: "selectedImageModelPath")
                }
            }
        }
    }

    // MARK: - Sizing

    /// The on-disk size (GB) of an installed model, or nil if it can't be read.
    /// Used to show accurate sizes for installed models instead of "0 GB".
    func installedSizeGB(_ path: String) -> Double? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let bytes = (attrs?[.size] as? NSNumber)?.int64Value, bytes > 0 else { return nil }
        return Double(bytes) / 1_073_741_824
    }

    /// A display-friendly size label for a catalog entry. Falls back to a
    /// "size unknown" marker when no real size is known rather than a 0 GB.
    func sizeLabel(for model: CatalogModel) -> String {
        if model.sizeGB > 0.01 {
            if model.sizeGB >= 1.0 {
                return String(format: "%.1f GB", model.sizeGB)
            }
            return String(format: "%.0f MB", model.sizeGB * 1024)
        }
        return "size unknown"
    }

    /// Recomputes an installed model's real size from disk (for JSON-parsed
    /// catalog entries whose `sizeGB` may be stale or missing).
    func installedSizeLabel(_ path: String) -> String {
        if let gb = installedSizeGB(path) {
            return gb >= 1.0 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", gb * 1024)
        }
        return "size unknown"
    }
}
