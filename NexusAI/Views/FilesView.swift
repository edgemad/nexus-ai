import SwiftUI

struct FilesView: View {
    @ObservedObject var activity: ActivityStore
    @State private var currentURL: URL?
    @State private var entries: [FileEntry] = []
    @State private var path = "Home"
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connected files")
                    .font(.title2.bold())
                Spacer()
                Button {
                    openFolder()
                } label: {
                    Label("Connect folder", systemImage: "folder.badge.plus")
                }
            }

            if currentURL == nil {
                emptyState
            } else {
                navigationBar
                fileList
            }
        }
        .cardStyle()
        .onAppear {
            if currentURL == nil {
                currentURL = FileManager.default.homeDirectoryForCurrentUser
                load()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No folder connected")
                .font(.headline)
            Text("Choose a folder on your Mac to browse its files.")
                .foregroundStyle(.secondary)
            Button("Connect folder") { openFolder() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(currentURL?.path == "/")

            ScrollView(.horizontal, showsIndicators: false) {
                Text(currentURL?.path ?? "/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Filter files…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }

    private var fileList: some View {
        let filtered = search.isEmpty ? entries : entries.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { entry in
                    Button {
                        open(entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                            Text(entry.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if let size = entry.sizeString {
                                Text(size)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if entry.id != filtered.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(minHeight: 280)
    }

    // MARK: - Actions

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Connect"
        if panel.runModal() == .OK, let url = panel.url {
            currentURL = url
            load()
            activity.log(icon: "folder.badge.plus", title: "Folder connected",
                         detail: "Connected to \(url.path)", color: .blue)
        }
    }

    private func load() {
        guard let url = currentURL else { return }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let mapped = contents.compactMap { url -> FileEntry? in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Double($0) }
            return FileEntry(url: url, name: url.lastPathComponent,
                             isDirectory: isDir.boolValue, size: size)
        }
        entries = mapped.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func open(_ entry: FileEntry) {
        if entry.isDirectory {
            currentURL = entry.url
            load()
        } else {
            NSWorkspace.shared.open(entry.url)
            activity.log(icon: "doc", title: "Opened file",
                         detail: entry.url.lastPathComponent, color: .purple)
        }
    }

    private func goUp() {
        guard let url = currentURL else { return }
        let parent = url.deletingLastPathComponent()
        currentURL = parent
        load()
    }
}

private struct FileEntry: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Double?

    var sizeString: String? {
        guard let size else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
