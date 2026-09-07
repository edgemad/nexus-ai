import Foundation
import AppKit

/// Audio generation (text-to-speech) and transcription (speech-to-text)
/// backed by the local kokoro/whisper runtimes when present, with a reliable
/// macOS `say` fallback for TTS so audio generation always works.
///
/// Concurrency: every operation is stamped with an `operationID`. Starting a
/// new operation bumps the token and terminates the current process, and any
/// async (cloud) result that finishes with a stale token is discarded, so a
/// slow older request can never overwrite a newer result.
@MainActor
final class SpeechEngine: ObservableObject {
    @Published private(set) var isGeneratingAudio = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var preparationMessage: String?
    @Published private(set) var lastAudioURL: URL?
    /// In-memory copy of the newest generated audio (TTS). Kept so it can be
    /// played without ever being written to a persisted location.
    @Published private(set) var lastAudioData: Data?
    @Published private(set) var lastTranscription: String?
    @Published var error: String?

    private let backend: BackendManager
    /// The currently-running external process (say / kokoro / whisper), kept so
    /// "Stop" can terminate it immediately.
    private var currentProcess: Process?
    /// Monotonic operation guard. Bumped at the start of every operation and on
    /// cancel so stale async results are ignored.
    private var operationID = UUID()

    /// Marks the start of a new operation, invalidates any in-flight one, and
    /// terminates any running process. Returns the token to check with
    /// ``isCurrent(_:)`` before publishing results.
    private func beginOperation() -> UUID {
        let id = UUID()
        operationID = id
        currentProcess?.terminate()
        currentProcess = nil
        return id
    }

    /// True if `id` is the most recent operation token (i.e. its result may be
    /// published).
    private func isCurrent(_ id: UUID) -> Bool {
        operationID == id
    }

    /// Cancels any in-progress TTS or transcription by terminating the running
    /// process, invalidating the operation token, and returning to idle.
    func cancel() {
        operationID = UUID()
        currentProcess?.terminate()
        currentProcess = nil
        isGeneratingAudio = false
        isTranscribing = false
        isPreparingModel = false
    }

    init(backend: BackendManager) {
        self.backend = backend
    }

    // MARK: - Input normalization

