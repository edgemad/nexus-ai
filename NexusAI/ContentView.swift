import SwiftUI

struct ContentView: View {
    @State private var selected = AppPanel.chat
    @State private var sessionsVisible = true

    @StateObject private var chatStore = ChatStore()
    @StateObject private var backend = BackendManager.shared
    @StateObject private var modelStore = ModelStore(backend: BackendManager.shared)
    @StateObject private var imageGenerator = ImageGenerator(backend: BackendManager.shared)
    @StateObject private var videoGenerator = VideoGenerator()
    @StateObject private var speechEngine = SpeechEngine(backend: BackendManager.shared)
    @StateObject private var audioMixer = AudioMixer()
    @StateObject private var audioStudioGenerator = AudioStudioGenerator()
    @StateObject private var musicPackCoordinator = MusicPackCoordinator()
    @StateObject private var mediaPlayer = MediaPlayer()
    @ObservedObject private var theme = ThemeManager.shared
    @StateObject private var profiles = ProfileStore.shared
    @StateObject private var systemMonitor = SystemMonitor()
    @StateObject private var activityStore = ActivityStore()
    @StateObject private var approvalStore = ApprovalStore.shared
    @StateObject private var automationStore = AutomationStore()
    @StateObject private var taskStore = TaskStore()
    @StateObject private var taskGraphEngine = TaskGraphEngine.shared
    @State private var isOnline = false

    init() {
        // All feature stores share BackendManager.shared so a single set of
        // backend processes is owned across the app.
        // Eagerly materialize shared stores so their seeded presets/bots are
        // written on first launch even before a panel that renders them opens.
        _ = BotStore.shared
        _ = PresetStore.shared
    }

