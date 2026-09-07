import SwiftUI

struct SettingsView: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var profiles: ProfileStore
    @ObservedObject var backend: BackendManager
    @StateObject private var backups = BackupManager.shared
    @ObservedObject var cloud = CloudProviderStore.shared
    @ObservedObject var assistant = AssistantSettings.shared
    @ObservedObject private var diagnostics = Diagnostics.shared
    @ObservedObject private var updates = UpdateManager.shared
    @State private var chatLanguage = LanguageSettings.current
    @State private var showCreateProfile = false
    @State private var restoreTarget: BackupSnapshot?
    @State private var miniMaxKey = MiniMaxService.apiKey
    @State private var keyStatus: String? = MiniMaxService.isConfigured ? "Key saved. Verify it below." : nil

    @State private var newAllowlistCommand = ""
    @AppStorage("approval.ttlSeconds") private var approvalTTL = 600.0
    @AppStorage("approval.historyLimit") private var approvalHistoryLimit = 200
    @AppStorage("chat.exportSanitize") private var exportSanitize = true
    @AppStorage(DataTrim.retentionDaysKey) private var outputsRetentionDays = 0
    @AppStorage(DataTrim.maxOutputsMBKey) private var maxOutputsMB = 0
    @State private var trimResult: String?
    @State private var isChecking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                generalSection
                themeSection
                providersSection
                profileSection
                assistantSection
                workspaceSection
                backupsSection
                backendsSection
                diagnosticsSection
                updatesSection
                securitySection
                miniMaxSection
            }
            .padding(20)
        }
        .confirmationDialog(
            "Restore from \(restoreTarget?.createdAt.formatted() ?? "this snapshot")?",
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore and relaunch", role: .destructive) {
                restoreAndRelaunch()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showCreateProfile) {
            CreateProfileSheet(store: profiles)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.title2.bold())
                Text("Themes, profiles, workspace, and backend status.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General")
                .font(.headline)
            Toggle("Demo mode (loads sample activity, approvals, automations)", isOn: $assistant.demoMode)
                .controlSize(.small)
            Text("Off = a fresh install starts with genuinely empty stores. Your real data is never affected.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.headline)

            Text("Appearance")
                .font(.subheadline.bold())
            Picker("Appearance", selection: $theme.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Text("Accent color")
                .font(.subheadline.bold())
            HStack(spacing: 10) {
                ForEach(ThemeAccent.allCases) { a in
                    Button {
                        theme.accent = a
                    } label: {
                        Circle()
                            .fill(a.color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().stroke(
                                    theme.accent == a ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: theme.accent == a ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Accent: \(theme.accent.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Liquid glass transparency")
                .font(.subheadline.bold())
            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
                Slider(value: $theme.glassOpacity, in: 0.4...1.0)
                Text("\(Int(theme.glassOpacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            Text("Lower = more see-through glass. Higher = more frosted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                Button {
                    showCreateProfile = true
                } label: {
                    Label("New profile", systemImage: "person.badge.plus")
                }
                .controlSize(.small)
            }

            ForEach($profiles.profiles) { $profile in
                HStack(spacing: 10) {
                    Image(systemName: profile.iconName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .foregroundStyle(Color(hex: profile.accent) ?? .blue)

                    TextField("Name", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: profile.name) { newValue in
                            profiles.renameProfile(profile.id, to: newValue)
                        }

                    Picker("Detail", selection: $profile.detailLevel) {
                        ForEach(DetailLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    .onChange(of: profile.detailLevel) { newValue in
                        profiles.updateProfile(profile.id, detailLevel: newValue)
                    }

                    Menu {
                        ForEach(ProfileStore.iconChoices, id: \.self) { icon in
                            Button {
                                profiles.setIcon(profile.id, icon)
                            } label: {
                                Label(icon, systemImage: icon)
                            }
                        }
                    } label: {
                        Image(systemName: "paintbrush")
                    }
                    .menuStyle(.borderlessButton)

                    Button(role: .destructive) {
                        profiles.deleteProfile(profile.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }

            if profiles.profiles.count > 1 {
                HStack(spacing: 8) {
                    Text("Active:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(profiles.profiles) { p in
                        Button {
                            profiles.activeProfileID = p.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: p.iconName).font(.caption)
                                Text(p.name).font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(profiles.activeProfileID == p.id
                                        ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .cardStyle()
    }

    private var assistantSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice & style")
                .font(.headline)
            Text("How Nexie talks to you — both spoken replies and the tone of written answers.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Assistant style", selection: $assistant.styleRaw) {
                ForEach(AssistantStyle.allCases) { style in
                    Text(style.rawValue).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Divider().opacity(0.3)

            Text("Spoken (Jarvis) voice")
                .font(.subheadline.bold())
            Picker("Voice", selection: $assistant.jarvisVoice) {
                Text("Adam (US male)").tag("am_adam")
                Text("Michael (US male)").tag("am_michael")
                Text("Sarah (US female)").tag("af_sarah")
                Text("Nicole (US female)").tag("af_nicole")
                Text("Mac system voice").tag("Samantha")
            }
            .pickerStyle(.menu)

            HStack(spacing: 12) {
                Text("Speed: \(assistant.jarvisSpeed, specifier: "%.2fx")")
                    .font(.subheadline.bold())
                    .frame(width: 90, alignment: .leading)
                Slider(value: $assistant.jarvisSpeed, in: 0.8...1.5, step: 0.05)
            }

            Toggle("Faster voice responses (may sound a bit clipped)", isOn: $assistant.fastVoiceMode)
                .controlSize(.small)
        }
        .cardStyle()
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workspace")
                .font(.headline)
            HStack {
                Text(WorkspaceManager.shared.rootURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([WorkspaceManager.shared.rootURL])
                }
            }
        }
        .cardStyle()
    }

    private var backupsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Backups")
                        .font(.headline)
                    Text("Timestamped, checksum-verified snapshots of your stores. Restore rolls data back and relaunches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Toggle("Automatic backups", isOn: Binding(
                get: { backups.autoBackup },
                set: { backups.autoBackup = $0 }
            ))
            HStack(spacing: 10) {
                Text("Every")
                Picker("Interval", selection: Binding(
                    get: { backups.intervalHours },
                    set: { backups.intervalHours = $0 }
                )) {
                    Text("2 hours").tag(2.0)
                    Text("6 hours").tag(6.0)
                    Text("12 hours").tag(12.0)
                    Text("Daily").tag(24.0)
                }
                .pickerStyle(.segmented)
                Spacer()
                Text("Keep")
                Picker("Retention", selection: Binding(
                    get: { backups.retention },
                    set: { backups.retention = $0 }
                )) {
                    Text("4").tag(4)
                    Text("8").tag(8)
                    Text("16").tag(16)
                    Text("32").tag(32)
                }
                .pickerStyle(.segmented)
            }
            .font(.caption)

            HStack {
                Label(
                    backups.lastBackup.map { "Last backup \($0.formatted(.relative(presentation: .named)))" }
                        ?? "No backups yet",
                    systemImage: backups.lastBackup == nil ? "icloud.slash" : "checkmark.icloud.fill"
                )
                .font(.caption)
                Spacer()
                if let err = backups.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }

            HStack {
                Button {
                    _ = backups.backupNow(force: true)
                    backups.prune()
                } label: {
                    Label("Back up now", systemImage: "plus.rectangle.on.folder")
                }
                Spacer()
                if backups.isBackingUp {
                    ProgressView().controlSize(.small)
                }
            }

            if !backups.snapshots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(backups.snapshots) { snapshot in
                        HStack(spacing: 8) {
                            Image(systemName: "archivebox")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                Text("\(snapshot.fileCount) file(s) · \(ByteCountFormatter.string(fromByteCount: snapshot.totalBytes, countStyle: .file))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                restoreTarget = snapshot
                            }
                            .buttonStyle(.borderless)
                            Button {
                                backups.delete(snapshot: snapshot)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .cardStyle()
    }

    private func restoreAndRelaunch() {
        guard let target = restoreTarget else { return }
        restoreTarget = nil
        guard backups.restore(from: target) else { return }
        relaunchApp()
    }

    /// Restore writes files on disk but leaves in-memory stores stale, so the
    /// reliable path is a clean relaunch onto the restored data — the same
    /// dead-state recovery flow the app already exercises on startup.
    private func relaunchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private var backendsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backends")
                .font(.headline)
            HStack {
                backendStatus("llama", running: backend.llmRunning)
                backendStatus("image (sd)", running: backend.imageRunning)
                backendStatus("audio", running: backend.audioRunning)
                backendStatus("research", running: backend.sidecarHealthy(.research))
                backendStatus("memory", running: backend.sidecarHealthy(.memory))
                backendStatus("brain", running: backend.sidecarHealthy(.brain))
                Spacer()
                Button(backend.anyRunning ? "Stop" : "Start") {
                    if backend.anyRunning { backend.stopAll() } else { backend.startAll() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .cardStyle()
    }
    @ViewBuilder
    private func backendStatus(_ name: String, running: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(running ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(name).font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnostics")
                        .font(.headline)
                    Text("A quick health check of backends, workspace, and recent activity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                diagRow("LLM backend", ok: backend.llmRunning, detail: backend.llmRunning ? "running" : "stopped")
                diagRow("Image backend", ok: backend.imageRunning, detail: backend.imageRunning ? "running" : "stopped")
                diagRow("Audio backend", ok: backend.audioRunning, detail: backend.audioRunning ? "ready" : "stopped")
                diagRow("Research backend", ok: backend.sidecarHealthy(.research), detail: backend.sidecarHealthy(.research) ? "healthy (port \(backend.researchPort))" : "stopped (watchdog supervising)")
                diagRow("Memory backend", ok: backend.sidecarHealthy(.memory), detail: backend.sidecarHealthy(.memory) ? "healthy (port \(backend.memoryPort))" : "stopped (watchdog supervising)")
                diagRow("Brain backend", ok: backend.sidecarHealthy(.brain), detail: backend.sidecarHealthy(.brain) ? "healthy (port \(backend.brainPort))" : "stopped (watchdog supervising)")
                diagRow("Web search", ok: true, detail: "built-in (SearXNG-style)")
                diagRow("Cloud provider", ok: cloud.isConfigured(cloud.active), detail: cloud.effectiveProvider?.rawValue ?? "none")
                diagRow("Outputs disk", ok: outputsDiskOK, detail: outputsDiskDetail)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Button {
                    runSelfTest()
                } label: {
                    Label("Run self-test", systemImage: "bolt.fill")
                }
                Button(role: .destructive) {
                    clearCaches()
                } label: {
                    Label("Clear caches", systemImage: "trash")
                }
                Spacer()
                if let result = selfTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            reliabilityPanel
            sessionLogPanel

            HStack(spacing: 10) {
                Button {
                    exportDiagnostics()
                } label: {
                    Label("Export diagnostics", systemImage: "square.and.arrow.up")
                }
                Button {
                    NSWorkspace.shared.open(diagnostics.logDirectoryURL)
                } label: {
                    Label("Open log folder", systemImage: "folder")
                }
                Spacer()
                if let path = exportPath {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Phase 6: updates & security

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates & self-maintenance").font(.headline)
            HStack {
                Text("Installed")
                Spacer()
                Text("Nexie \(updates.currentVersion)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Latest available")
                Spacer()
                if let latest = updates.latestVersion {
                    Text(latest)
                        .foregroundStyle(updates.isUpdateAvailable ? .blue : .secondary)
                        .fontWeight(updates.isUpdateAvailable ? .semibold : .regular)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
            if updates.isCriticalUpdate {
                Label("Your version is below the supported minimum — please update.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button("Check for updates") {
                    updates.checkForUpdates()
                }
                if let checked = updates.lastCheckedAt {
                    Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let whatsNew = updates.whatsNewText {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's New in \(updates.currentVersion)")
                        .font(.caption)
                        .fontWeight(.semibold)
                    ForEach(whatsNew.components(separatedBy: "\n"), id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("On every launch the app detects a version change, forces a fresh backup, and verifies the newest snapshot's integrity before resuming normal work.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Security hardening").font(.headline)

            // Persistent allowlist
            Text("Approved commands").font(.subheadline)
            Text("Commands you add here run even if they match the destructive-command blocklist. They are never sent to the model — only you can run them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if CommandAllowlist.all.isEmpty {
                Text("No allowed commands yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(CommandAllowlist.all, id: \.self) { command in
                    HStack {
                        Text(command)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            CommandAllowlist.remove(command)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                TextField("e.g. rm -rf ~/tmp/fetch-cache", text: $newAllowlistCommand)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    CommandAllowlist.add(newAllowlistCommand)
                    newAllowlistCommand = ""
                }
                .disabled(newAllowlistCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider().padding(.vertical, 4)

            // Approval policy
            Stepper(value: $approvalTTL, in: 5...3600, step: 5) {
                Text("Approval timeout: \(Int(approvalTTL)) s")
            }
            .font(.caption)
            Stepper(value: $approvalHistoryLimit, in: 10...1000, step: 10) {
                Text("Approval history kept: \(approvalHistoryLimit) records")
            }
            .font(.caption)

            Toggle(isOn: $exportSanitize) {
                Text("Sanitize exports (masks API keys, JWTs, emails)")
                    .font(.caption)
            }

            Divider().padding(.vertical, 4)

            // Output retention
            Stepper(value: $outputsRetentionDays, in: 0...365, step: 1) {
                Text(outputsRetentionDays == 0
                     ? "Output retention: off"
                     : "Delete outputs older than \(outputsRetentionDays) days")
            }
            .font(.caption)
            Stepper(value: $maxOutputsMB, in: 0...10240, step: 100) {
                Text(maxOutputsMB == 0
                     ? "Output quota: off"
                     : "Keep outputs under \(maxOutputsMB) MB")
            }
            .font(.caption)
            HStack(spacing: 10) {
                Button("Trim now") {
                    let report = DataTrim.trim(at: WorkspaceManager.shared.rootURL)
                    trimResult = "Removed \(report.itemsRemoved) item(s), freed \(Int64(report.bytesReclaimed) / 1024) KB"
                }
                Button {
                    NSWorkspace.shared.open(WorkspaceManager.shared.rootURL.appendingPathComponent("Outputs"))
                } label: {
                    Label("Open Outputs", systemImage: "folder")
                }
                Spacer()
                if let trim = trimResult {
                    Text(trim)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    private var reliabilityPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reliability").font(.caption)
            let s = diagnostics.stats
            statRow("Launches", "\(s.launches)")
            statRow("Crashes (abnormal exits)", "\(s.crashes)")
            statRow("Session uptime", uptimeString)
            statRow("Blocked commands", "\(s.blockedCommands)")
            statRow("Shell timeouts", "\(s.shellTimeouts)")
            statRow("Cancelled commands", "\(s.shellCancellations)")
            statRow("Sidecar restarts", sidecarRespawnString)
            statRow("Backups taken", "\(s.backups)")
            statRow("Restores performed", "\(s.restores)")
            statRow("Stores migrated", "\(s.migrations)")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sessionLogPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Session log").font(.caption)
                Spacer()
                Button(showFullLog ? "Show recent" : "View full log") {
                    showFullLog.toggle()
                }
                .font(.caption2)
            }
            let recent = showFullLog
                ? Array(diagnostics.events.suffix(60).reversed())
                : Array(diagnostics.events.suffix(8).reversed())
            if recent.isEmpty {
                Text("No log entries yet — activity appears here as it happens.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recent) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(diagnosticsClock.string(from: event.ts))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(event.level.rawValue.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(levelColor(event.level))
                        Text(event.source)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(event.message)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @State private var showFullLog = false
    @State private var exportPath: String?

    private var uptimeString: String {
        let secs = Int(Date().timeIntervalSince(diagnostics.stats.sessionStart))
        return String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
    }

    private var sidecarRespawnString: String {
        let r = diagnostics.stats.sidecarRespawns
        let parts = ["research", "memory", "brain"].compactMap { kind -> String? in
            guard let n = r[kind], n > 0 else { return nil }
            return "\(kind): \(n)"
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    private var diagnosticsClock: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func statRow(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption2)
            Spacer()
            Text(value).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func exportDiagnostics() {
        let url = Diagnostics.shared.export(to: WorkspaceManager.shared.rootURL, sidecars: [
            "llm": backend.llmRunning,
            "image": backend.imageRunning,
            "audio": backend.audioRunning,
            "research": backend.sidecarHealthy(.research),
            "memory": backend.sidecarHealthy(.memory),
            "brain": backend.sidecarHealthy(.brain),
        ])
        if let url {
            exportPath = url.lastPathComponent
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            exportPath = "export failed"
        }
    }

    private func diagRow(_ name: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(name).font(.caption)
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var outputsDiskOK: Bool {
        let url = WorkspaceManager.shared.outputsURL
        let mib = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap { $0.volumeAvailableCapacityForImportantUsage }
            .map { Double($0) / (1024 * 1024) } ?? 0
        return mib > 500
    }

    private var outputsDiskDetail: String {
        let url = WorkspaceManager.shared.outputsURL
        let mib = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap { $0.volumeAvailableCapacityForImportantUsage }
            .map { Double($0) / (1024 * 1024) } ?? 0
        return mib > 0 ? String(format: "%.0f MB free", mib) : "unknown"
    }

    @State private var selfTestResult: String?

    private func runSelfTest() {
        var lines: [String] = []
        lines.append(backend.llmRunning ? "LLM: ok" : "LLM: stopped (start it)")
        lines.append(backend.imageRunning ? "Image: ok" : "Image: stopped")
        lines.append(backend.audioRunning ? "Audio: ok" : "Audio: stopped")
        lines.append(cloud.effectiveProvider != nil ? "Cloud: configured" : "Cloud: none (local only)")
        selfTestResult = lines.joined(separator: "  ")
    }

    private func clearCaches() {
        TempMediaCache.shared.clearAll()
        let outputs = WorkspaceManager.shared.outputsURL
        if let items = try? FileManager.default.contentsOfDirectory(
            at: outputs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for item in items {
                let name = item.lastPathComponent
                // Only remove obviously cache-like generated media, not chats/profiles.
                if name.lowercased().contains("tts") || name.lowercased().contains("stt")
                    || name.lowercased().contains("transcript") || name.lowercased().contains("recreate") {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }
        selfTestResult = "Caches cleared"
    }

    /// Cloud chat providers (OpenAI, Google, Claude, OpenRouter, custom) with
    /// per-provider API key + model + connection check — an Ollama-style way to
    /// plug a cloud brain into the Chat assistant while keeping local as default.
    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Providers")
                        .font(.headline)
                    Text("Connect a cloud model for the Chat assistant. Add an API key and check it connects — local (on-device) stays the default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("Provider", selection: $cloud.active) {
                ForEach(CloudProviderStore.Provider.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.menu)

            Picker("Reply language", selection: $chatLanguage) {
                ForEach(LanguageSettings.all) { l in
                    Text(l.name).tag(l)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: chatLanguage) { newValue in
                LanguageSettings.set(newValue)
            }

            if cloud.active == .local {
                Text("Using on-device models. Select a provider above to add a cloud API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                providerFields(cloud.active)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func providerFields(_ provider: CloudProviderStore.Provider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField("API key", text: Binding(
                get: { cloud.apiKey(for: provider) },
                set: { cloud.setApiKey($0, for: provider); cloud.status = nil }
            ))
            .textFieldStyle(.roundedBorder)

            if provider == .custom {
                TextField("Base URL (e.g. https://your-llm.xyz/v1)", text: Binding(
                    get: { cloud.baseURL(for: provider) },
                    set: { cloud.setBaseURL($0, for: provider) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Text("Model")
                .font(.subheadline.bold())
            TextField("Model name", text: Binding(
                get: { cloud.model(for: provider) },
                set: { cloud.setModel($0, for: provider) }
            ))
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button(cloud.checking ? "Checking…" : "Check connection") {
                    checkCloudConnection()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(cloud.checking)

                if let link = provider.keyLink {
                    Button("Get a key") { NSWorkspace.shared.open(link) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let status = cloud.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(noteColor(status))
            }
        }
    }

    private func checkCloudConnection() {
        Task {
            cloud.status = "Checking…"
            let result = await cloud.checkConnection()
            cloud.status = result ?? "✓ Connected — \(cloud.active.rawValue) is ready."
        }
    }

    /// Optional MiniMax H3 (cloud) video/audio integration. The rest of the
    /// app runs fully offline; enabling this unlocks the hosted H3 engine in
    /// the Movie Studio for real-motion video with native stereo audio.
    private var miniMaxSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MiniMax H3 (optional)")
                        .font(.headline)
                    Text("Hosted 2K video + native audio engine for the Movie Studio. Requires a MiniMax API key & network access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.small)
                }
            }

            SecureField("MiniMax API key", text: $miniMaxKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: miniMaxKey) { _ in
                MiniMaxService.apiKey = miniMaxKey
                keyStatus = nil
            }

            HStack(spacing: 10) {
                Button(isChecking ? "Checking…" : "Verify key") {
                    verifyKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking || miniMaxKey.trimmingCharacters(in: .whitespaces).isEmpty)

                if !MiniMaxService.isConfigured {
                    Button("Get a key") {
                        if let url = URL(string: "https://platform.minimaxi.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            if let keyStatus {
                Text(keyStatus)
                    .font(.caption)
                    .foregroundStyle(noteColor(keyStatus))
            }
        }
        .cardStyle()
    }

    private func noteColor(_ note: String) -> Color {
        note.lowercased().contains("ok") || note.lowercased().contains("valid") ? .green : .orange
    }

    private func verifyKey() {
        let trimmed = miniMaxKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { keyStatus = "Enter a key first."; return }
        MiniMaxService.apiKey = trimmed
        isChecking = true
        keyStatus = nil
        Task {
            let result = await MiniMaxService.validateKey()
            isChecking = false
            keyStatus = result ?? "✓ Key is valid."
        }
    }
}
/// Sheet used when creating a brand-new user profile (richer fields so the
/// assistant can personalize its replies to each person).
private struct CreateProfileSheet: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = "person.crop.circle.fill"
    @State private var accent = "4E9B6E"
    @State private var tagline = ""
    @State private var preferences = ""
    @State private var language = "English"
    @State private var detailLevel: DetailLevel = .normal

    private static let languages = ["English", "Spanish", "French", "German",
                                    "Italian", "Portuguese", "Japanese", "Chinese", "Other"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New profile")
                .font(.title3.bold())
            Text("Who is this? The assistant uses these details to personalize chats.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(Color(hex: accent) ?? .blue)
                    .frame(width: 44)
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
                        .frame(width: 34, height: 34)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)

                HStack(spacing: 8) {
                    ForEach(ProfileStore.accentChoices, id: \.self) { hex in
                        Button {
                            accent = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(
                                    accent == hex ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: accent == hex ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Tagline / role (optional)", text: $tagline)
                .textFieldStyle(.roundedBorder)
            Text("How do they like things? (optional)")
                .font(.subheadline.bold())
            TextEditor(text: $preferences)
                .frame(height: 80)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Picker("Preferred language", selection: $language) {
                ForEach(Self.languages, id: \.self) { Text($0) }
            }

            Picker("Answer detail level", selection: $detailLevel) {
                ForEach(DetailLevel.allCases) { level in
                    Text(level.rawValue).tag(level)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    store.createProfile(name: name, icon: icon, accent: accent,
                                        tagline: tagline, preferences: preferences,
                                        language: language, detailLevel: detailLevel)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((val >> 16) & 0xFF) / 255,
            green: Double((val >> 8) & 0xFF) / 255,
            blue: Double(val & 0xFF) / 255,
            opacity: 1
        )
    }
}
