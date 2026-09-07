import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Music Studio: generate a local "pack" — synthesized audio, procedural cover
/// art, and an optional Ken Burns video — from a single text prompt. Zero
/// external models: audio comes from `FastMusicGenerator`, cover art and video
/// are rendered on-device.
struct MusicStudioView: View {
    @ObservedObject var coordinator: MusicPackCoordinator
    @ObservedObject var mediaPlayer: MediaPlayer

    @State private var prompt = "A calm ambient electronic track for deep focus"
    @State private var genre: AudioMixer.Genre = .ambient
    @State private var duration: Double = 30
    @State private var quality: MusicPackQuality = .balanced
    @State private var includeVideo = true
    @State private var aspect: ImageAspect = .square

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controls
                if coordinator.isRunning {
                    progressSection
                }
                if let pack = coordinator.lastPack {
                    resultPack(pack)
                }
                if let error = coordinator.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .glassPanel()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Music Studio")
                .font(.title2.bold())
            Text("Generate a local music pack: audio, cover, and optional video — fully on-device.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt")
                .font(.subheadline.bold())
            TextEditor(text: $prompt)
                .frame(height: 80)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Genre")
                        .font(.subheadline.bold())
                    Picker("Genre", selection: $genre) {
                        ForEach(AudioMixer.Genre.allCases) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Duration")
                        .font(.subheadline.bold())
                    Picker("Duration", selection: $duration) {
                        Text("15 s").tag(15.0)
                        Text("30 s").tag(30.0)
                        Text("45 s").tag(45.0)
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality")
                        .font(.subheadline.bold())
                    Picker("Quality", selection: $quality) {
                        ForEach(MusicPackQuality.allCases) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            HStack {
                Toggle("Include video", isOn: $includeVideo)
                Spacer()
                Picker("Aspect", selection: $aspect) {
                    ForEach(ImageAspect.allCases) { a in
                        Text(a.rawValue).tag(a)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!includeVideo)
            }

            HStack {
                Spacer()
                if coordinator.isRunning {
                    Button("Stop", role: .destructive) {
                        coordinator.cancel()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Generate Pack") {
                        coordinator.generate(MusicPackSpec(
                            prompt: prompt,
                            genre: genre,
                            duration: duration,
                            quality: quality,
                            includeVideo: includeVideo,
                            aspect: aspect
                        ))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView(value: coordinator.progress)
                Text(String(format: "%.0f%%", coordinator.progress * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(coordinator.stage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resultPack(_ pack: MusicPack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generated Pack")
                .font(.subheadline.bold())

            HStack(alignment: .top, spacing: 16) {
                if let img = NSImage(contentsOf: pack.coverURL) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 10) {
                    // Audio
                    HStack(spacing: 8) {
                        Button {
                            if mediaPlayer.url != pack.audioURL || mediaPlayer.kind != .audio {
                                mediaPlayer.load(pack.audioURL, kind: .audio)
                            }
                            mediaPlayer.play()
                        } label: { Label("Play", systemImage: "play.fill") }
                        .disabled(mediaPlayer.isPlaying && mediaPlayer.url == pack.audioURL)

                        Button {
                            mediaPlayer.pause()
                        } label: { Label("Pause", systemImage: "pause.fill") }
                        .disabled(!(mediaPlayer.isPlaying && mediaPlayer.url == pack.audioURL))

                        Button {
                            mediaPlayer.stop()
                        } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(mediaPlayer.url != pack.audioURL)

                        if let loaded = mediaPlayer.url, loaded == pack.audioURL, mediaPlayer.duration > 0 {
                            Text(String(format: "%.1f / %.1f s",
                                        mediaPlayer.currentTime, mediaPlayer.duration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Video
                    if let videoURL = pack.videoURL {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Button {
                                    if mediaPlayer.url != videoURL || mediaPlayer.kind != .video {
                                        mediaPlayer.load(videoURL, kind: .video)
                                    }
                                    mediaPlayer.play()
                                } label: { Label("Play video", systemImage: "film") }
                                .buttonStyle(.bordered)

                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([videoURL])
                                } label: { Label("Reveal", systemImage: "folder") }
                                .buttonStyle(.bordered)
                            }
                            if mediaPlayer.kind == .video, mediaPlayer.url == videoURL,
                               let avPlayer = mediaPlayer.avPlayerForVideo() {
                                VideoPlayer(player: avPlayer)
                                    .frame(maxWidth: 360, minHeight: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }

                    // Save actions
                    HStack(spacing: 8) {
                        Button("Save Audio") { saveFile(pack.audioURL) }
                        Button("Save Cover") { saveFile(pack.coverURL) }
                        if let videoURL = pack.videoURL {
                            Button("Save Video") { saveFile(videoURL) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func saveFile(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.audio, .image, .movie]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }
}