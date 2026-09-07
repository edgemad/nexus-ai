import Foundation
import SwiftUI

/// Coordinates Gemini-style audio recreation in the Audio Studio, fully local:
///
/// 1. **Recreate audio** — take a reference clip, transcribe it (whisper),
///    re-synthesize it in a chosen voice (kokoro), then optionally re-style it
///    into a genre (AudioMixer DSP). One click turns a sample into a fresh,
///    re-voiced reproduction.
/// 2. **Enhance / remix** — re-master an existing file (clean bus: widening,
///    EQ, normalize + limiter) or re-shape it into a genre (existing remix).
/// 3. **Music from prompt** — procedurally synthesize an instrumental track
///    that matches the genre described in the prompt.
@MainActor
final class AudioStudioGenerator: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var transcript: String?
    @Published var error: String?

    private let engine: SpeechEngine
    private let mixer: AudioMixer
    /// In-flight operation task; kept so "Stop" can cancel it.
    private var generationTask: Task<Void, Never>?

    /// Cancels any in-progress audio operation (recreate/enhance/music) and
    /// returns the UI to idle.
    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        isProcessing = false
        error = nil
    }

    init() {
        self.engine = SpeechEngine(backend: BackendManager.shared)
        self.mixer = AudioMixer()
    }

    /// 1. Audio → text → fresh audio (optionally re-styled into a genre).
    func recreateAudio(from source: URL, voice: String, genre: AudioMixer.Genre, strength: Double) {
        guard !isProcessing else { return }
        guard FileManager.default.fileExists(atPath: source.path) else {
            error = "Reference audio file not found."
            return
        }
        isProcessing = true
        error = nil
        transcript = nil
        lastOutputURL = nil

        generationTask?.cancel()
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            // 1) Transcribe the reference.
            self.transcript = nil
            guard let text = await self.engine.transcribeText(from: source) else {
                self.isProcessing = false
                self.error = self.engine.error ?? "Could not transcribe the reference audio."
                return
            }
            self.transcript = text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.isProcessing = false
                self.error = "Reference audio contained no speech to recreate."
                return
            }

            // 2) Re-synthesize the transcript in the chosen voice.
            guard let reSynth = await self.engine.synthesize(text, voice: voice) else {
                self.isProcessing = false
                self.error = self.engine.error ?? "Could not re-synthesize the audio."
                return
            }

            // 3) Optionally re-style it into the target genre.
            if genre != .original {
                guard let styled = await self.mixer.renderToURL(source: reSynth, genre: genre, strength: strength) else {
                    self.lastOutputURL = reSynth
                    self.isProcessing = false
                    return
                }
                self.lastOutputURL = styled
            } else {
                self.lastOutputURL = reSynth
            }
            self.isProcessing = false
            self.generationTask = nil
        }
        generationTask = task
    }

    /// 2. Enhance an existing file (re-mastered reproduction).
    func enhance(_ source: URL) {
        guard !isProcessing else { return }
        guard FileManager.default.fileExists(atPath: source.path) else {
            error = "Audio file not found."
            return
        }
        isProcessing = true
        error = nil
        lastOutputURL = nil
        generationTask?.cancel()
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            let out = await self.mixer.enhance(source: source)
            self.lastOutputURL = out
            self.isProcessing = false
            self.generationTask = nil
            if out == nil { self.error = self.mixer.error ?? "Enhancement failed." }
        }
        generationTask = task
    }

    /// 3. Generate music from a text prompt (procedural, offline).
    func makeMusic(prompt: String, duration: Double) {
        guard !isProcessing else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Describe the music you want first."
            return
        }
        isProcessing = true
        error = nil
        lastOutputURL = nil
        generationTask?.cancel()
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            let out = await self.mixer.synthMusic(prompt: trimmed, duration: duration)
            self.lastOutputURL = out
            self.isProcessing = false
            self.generationTask = nil
            if out == nil { self.error = self.mixer.error ?? "Music generation failed." }
        }
        generationTask = task
    }
}
