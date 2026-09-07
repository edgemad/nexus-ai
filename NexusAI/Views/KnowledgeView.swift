import SwiftUI

/// Knowledge panel: lets the user manage the agent's skills, knowledge base,
/// and memories — and see what the assistant has learned.
struct KnowledgeView: View {
    @ObservedObject var store: KnowledgeStore
    @State private var filter: KnowledgeType? = nil
    @State private var query = ""
    @State private var showAdd = false
    @State private var confirmingClear = false

    private var filtered: [KnowledgeItem] {
        let typed = filter.map { f in store.items.filter { $0.type == f } } ?? store.items
        guard !query.isEmpty else { return typed }
        return typed.filter { $0.relevance(to: query) > 0 || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(spacing: 10) {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(KnowledgeType?.none)
                    ForEach(KnowledgeType.allCases) { t in
                        Text(t.rawValue).tag(KnowledgeType?.some(t))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                TextField("Search skills, knowledge, memory…", text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            countsRow

            list
        }
        .cardStyle()
        .sheet(isPresented: $showAdd) {
            AddKnowledgeSheet(store: store)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Knowledge & Memory")
                    .font(.title2.bold())
                Text("Skills, knowledge library, and memories the agent can learn and refer to.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAdd = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear all", systemImage: "trash")
            }
            .disabled(store.items.isEmpty)
            .confirmationDialog("Clear all knowledge and memory?",
                                isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear everything", role: .destructive) { store.clearAll() }
            }
        }
    }

    private var countsRow: some View {
        HStack(spacing: 10) {
            countBadge(type: .skill, count: store.skills.count)
            countBadge(type: .knowledge, count: store.knowledge.count)
            countBadge(type: .memory, count: store.memories.count)
        }
    }

    @ViewBuilder
    private func countBadge(type: KnowledgeType, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: type.icon)
                .foregroundStyle(type.tint)
            Text(type.rawValue)
                .font(.caption)
            Text("\(count)")
                .font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08))
        .clipShape(Capsule())
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(store.items.isEmpty ? "No knowledge yet" : "No matches")
                            .font(.headline)
                        Text(store.items.isEmpty
                             ? "Add a skill, a knowledge entry, or chat with the assistant to let it learn."
                             : "Try a different search or filter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                } else {
                    ForEach(filtered) { item in
                        KnowledgeRow(item: item) {
                            store.delete(item.id)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 320)
    }
}

private struct KnowledgeRow: View {
    let item: KnowledgeItem
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.type.icon)
                .font(.title3)
                .foregroundStyle(item.type.tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.headline)
                    if let kind = item.memoryKind {
                        Text(kind.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(kind.tint.opacity(0.18))
                            .foregroundStyle(kind.tint)
                            .clipShape(Capsule())
                    }
                }
                Text(item.content)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                HStack(spacing: 6) {
                    Text(item.source)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(item.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .foregroundStyle(item.type.tint)
                    }
                    Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Sheet for adding a new skill, knowledge entry, or memory item.
private struct AddKnowledgeSheet: View {
    @ObservedObject var store: KnowledgeStore
    @Environment(\.dismiss) private var dismiss

    @State private var type: KnowledgeType = .knowledge
    @State private var memoryKind: MemoryKind = .fact
    @State private var title = ""
    @State private var content = ""
    @State private var skillDescription = ""
    @State private var topic = ""
    @State private var tagsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to knowledge & memory")
                .font(.title3.bold())

            Picker("Type", selection: $type) {
                ForEach(KnowledgeType.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if type == .memory {
                Picker("Memory kind", selection: $memoryKind) {
                    ForEach(MemoryKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            if type == .skill {
                TextField("When to apply (optional description)", text: $skillDescription)
                    .textFieldStyle(.roundedBorder)
            }
            if type == .knowledge {
                TextField("Topic / bundle (optional)", text: $topic)
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Tags, comma separated (optional)", text: $tagsText)
                .textFieldStyle(.roundedBorder)

            Text("Content")
                .font(.subheadline.bold())
            TextEditor(text: $content)
                .frame(height: 140)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty ||
                              content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func add() {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.add(KnowledgeItem(
            type: type,
            title: title.trimmingCharacters(in: .whitespaces),
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: tags,
            source: "manual",
            memoryKind: type == .memory ? memoryKind : nil,
            skillDescription: type == .skill ? skillDescription : nil,
            topic: type == .knowledge ? topic : nil
        ))
        dismiss()
    }
}
