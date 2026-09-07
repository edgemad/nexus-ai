import Foundation
import AVFoundation
import SwiftUI

/// Orchestrates a hands-free "talk to Nexie" round-trip: capture the mic,
/// transcribe with Whisper, run the reply through the chat/LLM, and speak the
/// answer aloud with the configured Jarvis voice.
@MainActor
final class VoiceConversationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    @Published private(set) var phase: Phase = .idle
    @Published var error: String?
    @Published private(set) var micReady = false
    @Published private(set) var recordingLevel: Float = -60

    private let speech: SpeechEngine
    private let chat: ChatStore
    private let settings = AssistantSettings.shared
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?

    init(speech: SpeechEngine, chat: ChatStore) {
        self.speech = speech
        self.chat = chat
    }

    var isActive: Bool { phase != .idle }

    var statusLabel: String {
        switch phase {
        case .idle: return ""
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        }
    }

    func toggle() {
        switch phase {
        case .idle: startListening()
        case .listening: stopAndProcess()
        default: break
        }
    }

    func stop() { stopAndProcess() }

    // MARK: - Recording

    private func startListening() {
        if micReady {
            beginRecording()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.micReady = granted
                if granted {
                    self?.beginRecording()
                } else {
                    self?.error = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                }
            }
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexie-voice-\(UUID().uuidString).wav")

        // Linear PCM WAV — no encoding step, Whisper-native, and avoids
        // AAC/USB-device issues that can produce silent files on macOS.
        let fmt: AudioFileTypeID = kAudioFileWAVEType
        let recordSettings: [String: Any] = [
            AVFormatIDKey:           kAudioFormatLinearPCM,
            AVSampleRateKey:         16_000,        // Whisper's preferred rate
            AVNumberOfChannelsKey:   1,             // mono
            AVLinearPCMBitDepthKey:  16,
            AVLinearPCMIsFloatKey:   false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: recordSettings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                self.error = "Audio capture did not start. Check System Settings > Sound > Input."
                return
            }
            recorder = rec
            recordingURL = url
            phase = .listening
            error = nil
            recordingLevel = -60
            startMetering()
        } catch {
            self.error = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let rec = self.recorder, rec.isRecording else { return }
                rec.updateMeters()
                let level = rec.averagePower(forChannel: 0)
                self.recordingLevel = level
            }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func stopAndProcess() {
        guard phase == .listening, let url = recordingURL else {
            discardRecording()
            return
        }
        recorder?.stop()
        recorder = nil
        stopMetering()
        phase = .thinking
        let captured = url
        Task {
            await process(captured)
        }
    }

    private func discardRecording() {
        recorder?.stop()
        recorder = nil
        stopMetering()
        recordingURL = nil
        if phase == .listening { phase = .idle }
    }

    // MARK: - Round trip

    private func process(_ url: URL) async {
        let (seconds, bytes) = audioSummary(of: url)
        if seconds < 0.4 || bytes < 500 {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
            phase = .idle
            error = "Recording too short (\(String(format: "%.1f", seconds))s, \(bytes) bytes). Hold the mic button while you speak."
            return
        }

        let transcribed = await speech.transcribeText(from: url)
        try? FileManager.default.removeItem(at: url)
        recordingURL = nil

        guard let question = transcribed, !question.isEmpty else {
            phase = .idle
            error = speech.error ?? "I didn't hear anything. Please try again."
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            chat.send(question) { [weak self] reply in
                Task { @MainActor in
                    self?.speakReply(reply)
                    cont.resume()
                }
            }
        }
        if phase == .thinking { phase = .idle }
    }

    private func speakReply(_ reply: String) {
        let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { phase = .idle; return }
        phase = .speaking
        let voice = settings.speakingVoice
        let speed = settings.effectiveSpeed
        if let suggestion = chat.proactiveSuggestion(afterReply: clean) {
            chat.injectSuggestion(suggestion)
        }
        Task {
            if let url = await speech.synthesize(clean, voice: voice, speed: speed) {
                speech.play(url)
                try? await Task.sleep(nanoseconds: UInt64(durationOf(url) * 1_000_000_000))
            }
            phase = .idle
        }
    }

    func cancelSpeaking() {
        phase = .idle
        speech.cancel()
    }

    // MARK: - Helpers

    private func durationOf(_ url: URL) -> Double {
        let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return seconds.isFinite && seconds > 0 ? seconds : 3.0
    }

    private func audioSummary(of url: URL) -> (Double, Int64) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return (seconds.isFinite && seconds > 0 ? seconds : 0, bytes)
    }
}