    var body: some View {
        ZStack {
            // Liquid glass aurora backdrop behind everything.
            LiquidGlassBackground(accent: theme.accentColor.opacity(1.0))
                .allowsHitTesting(false)

            NavigationSplitView {
                sidebar
            } detail: {
                detailPane
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(WindowAutoSizer(panel: selected))
        .tint(theme.accentColor)
        .preferredColorScheme(theme.appearance.colorScheme)
        .onAppear { systemMonitor.setActive(selected == .health) }
        .onChange(of: selected) { panel in
            systemMonitor.setActive(panel == .health)
            activityStore.log(
                icon: panel.icon,
                title: "Opened \(panel.title)",
                detail: panel.subtitle,
                color: .blue
            )
        }
        .toolbar {
            ToolbarItem {
                Button {
                    toggleSessionSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Show or hide the chat session list")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(isOnline ? "Online" : "Offline") {
                    isOnline.toggle()
                    activityStore.log(
                        icon: "network",
                        title: isOnline ? "Connection online" : "Connection offline",
                        detail: isOnline ? "Connected to network services." : "Running fully offline.",
                        color: isOnline ? .green : .gray
                    )
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selected) {
            Section("Assistant") {
                ForEach([AppPanel.chat, .models]) { panel in
                    Label(panel.title, systemImage: panel.icon)
                        .tag(panel)
                }
            }
            Section("Studio") {
                ForEach([AppPanel.imageStudio, .video, .audio, .musicStudio]) { panel in
                    Label(panel.title, systemImage: panel.icon)
                        .tag(panel)
                }
            }
            Section("System") {
                ForEach([AppPanel.health, .files, .workspace, .knowledge, .automations, .tasks, .taskGraph, .bots, .activity, .approvals, .settings]) { panel in
                    Label(panel.title, systemImage: panel.icon)
                        .tag(panel)
                        .badge(panel == .approvals && approvalStore.pendingCount > 0
                               ? approvalStore.pendingCount : 0)
                }
            }
        }
        .navigationTitle("Nexie")
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 220)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.title)
                        .font(.largeTitle.bold())
                    Text(selected.subtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                profileIndicator
            }
            .padding(24)

            Divider().opacity(0.3)

            selectedView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.ultraThinMaterial.opacity(theme.glassOpacity))
    }

    private func toggleSessionSidebar() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            sessionsVisible.toggle()
        }
    }

    private var profileIndicator: some View {
        HStack(spacing: 10) {
            if let p = profiles.activeProfile {
                HStack(spacing: 6) {
                    Image(systemName: p.iconName)
                        .foregroundStyle(Color(hex: p.accent) ?? .blue)
                    Text(p.name)
                        .font(.subheadline)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
            }
            Circle()
                .fill(isOnline ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
        }
    }

    @ViewBuilder
    private var selectedView: some View {
        switch selected {
        case .chat:
            ChatArea(chat: chatStore, modelStore: modelStore, speech: speechEngine,
                     sessionsVisible: $sessionsVisible)
        case .models:
            ModelsView(store: modelStore, backend: backend)
        case .imageStudio:
            ImageStudioView(generator: imageGenerator, modelStore: modelStore)
        case .video:
            VideoStudioView(generator: videoGenerator, modelStore: modelStore, mediaPlayer: mediaPlayer)
        case .audio:
            AudioView(engine: speechEngine, mixer: audioMixer, modelStore: modelStore, mediaPlayer: mediaPlayer, generator: audioStudioGenerator)
        case .musicStudio:
            MusicStudioView(coordinator: musicPackCoordinator, mediaPlayer: mediaPlayer)
        case .health:
            HealthView(monitor: systemMonitor, online: isOnline)
        case .files:
            FilesView(activity: activityStore)
        case .workspace:
            WorkspaceView(activity: activityStore)
        case .knowledge:
            KnowledgeView(store: KnowledgeStore.shared)
        case .automations:
            AutomationsView(store: automationStore, activity: activityStore)
        case .tasks:
            TasksView(store: taskStore, activity: activityStore)
        case .taskGraph:
            TaskGraphView(engine: taskGraphEngine, activity: activityStore)
        case .bots:
            BotsView(store: BotStore.shared)
        case .activity:
            ActivityView(store: activityStore)
        case .approvals:
            ApprovalsView(store: approvalStore, activity: activityStore)
        case .settings:
            SettingsView(theme: theme, profiles: profiles, backend: backend)
        }
    }
}

/// The chat workspace: a glass session sidebar (list + open-chat dock) beside
/// the active chat window. Uses a plain HStack so we avoid nesting a
/// NavigationSplitView inside the outer one (which crashes Auto Layout).
private struct ChatArea: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var modelStore: ModelStore
    let speech: SpeechEngine
    @Binding var sessionsVisible: Bool
    @State private var sessionWidth: CGFloat = 260
    @State private var dragging = false
    @StateObject private var voice: VoiceConversationController

    init(chat: ChatStore, modelStore: ModelStore, speech: SpeechEngine,
         sessionsVisible: Binding<Bool>) {
        self.chat = chat
        self.modelStore = modelStore
        self.speech = speech
        self._sessionsVisible = sessionsVisible
        _voice = StateObject(wrappedValue: VoiceConversationController(speech: speech, chat: chat))
        // When Nexie offers to generate audio and the user says "yes", replay
        // the last assistant reply out loud with the configured Jarvis voice.
        chat.audioGenerator = { [weak speech] in
            guard let speech, let session = chat.activeSession,
                  let lastReply = session.messages.last(where: { $0.role == .assistant })?.text else { return }
            let settings = AssistantSettings.shared
            let clean = lastReply
            Task { @MainActor in
                let voiceName = settings.speakingVoice
                let speed = settings.effectiveSpeed
                if let url = await speech.synthesize(clean, voice: voiceName, speed: speed) {
                    speech.play(url)
                }
            }
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ChatWindowView(chat: chat, modelStore: modelStore, speech: speech, voice: voice)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if sessionsVisible {
                sessionSidebar
                    .frame(width: sessionWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Thin drag handle to resize the sidebar.
            if sessionsVisible {
                Rectangle()
                    .fill(.white.opacity(dragging ? 0.5 : 0.0))
                    .frame(width: 5)
                    .offset(x: sessionWidth - 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragging = true
                                sessionWidth = min(max(sessionWidth + value.translation.width, 190), 380)
                            }
                            .onEnded { _ in dragging = false }
                    )
            }
        }
        .clipped()
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: sessionsVisible)
    }

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            SessionListView(store: chat)
            Divider().opacity(0.3)
            SessionDock(chat: chat, active: chat.activeID) { id in
                chat.select(id)
            }
        }
        .background(.ultraThinMaterial)
        .glassBorder()
    }
}

/// A hairline "liquid glass" border for panels.
private struct GlassBorderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
        )
    }
}

private extension View {
    func glassBorder() -> some View {
        modifier(GlassBorderModifier())
    }
}

/// A horizontal dock of open chat tiles pinned to the bottom of the chat
/// sidebar. Each tile switches the active chat and can be pinned/archived
/// or deleted via right-click.
private struct SessionDock: View {
    let chat: ChatStore
    let active: UUID?
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Open chats")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    chat.newChat()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chat.sessions.filter { !$0.isArchived }) { session in
                        SessionTile(chat: chat, sessionID: session.id,
                                    active: session.id == active, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }
}

/// A single chat "tab" in the dock.
private struct SessionTile: View {
    let chat: ChatStore
    let sessionID: UUID
    let active: Bool
    let onSelect: (UUID) -> Void

