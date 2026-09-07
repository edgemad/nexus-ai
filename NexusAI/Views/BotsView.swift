import SwiftUI

/// Bots panel: lets the user create, edit, and delete task-specific assistants
/// (personas with their own system prompt) that can be attached to any chat.
struct BotsView: View {
    @ObservedObject var store: BotStore
    @State private var showAdd = false
    @State private var editing: Bot?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if store.bots.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .cardStyle()
        .sheet(isPresented: $showAdd) {
            AddBotSheet(store: store)
        }
        .sheet(item: $editing) { bot in
            AddBotSheet(store: store, bot: bot)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bots")
                    .font(.title2.bold())
                Text("Create assistants for specific tasks and attach them to any chat.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAdd = true
            } label: {
                Label("New bot", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No bots yet")
                .font(.headline)
            Text("Create a bot like “Email Writer”, “Code Reviewer”, or “Math Tutor” and it becomes a personality available in every chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.bots) { bot in
                    BotRow(bot: bot) {
                        editing = bot
                    } onToggle: {
                        toggleBot(bot)
                    } onDelete: {
                        store.delete(bot.id)
                    }
                }
            }
        }
        .frame(minHeight: 320)
    }

    private func toggleBot(_ bot: Bot) {
        // Used from the chat picker primarily; here it opens the editor too.
        editing = bot
    }
}

private struct BotRow: View {
    let bot: Bot
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: bot.iconName)
                .font(.title3)
                .foregroundStyle(Color(hex: bot.accent) ?? .blue)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(bot.name)
                        .font(.headline)
                    if bot.isPreset {
                        Text("Built-in")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                if !bot.tagline.isEmpty {
                    Text(bot.tagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !bot.systemPrompt.isEmpty {
                    Text(bot.systemPrompt)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit this bot")

            if !bot.isPreset {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this bot")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Sheet for creating or editing a bot.
private struct AddBotSheet: View {
    @ObservedObject var store: BotStore
    var bot: Bot? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = "sparkles"
    @State private var accent = ProfileStore.accentChoices.first ?? "2F6FD8"
    @State private var tagline = ""
    @State private var systemPrompt = ""
    @State private var showingPreset = false

    private var isEditing: Bool { bot != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit bot" : "New bot")
                .font(.title3.bold())

            TextField("Name (e.g. Email Writer)", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(Color(hex: accent) ?? .blue)
                    .frame(width: 40)
                Menu {
                    ForEach(ProfileStore.iconChoices, id: \.self) { ic in
                        Button {
                            icon = ic
                        } label: {
                            Label(ic, systemImage: ic)
                        }
                    }
                } label: {
                    Image(systemName: "paintbrush")
                        .frame(width: 32, height: 32)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)

                Spacer()

                ForEach(ProfileStore.accentChoices, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .blue)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(
                            accent == hex ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: accent == hex ? 2 : 1))
                        .onTapGesture { accent = hex }
                }
            }

            TextField("Purpose / tagline (one line)", text: $tagline)
                .textFieldStyle(.roundedBorder)
                .help("Shown under the bot name to describe what it does.")

            Text("Instructions (system prompt)")
                .font(.subheadline.bold())
            TextEditor(text: $systemPrompt)
                .frame(height: 150)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("These instructions steer the model whenever this bot is active in a chat.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isEditing ? "Save" : "Create") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let bot {
                name = bot.name
                icon = bot.iconName
                accent = bot.accent
                tagline = bot.tagline
                systemPrompt = bot.systemPrompt
            }
        }
    }

    private func save() {
        let b = Bot(id: bot?.id ?? UUID(),
                    name: name.trimmingCharacters(in: .whitespaces),
                    iconName: icon,
                    accent: accent,
                    tagline: tagline.trimmingCharacters(in: .whitespaces),
                    systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    isPreset: bot?.isPreset ?? false)
        if isEditing { store.update(b) } else { store.add(b) }
        dismiss()
    }
}