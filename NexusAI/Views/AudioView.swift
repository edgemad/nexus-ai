import SwiftUI

struct AudioView: View {
    @ObservedObject var engine: SpeechEngine
    @ObservedObject var mixer: AudioMixer
    @ObservedObject var modelStore: ModelStore
    @ObservedObject var mediaPlayer: MediaPlayer
    @ObservedObject var generator: AudioStudioGenerator
    @State private var ttsText = "Welcome to Nexie. This audio was generated locally on your Mac."
    @State private var ttsVoice = "af_heart"
    @State private var recreateVoice = "af_heart"
    @State private var ttsSpeed = 1.0
    @State private var cloudVoice = "alloy"
    @State private var miniMaxVoice = "female-shaonv"
    @State private var language = LanguageSettings.current
    @State private var transcriptPath: URL?
    @State private var mixSource: URL?
    @State private var recreateSource: URL?
    @State private var recreateGenre: AudioMixer.Genre = .original
    @State private var recreateStrength = 0.8
    @State private var musicPrompt = "A chill ambient electronic track"
    @State private var mixGenre: AudioMixer.Genre = .rock
    @State private var mixStrength = 1.0

    /// Kokoro voices (local TTS) — an id used by the engine plus a friendly
    /// label. If kokoro isn't installed the engine falls back to macOS `say`.
    /// Fully offline and unlimited.
    private let voices: [(id: String, label: String)] = [
        ("af_heart", "Heart (US female)"),
        ("af_bella", "Bella (US female)"),
        ("af_nicole", "Nicole (US female)"),
        ("af_sarah", "Sarah (US female)"),
        ("af_sky", "Sky (US female)"),
        ("af_alloy", "Alloy (US female)"),
        ("af_jessica", "Jessica (US female)"),
        ("am_michael", "Michael (US male)"),
        ("am_adam", "Adam (US male)"),
        ("am_liam", "Liam (US male)"),
        ("am_onyx", "Onyx (US male)"),
        ("bm_george", "George (GB male)"),
        ("bf_emma", "Emma (GB female)"),
        ("bf_isabella", "Isabella (GB female)"),
        ("bm_daniel", "Daniel (GB male)"),
        ("am_echo", "Echo (US male)"),
        ("am_fenrir", "Fenrir (US male)"),
        ("am_puck", "Puck (US male)"),
        ("ef_dora", "Dora (ES female)"),
        ("em_alex", "Alex (ES male)"),
        ("ff_siwis", "Siwis (FR female)"),
        ("jf_alpha", "Alpha (JA female)"),
        ("zm_yunxi", "Yunxi (ZH male)"),
        ("zf_xiaobei", "Xiaobei (ZH female)")
    ]

    /// A reusable image-model picker shown at the top of the studio so the
    /// active checkpoint drives image generation from any studio.
    private var imageModelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Image model")
                .font(.subheadline.bold())
            Picker("Image model", selection: Binding(
                get: { modelStore.selectedImageModelPath ?? "" },
                set: { newValue in
                    if !newValue.isEmpty {
                        modelStore.selectImageModel(newValue)
                    }
                }
            )) {
                Text("None selected").tag("")
                ForEach(modelStore.installedImageModels, id: \.self) { path in
                    Text((path as NSString).lastPathComponent)
                        .tag(path)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            if modelStore.selectedImageModelPath == nil {
                Text("No image model installed. Add one in Models to generate images.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                HStack(alignment: .top, spacing: 16) {
                    ttsPanel
                    sttPanel
                }

                recreatePanel

                musicPanel

                mixerPanel
            }
            .padding(20)
        }
    }

