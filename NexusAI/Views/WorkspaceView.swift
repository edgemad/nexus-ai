import SwiftUI
import UniformTypeIdentifiers

/// Browsable view of the on-disk NexusAI Workspace folder: Outputs, Models,
/// Chats, Archives, and the in-app data files (memory, knowledge, profiles).
struct WorkspaceView: View {
    @ObservedObject var activity: ActivityStore
    @State private var currentURL: URL?
    @State private var entries: [WorkspaceEntry] = []
    @State private var search = ""

    private let ws = WorkspaceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if currentURL == nil {
                rootFolders
            } else {
                navigationBar
                fileList
            }
        }
        .cardStyle()
        .onAppear {
            if currentURL == nil {
                currentURL = ws.rootURL
                load()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workspace")
                    .font(.title2.bold())
                Text(ws.rootURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([ws.rootURL])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    /// Top-level quick links into each workspace subfolder as tiles.
    private var rootFolders: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                folderTile(title: "Outputs", icon: "photo.stack", url: ws.outputsURL)
                folderTile(title: "Models", icon: "square.stack.3d.up", url: ws.modelsURL)
                folderTile(title: "Chats", icon: "bubble.left.and.bubble.right", url: ws.chatsURL)
                folderTile(title: "Archives", icon: "archivebox", url: ws.archivesURL)
            }
            .padding(.top, 6)

            if !inAppFiles.isEmpty {
                Divider().padding(.vertical, 12)
                Text("App data")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LazyVStack(spacing: 0) {
                    ForEach(inAppFiles) { file in
                        dataFileRow(file)
                    }
                }
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var inAppFiles: [InAppFile] {
        [
            InAppFile(name: "memory.json", kind: "Agent memory"),
            InAppFile(name: "knowledge.json", kind: "Skills & knowledge"),
            InAppFile(name: "profiles.json", kind: "User profiles")
        ]
    }

    @ViewBuilder
    private func folderTile(title: String, icon: String, url: URL) -> some View {
        Button {
            currentURL = url
            load()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(.blue)
                Text(title)
                    .font(.headline)
                Text(countLabel(for: url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func dataFileRow(_ file: InAppFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline)
                Text(file.kind).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([ws.rootURL.appendingPathComponent(file.name)])
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        if file.name != inAppFiles.last?.name {
            Divider().padding(.leading, 40)
        }
    }

    private func countLabel(for url: URL) -> String {
        let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count ?? 0
        return "\(count) items"
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            Button {
                currentURL = ws.rootURL
                load()
            } label: {
                Image(systemName: "house")
            }
            Text(currentURL?.path ?? "/")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            TextField("Filter…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
    }

    private var fileList: some View {
        let filtered = search.isEmpty ? entries : entries.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { entry in
                    HStack(spacing: 12) {
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    if entry.id != filtered.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(minHeight: 300)
    }

    // MARK: - Actions

    private func load() {
        guard let url = currentURL else { return }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let mapped = contents.compactMap { url -> WorkspaceEntry? in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Double($0) }
            return WorkspaceEntry(url: url, name: url.lastPathComponent,
                                  isDirectory: isDir.boolValue, size: size)
        }
        entries = mapped.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func open(_ entry: WorkspaceEntry) {
        if entry.isDirectory {
            currentURL = entry.url
            load()
        } else {
            NSWorkspace.shared.open(entry.url)
            activity.log(icon: "doc", title: "Opened workspace file",
                         detail: entry.url.lastPathComponent, color: .purple)
        }
    }

    private func goUp() {
        guard let url = currentURL, url.path != ws.rootURL.path else {
            currentURL = nil
            entries = []
            return
        }
        let parent = url.deletingLastPathComponent()
        currentURL = parent.path == ws.rootURL.path ? ws.rootURL : parent
        load()
    }
}

private struct WorkspaceEntry: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Double?

    var sizeString: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

private struct InAppFile: Identifiable {
    let id = UUID()
    let name: String
    let kind: String
}
