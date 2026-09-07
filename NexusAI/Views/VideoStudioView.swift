import SwiftUI
import AVKit

/// Movie Studio: turns a single text prompt into a locally-rendered movie.
/// Keyframes are generated with the Stable Diffusion backend, then animated
/// (Ken Burns + crossfades) and given an ambient audio track before being
/// exported as H.264 QuickTime.
struct VideoStudioView: View {
    @ObservedObject var generator: VideoGenerator
    @ObservedObject var modelStore: ModelStore
    @ObservedObject var mediaPlayer: MediaPlayer
    @State private var prompt = "A lighthouse on a rocky shore during a slow aurora night, cinematic, epic scale"
    @State private var negative = ""
    @State private var keyframes = 6
    @State private var durationPerScene = 4.0
    @State private var fps = 30
    @State private var quality = 1
    @State private var withMusic = true

    private let qualities: [(label: String, steps: Int, res: (Int, Int))] = [
        ("Good", 18, (960, 540)),
        ("High", 26, (1280, 720)),
        ("Ultra", 34, (1920, 1080))
    ]
    @State private var miniMaxEngine = false
    @AppStorage(MiniMaxService.apiKeyKey) private var miniMaxKey = ""
    @State private var miniMaxDraftKey = ""
    @State private var miniMaxChecking = false
    @State private var miniMaxStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                HStack(alignment: .top, spacing: 16) {
                    composer
                    previewPanel
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Movie Studio")
                    .font(.title2.bold())
                Text("Generate a real video from a prompt — keyframes, Ken Burns motion, and a synthesized score, all on-device.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            imageModelPicker
        }
    }

    /// A menu that switches the active image checkpoint used by the movie
    /// studio's keyframe generator.
    private var imageModelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Image model")
                .font(.subheadline.bold())
            Picker("Image model", selection: Binding(
                get: { modelStore.selectedImageModelPath ?? "" },
                set: { newValue in
                    if !newValue.isEmpty { modelStore.selectImageModel(newValue) }
                }
            )) {
                Text("None selected").tag("")
                ForEach(modelStore.installedImageModels, id: \.self) { path in
                    Text((path as NSString).lastPathComponent).tag(path)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
        }
    }

    /// Play / pause / stop bound to the shared media player.
    private func transportButtons(for url: URL) -> some View {
        HStack(spacing: 8) {
            Button {
                if mediaPlayer.url != url { mediaPlayer.load(url, kind: .video) }
                mediaPlayer.play()
            } label: { Label("Play", systemImage: "play.fill") }
            .disabled(mediaPlayer.isPlaying && mediaPlayer.url == url)

            Button {
                mediaPlayer.pause()
            } label: { Label("Pause", systemImage: "pause.fill") }
            .disabled(!(mediaPlayer.isPlaying && mediaPlayer.url == url))

            Button {
                mediaPlayer.stop()
            } label: { Label("Stop", systemImage: "stop.fill") }
            .disabled(mediaPlayer.url != url)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt")
                .font(.headline)
            TextEditor(text: $prompt)
                .frame(height: 70)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))

            Text("Negative prompt")
                .font(.headline)
            TextField("Things to avoid…", text: $negative)
                .textFieldStyle(.roundedBorder)

            Picker("Quality", selection: $quality) {
                ForEach(qualities.indices, id: \.self) { i in
                    Text(qualities[i].label).tag(i)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Use MiniMax H3 (cloud)", isOn: $miniMaxEngine)
                .font(.subheadline.bold())
                .help("Render with the hosted MiniMax H3 engine (real motion + native stereo audio) instead of the on-device Ken Burns pipeline.")

            if miniMaxEngine {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Native motion + stereo audio. Add a MiniMax API key below to connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // API key + connection check (Ollama-style).
                    SecureField(MiniMaxService.isConfigured ? "••••••••••••  (key saved)" : "MiniMax API key", text: $miniMaxDraftKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: miniMaxDraftKey) { _ in miniMaxStatus = nil }

                    HStack(spacing: 8) {
                        Button {
                            saveAndCheckKey()
                        } label: {
                            Label(miniMaxChecking ? "Checking…" : (MiniMaxService.isConfigured ? "Save & check" : "Save & check connection"),
                                  systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(miniMaxChecking)

                        if !MiniMaxService.isConfigured {
                            Button("Get a key") {
                                if let url = URL(string: "https://platform.minimaxi.com") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if let miniMaxStatus {
                        Text(miniMaxStatus)
                            .font(.caption)
                            .foregroundStyle(miniMaxStatus.localizedCaseInsensitiveContains("ok")
                                             || miniMaxStatus.localizedCaseInsensitiveContains("valid") ? .green : .orange)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onAppear { miniMaxDraftKey = "" }
            } else {
                Text("Renders on-device. Toggle on to use MiniMax H3 for real motion + stereo audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Stepper("Scenes: \(keyframes)", value: $keyframes, in: 2...10)
            HStack {
                Stepper("Seconds / scene: \(durationPerScene, specifier: "%.1f")",
                        value: $durationPerScene, in: 2...10, step: 0.5)
            }
            Picker("Frame rate", selection: $fps) {
                Text("24 fps").tag(24)
                Text("30 fps").tag(30)
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $withMusic) {
                Label("Ambient soundtrack", systemImage: "music.note")
            }

            Button {
                generate()
            } label: {
                Label("Generate movie", systemImage: "film")
            }
            .buttonStyle(.borderedProminent)
            .disabled(generator.isGenerating)

            if generator.isGenerating {
                Button {
                    generator.cancel()
                } label: {
                    Label("Stop generating", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                .disabled(!generator.isGenerating)
            }
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.headline)
            Group {
                if let avPlayer = mediaPlayer.avPlayerForVideo(), mediaPlayer.kind == .video {
                    VideoPlayer(player: avPlayer)
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "film.stack")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("Generated movie appears here")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        )
                }
            }
            if generator.isGenerating {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(generator.stage) · \(Int(generator.progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: generator.progress)
            }
            if let movie = generator.lastMovieURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text((movie as NSURL).lastPathComponent ?? "movie.mov")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    transportButtons(for: movie)
                    HStack(spacing: 10) {
                        Button("Download…") { download(movie) }
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([movie])
                        }
                    }
                }
            }
            if let note = generator.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let err = generator.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func generate() {
        let q = qualities[quality]
        generator.generate(.init(engine: miniMaxEngine ? .miniMax : .local,
                                 prompt: prompt,
                                 negative: negative.isEmpty ? "blurry, low quality, distorted, watermark, text" : negative,
                                 keyframes: keyframes,
                                 fps: fps,
                                 durationPerScene: durationPerScene,
                                 width: q.res.0,
                                 height: q.res.1,
                                 steps: q.steps,
                                 withMusic: withMusic))
    }

    /// Saves the typed MiniMax API key and verifies it connects to the H3
    /// backend, reporting the result inline (Ollama-style "check connection").
    private func saveAndCheckKey() {
        let trimmed = miniMaxDraftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            MiniMaxService.apiKey = trimmed
        }
        guard MiniMaxService.isConfigured else {
            miniMaxStatus = "Enter a MiniMax API key to connect."
            return
        }
        miniMaxChecking = true
        miniMaxStatus = nil
        Task {
            let result = await MiniMaxService.validateKey()
            miniMaxChecking = false
            miniMaxStatus = result ?? "✓ Connected — MiniMax H3 is ready."
        }
    }

    /// Saves (downloads) the produced movie to a user-chosen location.
    private func download(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }
}