    private var mixerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Audio Mixer & Genre Remix")
                    .font(.headline)
                Spacer()
                if mixer.isProcessing {
                    ProgressView().controlSize(.small)
                }
            }
            Text("Pick a song or audio clip, choose a target genre, and Nexie will re-shape its tempo, tone and drive — e.g. a ballad reworked as rock, soul, or gospel. Fully local and offline.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                // Source file
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Choose audio file")
                        .font(.subheadline.bold())
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.audio, .movie]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            mixSource = url
                        }
                    } label: {
                        Label(mixSource?.lastPathComponent ?? "Choose audio file…",
                              systemImage: "music.note.list")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)

                    // 2. Genre
                    Text("2. Target genre")
                        .font(.subheadline.bold())
                    Picker("Genre", selection: $mixGenre) {
                        ForEach(AudioMixer.Genre.allCases) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.menu)

                    // 3. Strength
                    Text("3. Effect strength: \(Int(mixStrength * 100))%")
                        .font(.subheadline.bold())
                    Slider(value: $mixStrength, in: 0...1)

                    Button {
                        if let url = mixSource {
                            mixer.mix(source: url, genre: mixGenre, strength: mixStrength)
                        }
                    } label: {
                        Label("Mix / remix", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(mixer.isProcessing || mixSource == nil)

                    if mixer.isProcessing {
                        Button {
                            mixer.cancel()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                    }

                    Button {
                        if let url = mixSource {
                            generator.enhance(url)
                        }
                    } label: {
                        Label("Enhance", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(generator.isProcessing || mixSource == nil)

                    if let err = mixer.error {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }

                // Result
                VStack(alignment: .leading, spacing: 8) {
                    Text("Result")
                        .font(.subheadline.bold())
                    if mixer.isProcessing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Mixing \(mixGenre.rawValue)… \(Int(mixer.progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let url = mixer.lastMixURL {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Mixed output")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            transportButtons(for: url, kind: .audio)
                            HStack(spacing: 10) {
                                Button("Download…") { download(url) }
                            }
                        }
                    } else {
                        Text("Mixed output appears here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Gemini-style "recreate audio": reference clip → transcribed → re-voiced
    /// → optionally re-styled into a genre. One-click audio-to-audio.
    private var recreatePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recreate Audio")
                    .font(.headline)
                Spacer()
                if generator.isProcessing {
                    ProgressView().controlSize(.small)
                }
            }
            Text("Pick a reference audio clip. Nexie transcribes it, re-speaks it in your chosen voice, and can re-shape it into a genre — a fresh recreation of the original, fully local.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Reference audio")
                        .font(.subheadline.bold())
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.audio, .movie]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            recreateSource = url
                        }
                    } label: {
                        Label(recreateSource?.lastPathComponent ?? "Choose reference audio…",
                              systemImage: "waveform.path.ecg")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)

                    Text("2. Voice")
                        .font(.subheadline.bold())
                    Picker("Voice", selection: $recreateVoice) {
                        ForEach(voices, id: \.id) { v in
                            Text(v.label).tag(v.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("3. Genre re-style")
                        .font(.subheadline.bold())
                    Picker("Genre", selection: $recreateGenre) {
                        ForEach(AudioMixer.Genre.allCases) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("4. Style strength: \(Int(recreateStrength * 100))%")
                        .font(.subheadline.bold())
                    Slider(value: $recreateStrength, in: 0...1)

                    Button {
                        if let src = recreateSource {
                            generator.recreateAudio(from: src, voice: recreateVoice,
                                                    genre: recreateGenre, strength: recreateStrength)
                        }
                    } label: {
                        Label("Recreate audio", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(generator.isProcessing || recreateSource == nil)

                    if generator.isProcessing {
                        Button {
                            generator.cancel()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                    }

                    if let err = generator.error {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Output")
                        .font(.subheadline.bold())
                    if let text = generator.transcript {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Transcript")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(text)
                                .font(.caption2)
                                .textSelection(.enabled)
                                .lineLimit(4)
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let url = generator.lastOutputURL {
                        transportButtons(for: url, kind: .audio)
                        HStack(spacing: 10) {
                            Button("Download…") { download(url) }
                        }
                    } else {
                        Text("Recreated audio appears here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Gemini-style "music / sound from a prompt": procedurally synthesized
    /// instrumental track matched to the genre described. Fully offline.
    private var musicPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Music from Prompt")
                    .font(.headline)
                Spacer()
                if generator.isProcessing {
                    ProgressView().controlSize(.small)
                }
            }
            Text("Describe the music you want — e.g. \"an upbeat pop song\" or \"a calm ambient pad\" — and Nexie synthesizes a matching instrumental track from scratch. Fully local and offline.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $musicPrompt)
                .frame(height: 60)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Button {
                    generator.makeMusic(prompt: musicPrompt, duration: 14)
                } label: {
                    Label("Generate music", systemImage: "music.note")
                }
                .buttonStyle(.borderedProminent)
                .disabled(generator.isProcessing || musicPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if generator.isProcessing {
                    Button {
                        generator.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }

                if let url = generator.lastOutputURL {
                    transportButtons(for: url, kind: .audio)
                    Button("Download…") { download(url) }
                }
            }
            if let err = generator.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Studio")
                    .font(.title2.bold())
                Text("Generate speech and transcribe audio with local backends, macOS voices, or optional cloud providers.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            imageModelPicker
        }
    }

    /// Play / pause / stop transport buttons bound to the shared media player.
    private func transportButtons(for url: URL, kind: MediaPlayer.Kind) -> some View {
        HStack(spacing: 8) {
            Button {
                if mediaPlayer.url != url {
                    mediaPlayer.load(url, kind: kind)
                }
                mediaPlayer.play()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(mediaPlayer.isPlaying && mediaPlayer.url == url)

            Button {
                mediaPlayer.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(!(mediaPlayer.isPlaying && mediaPlayer.url == url))

            Button {
                mediaPlayer.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(mediaPlayer.url != url)
        }
    }

    /// Saves (downloads) a produced file to a user-chosen location rather than
    /// just leaving it in the workspace Outputs folder.
    private func download(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    /// Opt-in save of an in-memory generated audio clip to a user-chosen
    /// location (the clip is never autosaved to disk otherwise).
    private func saveAudioData(_ data: Data) {
        let panel = NSSavePanel()
        panel.title = "Save generated audio"
        panel.allowedContentTypes = [.audio]
        panel.nameFieldStringValue = "NexusAI-\(Int(Date().timeIntervalSince1970)).mp3"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private var ttsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text-to-Speech (generate audio)")
                .font(.headline)

            TextEditor(text: $ttsText)
                .frame(height: 110)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Picker("Voice", selection: $ttsVoice) {
                    ForEach(voices, id: \.id) { v in
                        Text(v.label).tag(v.id)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    engine.speak("This is a preview of the selected voice.", voice: ttsVoice,
                                 speed: ttsSpeed, cloudVoice: cloudVoice,
                                 miniMaxVoice: miniMaxVoice)
                } label: {
                    Label("Preview", systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
                .disabled(engine.isGeneratingAudio)
            }

            Picker("Language", selection: $language) {
                ForEach(LanguageSettings.all) { l in
                    Text(l.name).tag(l)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: language) { newValue in
                LanguageSettings.set(newValue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Speed: \(ttsSpeed, specifier: "%.2fx")")
                    .font(.subheadline.bold())
                Slider(value: $ttsSpeed, in: 0.5...2.0, step: 0.05)
            }

            HStack {
                Text("Kokoro includes several multilingual voices, but natural Filipino/Tagalog coverage may be limited. For Filipino audio, use a configured cloud provider or import an audio file into the Mixer panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(ttsText.count)/20,000 characters")
                    .font(.caption2)
                    .foregroundStyle(ttsText.count > 20_000 ? .red : .secondary)
            }

            Text("If a cloud provider is configured, the entered text is sent to that third party for synthesis.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Button {
                    engine.speak(ttsText, voice: ttsVoice, speed: ttsSpeed,
                                 cloudVoice: cloudVoice, miniMaxVoice: miniMaxVoice)
                } label: {
                    Label("Generate audio", systemImage: "speaker.wave.2")
                }
                .buttonStyle(.borderedProminent)
                .disabled(ttsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if engine.isGeneratingAudio {
                    Button {
                        engine.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                    ProgressView().controlSize(.small)
                }
            }

            if let data = engine.lastAudioData {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button {
                            mediaPlayer.loadAudio(data)
                            mediaPlayer.play()
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        Button {
                            mediaPlayer.pause()
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .disabled(!mediaPlayer.isPlaying)
                        Button {
                            mediaPlayer.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                    Button("Save audio…") {
                        if let data = engine.lastAudioData { saveAudioData(data) }
                    }
                }
            }
            if let err = engine.error { Text(err).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var sttPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech-to-Text (transcribe)")
                .font(.headline)

            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio, .movie]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    transcriptPath = url
                    engine.transcribe(from: url)
                }
            } label: {
                Label(transcriptPath == nil ? "Choose audio file…" :
                        (transcriptPath!.lastPathComponent), systemImage: "waveform")
            }
            .buttonStyle(.bordered)

            if engine.isPreparingModel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(engine.preparationMessage ?? "Preparing…")
                    Button {
                        engine.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }
            } else if engine.isTranscribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                    Button {
                        engine.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }
            }

            if let text = engine.lastTranscription {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcription")
                        .font(.subheadline.bold())
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if let err = engine.error { Text(err).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
