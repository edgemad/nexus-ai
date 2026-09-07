import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A single chat window bound to a ChatStore session. When `isFloating` the
/// window hosts its own native minimize/maximize/close controls and uses a
/// compact header (no session chrome).
struct ChatWindowView: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var modelStore: ModelStore
    @ObservedObject var botStore = BotStore.shared
    @ObservedObject var presetStore = PresetStore.shared
    var isFloating = false
    var speech: SpeechEngine?
    var voice: VoiceConversationController?
    @State private var draft = ""
    @State private var webResearch = false
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var attachments: [URL] = []
    @FocusState private var inputFocused: Bool
    @State private var lastUserQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(chat.activeSession?.title ?? "Chat")
                    .font(.title2.bold())
                    .lineLimit(1)
                Spacer()
                if !isFloating {
                    skillsMenu
                    presetMenu
                    botMenu
                    modelChip
                    moreMenu
                }
                if chat.llm.isStreaming || chat.isProcessing {
                    HStack(spacing: 6) {
                        if chat.isResponding {
                            ProgressView(value: chat.responsePercent)
                                .progressViewStyle(.linear)
                                .frame(width: 90)
                            Text("\(Int((chat.responsePercent * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("\(chat.responseTokens)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                windowControls
            }

            Divider().opacity(0.3)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.activeSession?.messages ?? []) { message in
                            MessageBubble(message: message,
                                          chat: chat,
                                          isLast: message.id == chat.activeSession?.messages.last?.id)
                                .id(message.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 340)
                .onChange(of: chat.activeSession?.messages.count ?? 0) { _ in
                    if let last = chat.activeSession?.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            VStack(spacing: 10) {
                if !attachments.isEmpty {
                    attachmentChips
                }
                HStack(spacing: 10) {
                    Button {
                        pickAttachments()
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(attachments.isEmpty ? .secondary : Color.accentColor)
                    .help("Attach images, video, audio, or documents")

                    TextField("Message Nexie…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($inputFocused)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 1
                                )
                                .blendMode(.plusLighter)
                        )
                        .onSubmit(send)

                    if let voice {
                        VoiceMicButton(voice: voice)
                    }

                    Button {
                        send()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isProcessing)

                    if chat.isProcessing || chat.llm.isStreaming {
                        Button {
                            chat.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                        .help("Stop generating")
                    }
                }

                if let voice, voice.isActive || voice.error != nil {
                    VoiceStatus(voice: voice)
                }

                HStack {
                    Picker("Answer mode", selection: $chat.answerMode) {
                        ForEach(AnswerMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 210)
                    .help("Quick: short, no research. Research: web + sources. Deep: thorough multi-source answer.")

                    Toggle(isOn: $webResearch) {
                        Label("Deep web research", systemImage: "globe")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Toggle(isOn: $chat.computerControl) {
                        Label("Computer control", systemImage: "terminal")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Let the model propose actions on your Mac (every action needs your approval)")

                    Button {
                        Task { await chat.selfImprovement.runScan(source: "You clicked Check for upgrades.") }
                    } label: {
                        if chat.selfImprovement.isScanning {
                            ProgressView().controlSize(.mini)
                            Text("Auditing…")
                        } else {
                            Label("Check for upgrades", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(chat.selfImprovement.isScanning)
                    .help("The AI audits backends, models and upstream releases, then proposes upgrades that need your approval")

                    Spacer()

                    if chat.isProcessing && webResearch {
                        Text("Searching the web…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showSavePreset) {
            savePresetSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: .nexieFocusInput)) { _ in
            inputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .nexieToggleMic)) { _ in
            voice?.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nexieRevealOutput)) { _ in
            revealLastOutput()
        }
    }

    private var activeBot: Bot? {
        guard let session = chat.activeSession else { return nil }
        return botStore.bot(withID: session.botID)
    }

    private var activePreset: PromptPreset? {
        guard let session = chat.activeSession else { return nil }
        return presetStore.preset(withID: session.presetID)
    }

    /// Reusable capsule-style chip used by the bot and preset pickers.
    private func capsuleButton(icon: String, label: String, tint: Color?, help: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint ?? Color.secondary.opacity(0.18)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    /// Reusable "skills" that start Nexie on a common workflow. Each pre-fills
    /// the input with a structured template the user completes, then sends.
    private var skillsMenu: some View {
        Menu {
            Button("Draft customer reply…") {
                draft = "Draft a customer reply. Tone: <friendly / formal / brief>.\nSituation: <what happened>\nKey points to cover:\n- <point>\n"
                inputFocused = true
            }
            Button("Compare products…") {
                draft = "Compare these products and give a short recommendation with pros/cons and sources.\nProducts:\n- <product A>\n- <product B>\n"
                inputFocused = true
            }
            Button("Summarize a thread…") {
                draft = "Summarize this conversation/thread into a bullet list of key points and suggested next steps:\n\n<paste text here>\n"
                inputFocused = true
            }
            Button("Research availability…") {
                draft = "Research availability for: <product type>\nRegion: <e.g. Australia>\nGive a shortlist with links, rough prices, and delivery notes, citing sources.\n"
                inputFocused = true
            }
        } label: {
            capsuleButton(icon: "sparkles",
                          label: "Skills",
                          tint: nil,
                          help: "Start a common workflow")
        }
    }

    /// Prompt-preset selector for the active chat session.
    private var presetMenu: some View {
        Menu {
            Button {
                if let sid = chat.activeSession?.id { chat.setPreset(nil, for: sid) }
            } label: {
                Label("No preset", systemImage: "xmark.circle")
            }
            Divider()
            ForEach(presetStore.presets) { preset in
                Button {
                    if let sid = chat.activeSession?.id { chat.setPreset(preset.id, for: sid) }
                } label: {
                    Label(preset.name, systemImage: "text.quote")
                }
            }
            Divider()
            Button("Save current message as preset…") {
                presetName = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                showSavePreset = true
            }
        } label: {
            capsuleButton(icon: "text.quote",
                          label: activePreset?.name ?? "Preset",
                          tint: activePreset != nil ? Color(hex: "16A085") : nil,
                          help: "Choose a reusable instruction preset for this chat")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Regenerate / export actions for the active session.
    private var moreMenu: some View {
        Menu {
            Button {
                if let sid = chat.activeSession?.id { chat.regenerateLast(in: sid) }
            } label: {
                Label("Regenerate last reply", systemImage: "arrow.clockwise")
            }
            .disabled(chat.isProcessing || chat.activeSession?.messages.last?.role == .user)
            Divider()
            Button("Export as Markdown…") {
                if let sid = chat.activeSession?.id {
                    reveal(chat.exportConversation(sid, format: .markdown))
                }
            }
            Button("Export as JSON…") {
                if let sid = chat.activeSession?.id {
                    reveal(chat.exportConversation(sid, format: .json))
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Regenerate or export this chat")
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save prompt preset")
                .font(.headline)
            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSavePreset = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        presetStore.add(PromptPreset(name: name,
                                                     systemPrompt: draft.trimmingCharacters(in: .whitespacesAndNewlines)))
                        if let sid = chat.activeSession?.id {
                            if let saved = presetStore.presets.first(where: { $0.name == name }) {
                                chat.setPreset(saved.id, for: sid)
                            }
                        }
                        draft = ""
                        showSavePreset = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    /// Task-specific bot selector for the active chat session.
    private var botMenu: some View {
        Menu {
            Button {
                if let sid = chat.activeSession?.id { chat.setBot(nil, for: sid) }
            } label: {
                Label("No bot", systemImage: "xmark.circle")
            }
            Divider()
            ForEach(botStore.bots) { bot in
                Button {
                    if let sid = chat.activeSession?.id { chat.setBot(bot.id, for: sid) }
                } label: {
                    Label(bot.name, systemImage: bot.iconName)
                }
            }
            Divider()
            Text("Manage bots in the Bots panel")
                .font(.caption)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeBot?.iconName ?? "sparkles")
                Text(activeBot?.name ?? "No bot")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(activeBot.map { Color(hex: $0.accent) ?? Color.accentColor } ?? Color.secondary.opacity(0.18))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a task-specific bot for this chat")
    }

    private var modelChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(modelStore.selectedModelName != nil ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(modelStore.selectedModelName ?? "No model loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
    }

    /// Minimize / maximize / float controls shown at the top of the chat.
    private var windowControls: some View {
        HStack(spacing: 6) {
            windowButton("minus", tint: Color.yellow.opacity(0.85), help: "Minimize — hides this window and returns to the app") {
                if isFloating {
                    FloatingChatController.shared.minimize()
                } else {
                    window()?.miniaturize(nil)
                }
            }
            windowButton("arrow.up.left.and.arrow.down.right",
                         tint: Color.green.opacity(0.85), help: "Maximize / restore") {
                window()?.zoom(nil)
            }
            windowButton(isFloating ? "arrow.down.backward.square" : "arrow.up.forward.square",
                         tint: Color.blue.opacity(0.85),
                         help: isFloating
                             ? "Return this chat to the main app"
                             : "Float this chat in its own always-on-top window") {
                FloatingChatController.shared.toggle(chat: chat, modelStore: modelStore)
            }
        }
    }

    private func windowButton(_ icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .background(tint, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The hosting window (the floating panel when floating, else key window).
    private func window() -> NSWindow? {
        if isFloating {
            return FloatingChatController.shared.window
        }
        return NSApp.keyWindow
    }

    /// Horizontal row of attached-file chips above the composer.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments, id: \.self) { url in
                    HStack(spacing: 5) {
                        if isImage(url) {
                            AttachmentThumbnail(url: url)
                        } else {
                            Image(systemName: attachmentIcon(url))
                                .font(.caption)
                        }
                        Text((url as NSURL).lastPathComponent ?? url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            attachments.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
        }
    }

    private func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "svg"]
            .contains(url.pathExtension.lowercased())
    }

    private func attachmentIcon(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "svg": return "photo"
        case "mp4", "mov", "m4v", "mkv", "webm", "avi", "mpg", "mpeg": return "film"
        case "wav", "mp3", "m4a", "flac", "aiff", "aif", "ogg", "opus", "wma": return "waveform"
        case "pdf": return "doc.richtext"
        case "txt", "md", "markdown", "csv", "json", "log", "rtf": return "doc.text"
        case "zip", "tar", "gz", "7z", "rar", "dmg", "pkg": return "archivebox"
        default: return "doc"
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Attach files"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        // Accept every file type (and folders) — attachments are passed along
        // by path; text-like ones are also read inline so the model can see them.
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK {
            let picked = panel.urls
            // Inline squash of plain-text-ish docs so the model can read them
            // directly without needing a parser for every format.
            for url in picked {
                let ext = url.pathExtension.lowercased()
                if ["txt", "md", "markdown", "csv", "json", "rtf", "log", "text", "xml", "yml", "yaml", "html", "htm", "swift", "py", "js", "ts", "c", "cpp", "h", "go", "rs", "java", "sh", "sql", "css"].contains(ext),
                   let data = try? Data(contentsOf: url),
                   let s = String(data: data, encoding: .utf8) {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    let snippet = String(trimmed.prefix(4000))
                    draft += snippet + "\n\n"
                }
            }
            attachments.append(contentsOf: picked)
        }
    }

    private func send() {
        var text = draft
        draft = ""
        if !attachments.isEmpty {
            let paths = attachments.map(\.path).joined(separator: "\n")
            text += "\n\n[attached files]\n\(paths)"
            attachments.removeAll()
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { lastUserQuery = t }
        chat.send(text, webResearch: webResearch)
    }

    /// Cmd+D: reveal the most recent generated output folder in Finder.
    private func revealLastOutput() {
        let fm = FileManager.default
        let root = WorkspaceManager.shared.outputsURL
        var newest = root
        if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                   options: [.skipsHiddenFiles]) {
            let dated = items.compactMap { url -> (URL, Date)? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return date.map { (url, $0) }
            }
            if let top = dated.max(by: { $0.1 < $1.1 }) {
                newest = top.0
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([newest])
    }
}

/// Push-to-talk microphone button that observes the voice controller so its
/// recording state re-renders live.
private struct VoiceMicButton: View {
    @ObservedObject var voice: VoiceConversationController

    var body: some View {
        Button {
            voice.toggle()
        } label: {
            Image(systemName: voice.phase == .listening ? "mic.fill" : "mic")
                .foregroundStyle(voice.phase == .listening ? Color.red : Color.accentColor)
        }
        .buttonStyle(.bordered)
        .help(voice.phase == .listening ? "Stop recording and ask" : "Talk to Nexie (speak, and I'll answer aloud)")
    }
}

/// Live status/error line while Nexie listens, thinks, or speaks.
private struct VoiceStatus: View {
    @ObservedObject var voice: VoiceConversationController

    var body: some View {
        HStack(spacing: 8) {
            if let err = voice.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if voice.phase == .listening {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                Text(voice.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if voice.recordingLevel > -50 {
                    Text("●")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("Microphone is picking up audio")
                }
                ProgressView(value: meterFraction(voice.recordingLevel))
                    .progressViewStyle(.linear)
                    .frame(width: 60)
            } else {
                ProgressView().controlSize(.small)
                Text(voice.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if voice.phase == .speaking { voice.cancelSpeaking() }
                else { voice.stop() }
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Cancel voice interaction")
        }
    }

    /// Maps a decibel meter value (-60…0) to a 0…1 progress fraction.
    private func meterFraction(_ db: Float) -> Double {
        let clamped = max(-60, min(0, db))
        return Double((clamped + 60) / 60)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var chat: ChatStore?
    var isLast = false
    @ObservedObject var agent = AgentExecutor.shared
    @State private var editing = false
    @State private var editDraft = ""
    @State private var copied = false

    var body: some View {
        HStack {
            if message.role.isUser { Spacer(minLength: 50) }
            VStack(alignment: message.role.isUser ? .trailing : .leading, spacing: 4) {
                if editing {
                    TextEditor(text: $editDraft)
                        .font(.body)
                        .frame(minWidth: 320, minHeight: 100)
                        .padding(8)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.18)))
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel") { editing = false }
                        Button("Save & resend") { commitResend() }
                            .buttonStyle(.borderedProminent)
                            .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Text(markdown(AgentExecutor.scrubbed(message.text)))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .background(
                            message.role.isUser
                                ? Color.accentColor.opacity(0.22)
                                : Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .opacity(0.35)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 1
                                )
                                .blendMode(.plusLighter)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                }

                HStack(spacing: 10) {
                    Text(message.role.isUser ? "You" : "Nexie")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(message.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let confidence = message.researchConfidence {
                        Text("evidence \(confidence)")
                            .font(.caption2.bold())
                            .foregroundStyle(confidenceColor(confidence))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(confidenceColor(confidence).opacity(0.14))
                            .clipShape(Capsule())
                            .help("Verdict confidence from the cited evidence")
                    }
                    Button {
                        copyMessage()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        Label("Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.iconOnly)
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy this message")
                }

                if !message.role.isUser, !message.sources.isEmpty {
                    evidenceFooter
                }

                if !message.role.isUser {
                    ForEach(agent.actions(for: message.id)) { action in
                        actionCard(action)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: message.role.isUser ? .trailing : .leading)
            if !message.role.isUser { Spacer(minLength: 50) }
        }
        .contextMenu {
            Button {
                copyMessage()
            } label: {
                Label("Copy text", systemImage: "doc.on.doc")
            }
            if message.role.isUser, let chat {
                Divider()
                Button {
                    editDraft = message.text
                    editing = true
                } label: {
                    Label("Edit & resend", systemImage: "square.and.pencil")
                }
                .disabled(chat.isProcessing)
            }
            if !message.role.isUser, let chat {
                Divider()
                Button {
                    if let sid = chat.activeSession?.id { chat.regenerateLast(in: sid) }
                } label: {
                    Label("Regenerate reply", systemImage: "arrow.clockwise")
                }
                .disabled(chat.isProcessing)
            }
            Divider()
            if let chat, !isLast {
                Button {
                    chat.revert(to: message.id)
                } label: {
                    Label("Revert conversation to here", systemImage: "arrow.uturn.backward")
                }
            }
            if let chat {
                Button(role: .destructive) {
                    chat.deleteMessage(message.id)
                } label: {
                    Label("Delete message", systemImage: "trash")
                }
            }
        }
    }

    private func commitResend() {
        guard let chat, let sid = chat.activeSession?.id else { return }
        chat.editAndResend(message.id, newText: editDraft, in: sid)
        editing = false
    }

    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
    }

    /// A permission card for a proposed computer-control action.
    private func actionCard(_ action: AgentAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: action.kind.icon)
                    .foregroundStyle(Color.accentColor)
                Text(action.kind.title)
                    .font(.caption.bold())
                Spacer()
                statusPill(action)
            }

            Text(action.command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))

            switch action.status {
            case .pending:
                HStack(spacing: 8) {
                    Text("Permission required")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Spacer()
                    Button {
                        if let aid = action.approvalID {
                            ApprovalStore.shared.decide(approvalID: aid, allow: false)
                        }
                    } label: {
                        Label("Deny", systemImage: "xmark")
                    }
                    Button {
                        if let aid = action.approvalID {
                            ApprovalStore.shared.decide(approvalID: aid, allow: true)
                        }
                    } label: {
                        Label("Approve & run", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        AgentExecutor.shared.cancel(action.id)
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .help("Interrupt the running command")
                }
            case .done, .failed, .approved:
                if let out = action.result {
                    Text(out)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(action.status == .failed ? .red : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .denied:
                Text("Denied by you — nothing was run.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .cancelled:
                Text("Cancelled by you — running command was interrupted.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12)))
    }

    private func statusPill(_ action: AgentAction) -> some View {
        let color: Color = switch action.status {
        case .pending: .yellow
        case .running, .approved: .blue
        case .done: .green
        case .failed: .red
        case .denied, .cancelled: .gray
        }
        return Text(action.status.label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.25), in: Capsule())
    }

    /// Lightweight Markdown rendering via AttributedString (code, bold, links…).
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// Evidence footer: numbered, clickable source chips with a confidence
    /// badge, pinned under any assistant message backed by research.
    private var evidenceFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Sources (\(message.sources.count))")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, source in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("[\(index + 1)]")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(source.title.isEmpty ? source.url : source.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Text(domain(of: source.url))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .help("Open \(source.url)")
                    } else {
                        Text(source.title.isEmpty ? source.url : source.title)
                            .font(.caption2)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 440, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
    }

    private func domain(of urlString: String) -> String {
        URL(string: urlString)?.host
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? urlString
    }

    private func confidenceColor(_ confidence: Int) -> Color {
        switch confidence {
        case 70...: return .green
        case 40...: return .yellow
        default: return .orange
        }
    }
}

/// A small rounded thumbnail so attached screenshots/images are visible before
/// they're sent. Any OS screenshot (Mac/Windows/Linux) is a plain image file and
/// renders here exactly the same way.
private struct AttachmentThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear {
            if image == nil {
                image = NSImage(contentsOf: url)
            }
        }
    }
}
