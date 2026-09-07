import SwiftUI
import AppKit

/// The chat-session sidebar: new chat, list of pinned/normal/archived chats
/// with rename, delete, archive, and pin actions. Also searchable and
/// exportable (Markdown/JSON).
struct SessionListView: View {
    @ObservedObject var store: ChatStore
    @State private var renamingID: UUID?
    @State private var draftTitle = ""
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chats")
                    .font(.headline)
                Spacer()
                Button {
                    store.newChat()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search chats…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            List {
                let pinned = store.pinnedSessions.filter(matches)
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { session in
                            row(session)
                        }
                    }
                }

                let normal = store.normalSessions.filter(matches)
                Section(searchText.isEmpty ? "Chats" : "Results") {
                    ForEach(normal) { session in
                        row(session)
                    }
                }

                let archived = store.archivedSessions.filter(matches)
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { session in
                            row(session)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func matches(_ session: ChatSession) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if session.title.localizedCaseInsensitiveContains(q) { return true }
        return session.messages.contains { $0.text.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder
    private func row(_ session: ChatSession) -> some View {
        let isActive = session.id == store.activeID
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            if renamingID == session.id {
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        store.rename(session.id, to: draftTitle)
                        renamingID = nil
                    }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .lineLimit(1)
                        .fontWeight(isActive ? .semibold : .regular)
                    Text(relative(session.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { store.select(session.id) }
        .contextMenu {
            Button("Rename") {
                draftTitle = session.title
                renamingID = session.id
            }
            Button(session.isPinned ? "Unpin" : "Pin") {
                store.togglePin(session.id)
            }
            Button(session.isArchived ? "Unarchive" : "Archive") {
                if session.isArchived { store.unarchive(session.id) } else { store.archive(session.id) }
            }
            Divider()
            Menu("Export") {
                Button("As Markdown…") {
                    reveal(store.exportConversation(session.id, format: .markdown))
                }
                Button("As JSON…") {
                    reveal(store.exportConversation(session.id, format: .json))
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.delete(session.id)
            }
        }
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