    /// Trims surrounding whitespace and clamps to 20,000 characters. Returns
    /// nil when the input is empty or whitespace-only.
    private func normalizedText(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(20_000))
    }

    private func normalizedSpeed(_ speed: Double) -> Double {
        min(max(speed, 0.5), 2.0)
    }

    // MARK: - Text-to-Speech

    func speak(_ text: String, voice: String = "af_heart", speed: Double = 1.0,
               cloudVoice: String = "alloy", miniMaxVoice: String = "female-shaonv") {
        guard let cleanText = normalizedText(text) else { return }
        let id = beginOperation()
        let cleanSpeed = normalizedSpeed(speed)
        isGeneratingAudio = true
        error = nil

        let langCode = LanguageSettings.current.code

        // A locally-available kokoro voice → on-device engine (fast, offline).
        if SpeechEngine.isKokoroVoice(voice) {
            let outURL = TempMediaCache.shared.url(ext: "wav")
            if let (worker, runtime) = kokoroWorker(), let node = nodeURL() {
                runKokoro(id: id, node: node, worker: worker, runtime: runtime,
                          text: cleanText, voice: voice, speed: cleanSpeed, out: outURL) { ok in
                    guard self.isCurrent(id) else { return }
                    self.finish(ok: ok, out: outURL)
                }
            } else {
                isGeneratingAudio = false
                error = "Kokoro audio backend not found. Install Node.js or use a different voice."
            }
            return
        }

        // Any other voice → cloud if a provider is available, else macOS `say`.
        if MiniMaxService.isConfigured {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrent(id) else { return }
                let data = await MiniMaxService.TTS.speak(text: cleanText, voice: miniMaxVoice,
                                                          languageCode: langCode)
                guard self.isCurrent(id) else { return }
                let outURL = TempMediaCache.shared.url(ext: "mp3")
                guard let data else {
                    self.isGeneratingAudio = false
                    self.error = "The MiniMax provider returned no audio."
                    return
                }
                do {
                    try data.write(to: outURL, options: .atomic)
                    self.finish(ok: true, out: outURL)
                } catch {
                    self.isGeneratingAudio = false
                    self.error = "Could not save generated audio: \(error.localizedDescription)"
                }
            }
            return
        }
        if CloudTTSEngine.isConfigured {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrent(id) else { return }
                let outURL = TempMediaCache.shared.url(ext: "mp3")
                let data = await CloudTTSEngine.speak(text: cleanText, voice: cloudVoice, to: outURL)
                guard self.isCurrent(id) else { return }
                self.finish(ok: data != nil && FileManager.default.fileExists(atPath: outURL.path),
                            out: outURL)
            }
            return
        }

        // macOS `say` fallback.
        let aiffURL = TempMediaCache.shared.url(ext: "aiff")
        runSay(id: id, text: cleanText, voice: voice, speed: cleanSpeed, out: aiffURL) { ok in
            guard self.isCurrent(id) else { return }
            self.finish(ok: ok, out: aiffURL)
        }
    }

    private func finish(ok: Bool, out: URL) {
        currentProcess = nil
        isGeneratingAudio = false
        if ok && FileManager.default.fileExists(atPath: out.path) {
            lastAudioData = try? Data(contentsOf: out)
            lastAudioURL = out
        } else {
            lastAudioData = nil
            error = "Audio generation failed."
        }
    }

    /// Synthesizes speech and returns the generated audio URL (uses the kokoro
    /// engine when the voice is a kokoro voice, else the macOS `say` fallback).
    /// Used by the "recreate audio" pipeline so a produced clip can be chained
    /// into the genre remixer. Returns nil on failure or when cancelled.
    func synthesize(_ text: String, voice: String = "af_heart", speed: Double = 1.0) async -> URL? {
        guard let cleanText = normalizedText(text) else { return nil }
        let id = beginOperation()
        let cleanSpeed = normalizedSpeed(speed)
        isGeneratingAudio = true
        error = nil

        if let (worker, runtime) = kokoroWorker(), let node = nodeURL(),
           SpeechEngine.isKokoroVoice(voice) {
            let outURL = TempMediaCache.shared.url(ext: "wav")
            let done = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                runKokoro(id: id, node: node, worker: worker, runtime: runtime,
                          text: cleanText, voice: voice, speed: cleanSpeed, out: outURL) { ok in
                    cont.resume(returning: ok)
                }
            }
            guard isCurrent(id) else { return nil }
            isGeneratingAudio = false
            if done && FileManager.default.fileExists(atPath: outURL.path) {
                lastAudioData = try? Data(contentsOf: outURL)
                lastAudioURL = outURL
                return outURL
            }
            error = "Audio generation failed."
            return nil
        }

        let aiffURL = TempMediaCache.shared.url(ext: "aiff")
        let done = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            runSay(id: id, text: cleanText, voice: voice, speed: cleanSpeed, out: aiffURL) { ok in
                cont.resume(returning: ok)
            }
        }
        guard isCurrent(id) else { return nil }
        isGeneratingAudio = false
        if done && FileManager.default.fileExists(atPath: aiffURL.path) {
            lastAudioData = try? Data(contentsOf: aiffURL)
            lastAudioURL = aiffURL
            return aiffURL
        }
        error = "Audio generation failed."
        return nil
    }

    private func runSay(id: UUID, text: String, voice: String, speed: Double,
                        out: URL, completion: @escaping (Bool) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args = ["-v", voice, "-o", out.path, text]
        if speed != 1.0 {
            args.insert("-r", at: 0)
            args.insert("\(Int(180 * speed))", at: 1)
        }
        proc.arguments = args
        currentProcess = proc
        Task.detached { [weak self] in
            do {
                try proc.run()
                proc.waitUntilExit()
                if await !(self?.isCurrent(id) ?? false) { completion(false); return }
                completion(proc.terminationStatus == 0)
            } catch {
                completion(false)
            }
        }
    }

    private func kokoroWorker() -> (URL, URL)? {
        guard let root = backend.rootFolder else { return nil }
        let worker = root.appendingPathComponent("scripts/workers/tts-kokoro-worker.mjs")
        let runtime = root.appendingPathComponent("app/tts-runtime")
        guard FileManager.default.fileExists(atPath: worker.path),
              FileManager.default.fileExists(atPath: runtime.path) else { return nil }
        return (worker, runtime)
    }

    /// Resolves the Node.js executable. A packaged app launched from Finder may
    /// not inherit the shell PATH, so check common install locations rather than
    /// relying on `/usr/bin/env`.
    private func nodeURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Voice IDs the installed kokoro runtime ships (the .bin voice packs).
    /// macOS `say` voice names (Samantha/Alex/…) are NOT valid here — routing a
    /// non-kokoro voice to the worker makes it fail, so we detect and fall back
    /// to `say` for those.
    static let kokoroVoiceIDs: Set<String> = [
        "af_alloy","af_aoede","af_bella","af_heart","af_jessica","af_kore",
        "af_nicole","af_nova","af_river","af_sarah","af_sky",
        "am_adam","am_echo","am_eric","am_fenrir","am_liam","am_michael",
        "am_onyx","am_puck","am_santa",
        "bf_alice","bf_emma","bf_isabella","bf_lily",
        "bm_daniel","bm_fable","bm_george","bm_lewis",
        "ef_dora","em_alex","em_santa","ff_siwis",
        "hf_alpha","hf_beta","hm_omega","hm_psi",
        "if_sara","im_nicola",
        "jf_alpha","jf_gongitsune","jf_nezumi","jf_tebukuro","jm_kumo",
        "pf_dora","pm_alex","pm_santa",
        "zf_xiaobei","zf_xiaoni","zf_xiaoxiao","zf_xiaoyi",
        "zm_yunjian","zm_yunxi","zm_yunxia","zm_yunyang"
    ]

    static func isKokoroVoice(_ voice: String) -> Bool {
        kokoroVoiceIDs.contains(voice)
    }

    /// Runs the kokoro worker, which reads a JSON payload over stdin and writes
    /// the WAV to `output`. Requires TTS_RUNTIME to resolve kokoro-js. Process
    /// output is redirected to /dev/null to avoid pipe-buffer deadlocks.
    private func runKokoro(id: UUID, node: URL, worker: URL, runtime: URL, text: String,
                           voice: String, speed: Double, out: URL,
                           completion: @escaping (Bool) -> Void) {
        let proc = Process()
        proc.executableURL = node
        proc.arguments = [worker.path]

        var env = ProcessInfo.processInfo.environment
        env["TTS_RUNTIME"] = runtime.path
        proc.environment = env

        let stdin = Pipe()
        let nullURL = URL(fileURLWithPath: "/dev/null")
        let nullHandle = try? FileHandle(forWritingTo: nullURL)
        proc.standardInput = stdin
        proc.standardOutput = nullHandle
        proc.standardError = nullHandle
        currentProcess = proc

        let payload: [String: Any] = [
            "text": text,
            "voice": voice,
            "speed": speed,
            "modelId": "onnx-community/Kokoro-82M-v1.0-ONNX",
            "dtype": "q8",
            "output": out.path,
            "cacheDir": WorkspaceManager.shared.rootURL
                .appendingPathComponent("tts-cache").path
        ]

        Task.detached { [weak self] in
            do {
                try proc.run()
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    stdin.fileHandleForWriting.write(data)
                }
                stdin.fileHandleForWriting.closeFile()
                proc.waitUntilExit()
                if await !(self?.isCurrent(id) ?? false) { completion(false); return }
                completion(proc.terminationStatus == 0 &&
                           FileManager.default.fileExists(atPath: out.path))
            } catch {
                completion(false)
            }
        }
    }

    // MARK: - Speech-to-Text

    func transcribe(from url: URL) {
        guard let whisper = whisperCli(), FileManager.default.fileExists(atPath: url.path) else {
            error = "Whisper backend not found."
            return
        }
        let id = beginOperation()
        isTranscribing = true
        error = nil
        lastTranscription = nil

        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(id) else { return }
            // Make sure a whisper model is present (downloads it once if needed).
            self.isPreparingModel = true
            self.preparationMessage = "Preparing Whisper…"
            guard let model = await self.whisperModelPath(preparing: { phase in
                Task { @MainActor in
                    guard self.isCurrent(id) else { return }
                    self.preparationMessage = phase
                }
            }) else {
                self.isPreparingModel = false
                self.isTranscribing = false
                self.error = "Could not obtain a whisper model."
                return
            }
            self.isPreparingModel = false
            self.preparationMessage = "Transcribing audio…"

            let outBase = WorkspaceManager.shared.newOutputFolder()
                .appendingPathComponent("transcript-\(UUID().uuidString.lowercased())")
            let txtPath = outBase.path + ".txt"

            // Run Whisper off the main actor so the UI never freezes while a
            // long clip is being transcribed.
            let result = await Self.runProcess(
                executable: URL(fileURLWithPath: whisper),
                arguments: ["-m", model, "-f", url.path, "-otxt", "-of", outBase.path, "-nt"]
            )
            self.isTranscribing = false
            guard self.isCurrent(id) else { return }
            guard result.status == 0 else {
                self.error = "Whisper exited with code \(result.status)."
                return
            }
            let text = FileManager.default.fileExists(atPath: txtPath)
                ? (try? String(contentsOfFile: txtPath, encoding: .utf8)) ?? ""
                : ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self.error = "No speech was detected."
                return
            }
            self.lastTranscription = trimmed
        }
    }

    /// Transcribes an audio file to plain text (async). Used by the
    /// "recreate audio" pipeline and the voice conversation controller to turn a
    /// reference/recorded clip into text. Runs Whisper off the main actor so the
    /// UI stays responsive while a long clip is being processed.
    func transcribeText(from url: URL) async -> String? {
        guard let whisper = whisperCli(),
              FileManager.default.fileExists(atPath: url.path) else {
            error = "Whisper backend not found."
            return nil
        }
        let id = beginOperation()
        guard let model = await whisperModelPath() else {
            error = "Could not obtain a whisper model."
            return nil
        }
        guard isCurrent(id) else { return nil }
        let outBase = WorkspaceManager.shared.newOutputFolder()
            .appendingPathComponent("recreate-\(UUID().uuidString.lowercased())")
        let txtPath = outBase.path + ".txt"

        let result = await Self.runProcess(
            executable: URL(fileURLWithPath: whisper),
            arguments: ["-m", model, "-f", url.path, "-otxt", "-of", outBase.path, "-nt"]
        )
        guard isCurrent(id) else { return nil }
        guard result.status == 0,
              FileManager.default.fileExists(atPath: txtPath),
              let text = try? String(contentsOfFile: txtPath, encoding: .utf8) else {
            error = "Transcription failed."
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the whisper-cli binary path, if present.
    private func whisperCli() -> String? {
        guard let root = backend.rootFolder else { return nil }
        let p = root.appendingPathComponent("app/speech-backend/mac/cpu/whisper-cli")
        return FileManager.default.isExecutableFile(atPath: p.path) ? p.path : nil
    }

    /// Returns the whisper GGML model path. Auto-downloads a small model
    /// (ggml-base.bin, ~142MB) into app/speech-models on first use if absent.
    private func whisperModelPath(preparing: ((String) -> Void)? = nil) async -> String? {
        guard let root = backend.rootFolder else { return nil }
        let dir = root.appendingPathComponent("app/speech-models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           let first = files.first(where: { $0.hasSuffix(".bin") }) {
            return dir.appendingPathComponent(first).path
        }

        // Download ggml-base.bin if missing (network required on first use).
        let dest = dir.appendingPathComponent("ggml-base.bin")
        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin") else {
            return nil
        }
        do {
            preparing?("Downloading speech model…")
            // Stream to disk — never load the model into memory.
            let (tempURL, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            preparing?("Finalizing model…")
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    /// Pre-warms the audio stack in the background so the first transcription
    /// or speech request is fast: ensures the whisper model is downloaded &
    /// cached (only when whisper-cli is present). TTS is either the kokoro
    /// worker or the system `say`, both instantly ready.
    @discardableResult
    func prewarmAudio() async -> Bool {
        // Ensure STT model is cached if the whisper CLI exists.
        if whisperCli() != nil {
            _ = await whisperModelPath()
        }
        // Report overall readiness (TTS always available via say fallback).
        return true
    }

    /// Runs a system process off the main actor so the UI never freezes during
    /// Whisper or other long-running CLI invocations. The caller suspends via
    /// `await` and resumes on the main actor with the results.
    nonisolated private static func runProcess(
        executable: URL, arguments: [String]
    ) async -> (status: Int32, output: Data) {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (proc.terminationStatus, data)
        } catch {
            return (-1, Data())
        }
    }

    func play(_ url: URL) {
        NSSound(contentsOf: url, byReference: true)?.play()
    }
}
