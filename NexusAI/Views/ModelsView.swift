import SwiftUI

struct ModelsView: View {
    @ObservedObject var store: ModelStore
    @ObservedObject var backend: BackendManager

    /// A model deletion waiting for confirmation.
    private struct PendingDelete {
        let path: String
        let kind: ModelStore.ModelKind
        let displayName: String
    }
    @State private var pendingDelete: PendingDelete?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(alignment: .leading, spacing: 20) {
                    installedSection(title: "Text models", subtitle: "Local GGUF chat / reasoning models",
                                     icon: "bubble.left.and.bubble.right", kind: .text)

                    Divider()

                    installedSection(title: "Image models", subtitle: "Stable Diffusion checkpoints",
                                     icon: "photo.on.rectangle.angled", kind: .image)
                }

                Divider()

                HStack {
                    Text("Available to download")
                        .font(.headline)
                    Spacer()
                    if store.isRefreshingCatalog {
                        ProgressView().controlSize(.small)
                        Text("Checking Hugging Face…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            store.checkForLatestModels()
                        } label: {
                            Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .controlSize(.small)
                    }
                }

                // Catalog browsing filter: which models to show.
                Picker("Catalog", selection: Binding(
                    get: { store.catalogMode },
                    set: { mode in store.setCatalogMode(mode) }
                )) {
                    ForEach(ModelCatalogService.Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Search-model line: type a specific model to look it up on
                // Hugging Face and see matching installable entries.
                if store.catalogMode == .search {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search a specific model (e.g. llama 3, phi-4, mistral 7b)…",
                                  text: $store.catalogSearchText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { store.refreshCatalogFromNetwork() }
                        if !store.catalogSearchText.isEmpty {
                            Button {
                                store.catalogSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                LazyVStack(spacing: 10) {
                    ForEach(store.catalog) { model in
                        catalogRow(model)
                    }
                }
            }
            .padding(20)
            .textSelection(.enabled)
        }
        .confirmationDialog(deleteTitle, isPresented: deletePresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                performDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - Delete confirmation

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var deleteTitle: String {
        if let p = pendingDelete {
            return "Delete “\(p.displayName)”?"
        }
        return "Delete model?"
    }

    private var deleteMessage: String {
        "This permanently removes the model file from disk. This cannot be undone."
    }

    private func performDelete() {
        guard let p = pendingDelete else { return }
        if p.kind == .text { store.deleteTextModel(p.path) }
        else { store.deleteImageModel(p.path) }
        pendingDelete = nil
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Model Manager")
                    .font(.title2.bold())
                Text("Select, download, and manage local models. Downloads land in the workspace Models folder and are loaded by the local backends.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.downloading {
                ProgressView(value: store.downloadProgress)
                    .frame(width: 120)
                Text("\(store.downloadProgress > 0 ? Int((store.downloadProgress * 100).rounded()) : 0)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    /// The download-progress area shown in a catalog row while that model is
    /// being fetched (supports several downloads at once — one per row).
    @ViewBuilder
    private func downloadPill(for filename: String) -> some View {
        if let task = store.downloads.first(where: { $0.filename == filename && !$0.isComplete }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView(value: task.progress)
                        .frame(width: 90)
                    Text("\(task.percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(task.failed ? "Failed — retry" : "Downloading…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        } else if let task = store.downloads.first(where: { $0.filename == filename && $0.isComplete }) {
            HStack(spacing: 6) {
                Image(systemName: task.failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(task.failed ? .orange : .green)
                Text(task.failed ? "Failed" : "Installed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(task.failed ? .orange : .green)
                if task.failed {
                    Button("Retry") {
                        if let catalogModel = store.catalog.first(where: { $0.filename == filename }) {
                            store.download(catalogModel)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                } else {
                    Button("Dismiss") { store.dismissDownload(task.id) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// An installed-model group rendered as a distinct card with its own header
    /// and divider so image / audio / text model types are clearly separated.
    @ViewBuilder
    private func installedSection(title: String, subtitle: String, icon: String,
                                  kind: ModelStore.ModelKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 2)

            let list = kind == .text ? store.installedTextModels : store.installedImageModels
            if list.isEmpty {
                Text("No \(kind == .text ? "text" : "image") models installed yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(list, id: \.self) { path in
                    let isSelected = (kind == .text && path == store.selectedTextModelPath)
                        || (kind == .image && path == store.selectedImageModelPath)
                    HStack {
                        Image(systemName: kind == .text ? "bubble.left.and.bubble.right" : "photo")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent)
                            .lineLimit(1)
                        Text(store.installedSizeLabel(path))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isSelected {
                            Text("Active")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        } else {
                            Button("Select") {
                                if kind == .text { store.selectTextModel(path) }
                                else { store.selectImageModel(path) }
                            }
                        }
                        Button {
                            pendingDelete = PendingDelete(
                                path: path,
                                kind: kind,
                                displayName: (path as NSString).lastPathComponent)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Delete this model from disk")
                        .disabled(store.downloading)
                    }
                    .padding(10)
                    .background(isSelected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            if kind == .image {
                Button("Import image model from file…") {
                    store.addImageModelFromFile()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .cardStyle()
    }

    private func catalogRow(_ model: ModelStore.CatalogModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: model.kind == .text ? "bubble.left" : "photo")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text("\(model.kind.rawValue) · \(store.sizeLabel(for: model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.downloads.contains(where: { $0.filename == model.filename }) {
                downloadPill(for: model.filename)
            } else {
                Button("Download") {
                    store.download(model)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