    private var session: ChatSession? {
        chat.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        Button {
            onSelect(sessionID)
        } label: {
            HStack(spacing: 6) {
                Text(session?.title ?? "Chat")
                    .font(.caption)
                    .lineLimit(1)
                if let c = session?.messages.filter({ $0.role == .user }).count, c > 0 {
                    Text("\(c)")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                if let s = session, s.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Group {
                    if active { Color.accentColor.opacity(0.28) }
                    else { Color.white.opacity(0.12) }
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Color.accentColor.opacity(0.6) : .white.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let s = session { chat.togglePin(s.id) }
            } label: {
                Label(session?.isPinned == true ? "Unpin" : "Pin", systemImage: "pin")
            }
            Button {
                if let s = session { chat.archive(s.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Divider()
            Button(role: .destructive) {
                if let s = session { chat.delete(s.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Resizes the hosting window to the selected panel's preferred content size
/// so the app "auto-adjusts" when you switch features, instead of leaving the
/// window at whatever size the previous panel had. Clamps to the visible screen
/// frame so it never sizes the window off-screen.
private struct WindowAutoSizer: NSViewRepresentable {
    var panel: AppPanel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        applySize(to: view, animated: false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applySize(to: nsView, animated: true)
    }

    private func applySize(to nsView: NSView, animated: Bool) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let target = WindowAutoSizer.preferredSize(for: panel)
            guard target.width >= 600, target.height >= 500 else { return }
            let screen = window.screen ?? NSScreen.main
            let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            var rect = window.frame
            rect.size = NSSize(width: max(980, min(target.width, visible.width - 48)),
                               height: max(620, min(target.height, visible.height - 48)))
            // Keep the window's top-center anchored as it resizes.
            let x = rect.midX - rect.width / 2
            let top = max(visible.maxY - 64, rect.maxY)
            rect = NSRect(x: x, y: top - rect.height, width: rect.width, height: rect.height)
            if window.frame != rect {
                if animated {
                    window.setFrame(rect, display: true, animate: true)
                } else {
                    window.setFrame(rect, display: true)
                }
            }
        }
    }

    private static func preferredSize(for panel: AppPanel) -> NSSize {
        switch panel {
        case .chat:            return NSSize(width: 1280, height: 800)
        case .models:          return NSSize(width: 1180, height: 800)
        case .imageStudio:     return NSSize(width: 1150, height: 800)
        case .video:           return NSSize(width: 1100, height: 780)
        case .audio:           return NSSize(width: 1080, height: 820)
        case .musicStudio:     return NSSize(width: 1120, height: 860)
        case .taskGraph:       return NSSize(width: 1200, height: 820)
        default:               return NSSize(width: 1080, height: 760)
        }
    }
}

enum AppPanel: Hashable, Identifiable {
    case chat, models, imageStudio, video, audio, musicStudio, health, files,
         workspace, knowledge, automations, tasks, taskGraph, bots, activity, approvals, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .models: return "Models"
        case .imageStudio: return "Image Studio"
        case .video: return "Movie Studio"
        case .audio: return "Audio"
        case .musicStudio: return "Music Studio"
        case .health: return "Computer Health"
        case .files: return "Files"
        case .workspace: return "Workspace"
        case .knowledge: return "Skills & Knowledge"
        case .automations: return "Automations"
        case .tasks: return "Tasks"
        case .taskGraph: return "Run Inspector"
        case .bots: return "Bots"
        case .activity: return "Activity"
        case .approvals: return "Approvals"
        case .settings: return "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .chat: return "Multi-chat with local and web-assisted answers"
        case .models: return "Manage and download local models"
        case .imageStudio: return "Generate and remix images locally"
        case .video: return "Generate a full movie from a prompt"
        case .audio: return "Text-to-speech and transcription"
        case .musicStudio: return "Generate local music packs"
        case .health: return "Monitor this Mac's local resources"
        case .files: return "Browse connected files and folders"
        case .workspace: return "Browse the on-disk NexusAI Workspace"
        case .knowledge: return "Skills, knowledge base, and long-term memory"
        case .automations: return "Manage scheduled workflows"
        case .tasks: return "Track multi-step, approval-gated work"
        case .taskGraph: return "Plan, run, and inspect dependency-graph tasks"
        case .bots: return "Task-specific assistants you can attach to chats"
        case .activity: return "Review recent actions and events"
        case .approvals: return "Review actions waiting for permission"
        case .settings: return "Themes, profiles, and backends"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .models: return "square.stack.3d.up"
        case .imageStudio: return "photo.on.rectangle.angled"
        case .video: return "film"
        case .audio: return "waveform"
        case .musicStudio: return "music.note.house"
        case .health: return "waveform.path.ecg"
        case .files: return "folder"
        case .workspace: return "externaldrive.fill"
        case .knowledge: return "brain.head.profile"
        case .automations: return "clock.arrow.circlepath"
        case .tasks: return "checklist"
        case .taskGraph: return "point.3.connected.trianglepath.dotted"
        case .bots: return "sparkles"
        case .activity: return "list.bullet.rectangle"
        case .approvals: return "checkmark.shield"
        case .settings: return "gearshape"
        }
    }
}

extension View {
    func cardStyle() -> some View {
        let opacity = ThemeManager.shared.glassOpacity
        return self
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial.opacity(opacity), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
