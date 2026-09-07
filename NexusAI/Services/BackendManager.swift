import Foundation
import SwiftUI

/// Shared per-launch token for the local Python sidecars. Generated once per
/// process, injected into each sidecar's environment at spawn, and sent as an
/// `Authorization: Bearer` header by every Swift client. `/health` stays open
/// (liveness probes); data + control endpoints require the token.
enum SidecarAuth {
    static let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

enum BackendKind: String, CaseIterable, Identifiable {
    case text = "Text (LLM)"
    case image = "Image (SD)"
    case speech = "Speech (Whisper)"
    case tts = "Audio (TTS)"
    case research = "Research (web)"
    case memory = "Memory"
    case brain = "Brain"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .text: return "bubble.left.and.bubble.right"
        case .image: return "photo"
        case .speech: return "waveform"
        case .tts: return "speaker.wave.2"
        case .research: return "globe"
        case .memory: return "brain"
        case .brain: return "cpu"
        }
    }
}

@MainActor
final class BackendManager: ObservableObject {
    @Published private(set) var states: [BackendKind: BackendState] = [:]
    @Published var rootFolder: URL?
    @Published var statusMessage = ""
    /// The audio stack (STT whisper-cli + kokoro TTS runtime) is self-contained
    /// and available to serve. Used instead of a "running process" check because
    /// whisper/kokoro are one-shot CLI tools that exit after each request.
    @Published private(set) var audioReady = false

    /// Live health (HTTP /health probe) of the three Python sidecars, refreshed
    /// by the watchdog. More truthful than `process.isRunning` because it also
    /// detects wedged or externally-started processes.
    @Published private(set) var researchHealthy = false
    @Published private(set) var memoryHealthy = false
    @Published private(set) var brainHealthy = false

    /// True when a healthy llama-server is answering on the text port, whether
    /// we spawned it this session or adopted one orphaned by a previous app
    /// instance (a hard kill never runs the clean-terminate handler, so its
    /// children survive the parent). Adoption stops us double-binding :8080.
    @Published private(set) var llmHealthy = false
    private var adoptedLLM = false

    /// Watchdog bookkeeping: consecutive failed probes before a respawn, and
    /// the periodic supervision task itself.
    private var unhealthyCounts: [BackendKind: Int] = [:]
    private var watchdogTask: Task<Void, Never>?

    struct BackendState {
        var process: Process?
        var port: Int
        var path: String?
    }

    private var llmStartedForModel: String?
    private var llmPausedForImages = false
    private var imageStartedForModel: String?
    private var imageLogHandle: FileHandle?

    /// Shared backend manager so all views reference the same processes.
    @MainActor static let shared = BackendManager()

    private init() {
        for kind in BackendKind.allCases {
            states[kind] = BackendState(process: nil, port: 0, path: nil)
        }
        detectRoot()
    }

    var llamaPort: Int { states[.text]?.port ?? 8080 }

    /// Port and URL of the pure-Python web-research sidecar.
    /// The state port is 0 until assigned, so treat 0 as "use the default".
    var researchPort: Int {
        let p = states[.research]?.port ?? 0
        return p > 0 ? p : 8765
    }
    var researchURL: URL { URL(string: "http://127.0.0.1:\(researchPort)")! }
    var researchRunning: Bool { states[.research]?.process?.isRunning == true }

    /// Port and URL of the pure-Python memory/knowledge sidecar.
    var memoryPort: Int {
        let p = states[.memory]?.port ?? 0
        return p > 0 ? p : 8766
    }
    var memoryURL: URL { URL(string: "http://127.0.0.1:\(memoryPort)")! }
    var memoryRunning: Bool { states[.memory]?.process?.isRunning == true }

    /// Port and URL of the pure-Python routing/intent sidecar.
    var brainPort: Int {
        let p = states[.brain]?.port ?? 0
        return p > 0 ? p : 8767
    }
    var brainURL: URL { URL(string: "http://127.0.0.1:\(brainPort)")! }
    var brainRunning: Bool { states[.brain]?.process?.isRunning == true }

    /// UI-visible sidecar health (probe-based, refreshed by the watchdog).
    func sidecarHealthy(_ kind: BackendKind) -> Bool {
        switch kind {
        case .research: return researchHealthy
        case .memory: return memoryHealthy
        case .brain: return brainHealthy
        default: return false
        }
    }

    // MARK: - Root detection

    func setRoot(_ url: URL) {
        rootFolder = url
    }

    private func detectRoot() {
        // The workspace folder holds the bundled backends (sd, llama) and the
        // models directory. Prefer it so model downloads + backend launching use
        // one reliable, writable location instead of a stale external volume path.
        let workspace = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("NexusAI Workspace", isDirectory: true)
        let candidates = [
            workspace,
            URL(fileURLWithPath: "/Volumes/1TBex/Uncensored-Local-Studio-main"),
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("NexusAI/backends")
        ]
        for c in candidates {
            if let c, FileManager.default.fileExists(atPath: c.path) {
                rootFolder = c
                break
            }
        }
        // If no candidate existed yet, fall back to the workspace and create it.
        if rootFolder == nil {
            try? FileManager.default.createDirectory(at: workspace,
                                                     withIntermediateDirectories: true)
            rootFolder = workspace
        }
    }

    // MARK: - Path resolution

    private func llmBackendDir() -> URL? {
        guard let root = rootFolder else { return nil }
        let dir = root.appendingPathComponent("app/llm-backend/mac/arm64")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    private func modelsDir() -> URL? {
        guard let root = rootFolder else { return nil }
        let dir = root.appendingPathComponent("app/llm-models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Text backend (llama-server)

    func startOrEnsureLLM(modelPath: String?) {
        guard let backendDir = llmBackendDir(),
              let server = backendDir.appendingPathComponent("llama-server") as URL?,
              FileManager.default.isExecutableFile(atPath: server.path) else {
            statusMessage = "llama-server not found."
            return
        }

        if let proc = states[.text]?.process, proc.isRunning,
           llmStartedForModel == modelPath {
            return
        }

        // Self-heal from a previous hard kill: a healthy llama-server may
        // already be serving on :8080 (orphaned by the dead instance). Adopt it
        // so the UI reports running and we don't spawn a duplicate. Only adopt
        // when the requested model matches what we have tracked, or nothing was
        // requested at all.
        if adoptHealthyLLM(desired: modelPath) {
            statusMessage = "Adopted existing llama-server on port 8080"
            Diagnostics.shared.record(.warn, source: "sidecars",
                                      "adopted orphaned llama-server on port 8080 (healthy)")
            return
        }

        // The existing server is not healthy (or a different model is being
        // selected): stop the stale listener, then start clean.
        killLLMListener()
        states[.text]?.process?.terminate()
        states[.text]?.process?.waitUntilExit()
        states[.text] = nil

        let model = modelPath ?? findDefaultModel()
        guard let model else {
            statusMessage = "No text model selected. Choose one in Models."
            return
        }

        let port = 8080
        let mmproj = projectorPath(for: model)

        let proc = Process()
        var args = [
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "-m", model,
            "-c", "8192",
            "-fa", "on",
            "-ngl", "99"
        ]
        if let mmproj {
            args.append(contentsOf: ["--mmproj", mmproj])
        }

        let stdout = Pipe()
        proc.executableURL = server
        proc.arguments = args
        proc.standardOutput = stdout
        proc.standardError = stdout

        do {
            try proc.run()
            states[.text] = BackendState(process: proc, port: port, path: server.path)
            llmStartedForModel = model
            adoptedLLM = false
            llmHealthy = true
            statusMessage = "Started llama-server on port \(port)"
        } catch {
            statusMessage = "Failed to start llama-server: \(error.localizedDescription)"
        }
    }

    /// Adopts an already-serving llama-server on :8080 (e.g. orphaned by a
    /// hard-killed previous instance) so the app reports it as running instead
    /// of spawning a duplicate that cannot bind the port.
    private func adoptHealthyLLM(desired: String?) -> Bool {
        guard probeLLMHealthy() else {
            adoptedLLM = false
            return false
        }
        if let desired, llmStartedForModel != desired { return false }
        guard let backendDir = llmBackendDir() else { return false }
        let server = backendDir.appendingPathComponent("llama-server")
        states[.text] = BackendState(process: nil, port: 8080, path: server.path)
        adoptedLLM = true
        llmHealthy = true
        llmStartedForModel = desired
        return true
    }

    /// Synchronous one-shot health probe for the text backend (blocking is fine
    /// here: it runs once at startup, not on hot paths).
    private func probeLLMHealthy() -> Bool {
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/health")!)
        request.timeoutInterval = 1.5
        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false
        session.dataTask(with: request) { _, response, _ in
            healthy = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2.5)
        return healthy
    }

    /// Kills whatever holds the llama port (a stale orphan) so a fresh launch
    /// can bind it. Best-effort; silently ignores failures.
    private func killLLMListener() {
        guard probeLLMHealthy() else { return }
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:8080"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        try? lsof.run()
        lsof.waitUntilExit()
        let pidText = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pid = Int(pidText) else { return }
        Diagnostics.shared.record(.warn, source: "sidecars", "stopping stale llama-server (pid \(pid))")
        _ = try? Process.run(URL(fileURLWithPath: "/bin/kill"), arguments: [String(pid)])
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func projectorPath(for model: String) -> String? {
        guard let modelsDir = modelsDir() else { return nil }
        let base = (model as NSString).deletingPathExtension
        let candidates = [
            "\(base)-mmproj-Q8_0.gguf",
            "\(base)-mmproj-BF16.gguf",
            projectorsContaining(files: try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path), base: (model as NSString).lastPathComponent)
        ]
        for c in candidates {
            if let c, FileManager.default.fileExists(atPath: c) {
                return c
            }
        }
        return nil
    }

    private func projectorsContaining(files: [String]?, base: String) -> String? {
        // Projector naming is often parallel to the model name.
        guard let files, let modelsDir = modelsDir() else { return nil }
        let stem = base.hasPrefix("llama") ? base : base
        let prefix = stem.replacingOccurrences(of: ".gguf", with: "")
        for f in files where f.contains("mmproj") && !f.hasPrefix(".") {
            return modelsDir.appendingPathComponent(f).path
        }
        _ = prefix
        return nil
    }

    private func findDefaultModel() -> String? {
        guard let modelsDir = modelsDir() else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        let gguf = files.sorted().filter {
            $0.hasSuffix(".gguf") && !$0.contains("mmproj")
                && fileExistsReal(at: modelsDir.appendingPathComponent($0))
        }
        guard let first = gguf.first else { return nil }
        return modelsDir.appendingPathComponent(first).path
    }

    func isLLMRunning() -> Bool { llmRunning }

    var llmRunning: Bool {
        (states[.text]?.process?.isRunning == true) || (adoptedLLM && llmHealthy)
    }
    var imageRunning: Bool { states[.image]?.process?.isRunning == true }
    /// Audio uses one-shot CLI tools (whisper + kokoro), so there is no
    /// persistent daemon to poll; "running" means the stack is present and ready.
    var audioRunning: Bool { audioReady }
    var anyRunning: Bool { BackendKind.allCases.contains { states[$0]?.process?.isRunning == true } }

    /// Starts every backend that can run persistently:
    ///   - text:  llama-server (long-running HTTP server)
    ///   - image: the local `sd` image server (long-running, OpenAI-compatible)
    ///   - audio: pre-warms the transcription/voice runtimes (one-shot CLI
    ///     tools, so "running" means model + runtime are ready to serve)
    /// Each launch is non-blocking: backends warm up in the background while
    /// the UI stays responsive.
    func startAll() {
        startOrEnsureLLM(modelPath: selectedTextModelPathForStartup)
        startImageInBackground()
        startAudioInBackground()
        startResearchSidecar()
        startMemorySidecar()
        startBrainSidecar()
        startSidecarWatchdog()
        // If llama-server was still warming up when we probed above, re-check
        // once shortly after launch and adopt it if it has come up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !self.llmRunning else { return }
            if self.adoptHealthyLLM(desired: self.selectedTextModelPathForStartup) {
                self.statusMessage = "Adopted existing llama-server on port 8080"
                Diagnostics.shared.record(.warn, source: "sidecars",
                                          "adopted llama-server after warm-up (port 8080)")
            }
        }
    }

    /// Launches the sd image server in the background with whatever image model
    /// is selected (falling back to the first installed checkpoint). Safe to
    /// call repeatedly; reuses an already-running server.
    func startImageInBackground() {
        guard imageBackendPath != nil else {
            statusMessage = "Image backend (sd) not found."
            return
        }
        guard !imageRunning else { return }
        let model = UserDefaults.standard.string(forKey: "selectedImageModelPath")
            ?? defaultImageModel()
        guard let model else {
            statusMessage = "No image model selected yet — image server will start once one is added."
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.ensureImageServer(modelPath: model)
        }
    }

    /// Pre-warms the audio backends. Because whisper-cli (STT) and the kokoro
    /// worker (TTS) are one-shot CLI processes invoked per request, there is no
    /// persistent daemon to keep alive; "starting" them here means ensuring the
    /// required model + runtime are in place so the first request is fast.
    func startAudioInBackground() {
        guard let root = rootFolder else {
            statusMessage = "Audio backend unavailable: workspace not found."
            return
        }
        let worker = root.appendingPathComponent("scripts/workers/tts-kokoro-worker.mjs")
        let runtime = root.appendingPathComponent("app/tts-runtime")
        let whisper = root.appendingPathComponent("app/speech-backend/mac/cpu/whisper-cli")

        let ttsReady = FileManager.default.fileExists(atPath: worker.path)
            && FileManager.default.fileExists(atPath: runtime.path)
        let sttReady = FileManager.default.isExecutableFile(atPath: whisper.path)

        states[.tts]?.process = nil   // no persistent TTS process; ready check only
        states[.speech]?.process = nil

        audioReady = ttsReady && sttReady

        statusMessage = ttsReady && sttReady
            ? "Audio backends ready."
            : "Audio backends ready (" + (ttsReady ? "TTS ✓" : "TTS fallback: say") + ", " + (sttReady ? "whisper ✓" : "whisper unavailable") + ")."
    }

    /// Launches the pure-Python web-research sidecar (stdlib-only, no deps) if
    /// it isn't already running and the script is present in the workspace.
    func startResearchSidecar() {
        guard let root = rootFolder else {
            statusMessage = "Research backend unavailable: workspace not found."
            return
        }
        let script = root.appendingPathComponent("app/research-backend/nexie_research.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            statusMessage = "Research backend not found (expected \(script.path))."
            return
        }
        if researchRunning { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["NEXIE_RESEARCH_PORT"] = "\(researchPort)"
        env["NEXIE_AUTH_TOKEN"] = SidecarAuth.token
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

do {
            try proc.run()
            states[.research] = BackendState(process: proc, port: researchPort,
                                             path: script.path)
            researchHealthy = true
            statusMessage = "Started research backend on port \(researchPort)"
            Diagnostics.shared.record(.info, source: "sidecars",
                                      "research started on port \(researchPort)")
        } catch {
            statusMessage = "Failed to start research backend: \(error.localizedDescription)"
        }
    }

    /// Launches the pure-Python memory/knowledge sidecar (stdlib-only, no deps)
    /// if it isn't already running and the script is present in the workspace.
    func startMemorySidecar() {
        guard let root = rootFolder else { return }
        let script = root.appendingPathComponent("app/research-backend/nexie_memory.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return }
        if memoryRunning { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["NEXIE_MEMORY_PORT"] = "\(memoryPort)"
        env["NEXIE_WORKSPACE_ROOT"] = root.path
        env["NEXIE_AUTH_TOKEN"] = SidecarAuth.token
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            states[.memory] = BackendState(process: proc, port: memoryPort,
                                           path: script.path)
            memoryHealthy = true
            statusMessage = "Started memory backend on port \(memoryPort)"
            Diagnostics.shared.record(.info, source: "sidecars",
                                      "memory started on port \(memoryPort)")
        } catch {
            statusMessage = "Failed to start memory backend: \(error.localizedDescription)"
        }
    }

    /// Launches the pure-Python routing/intent sidecar (stdlib-only, no deps)
    /// if it isn't already running and the script is present in the workspace.
    func startBrainSidecar() {
        guard let root = rootFolder else { return }
        let script = root.appendingPathComponent("app/research-backend/nexie_brain.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return }
        if brainRunning { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["NEXIE_BRAIN_PORT"] = "\(brainPort)"
        env["NEXIE_AUTH_TOKEN"] = SidecarAuth.token
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            states[.brain] = BackendState(process: proc, port: brainPort,
                                          path: script.path)
            brainHealthy = true
            statusMessage = "Started brain backend on port \(brainPort)"
            Diagnostics.shared.record(.info, source: "sidecars",
                                      "brain started on port \(brainPort)")
        } catch {
            statusMessage = "Failed to start brain backend: \(error.localizedDescription)"
        }
    }

    // MARK: - Sidecar watchdog

    /// Probes a sidecar's health endpoint with a short timeout.
    private func probe(port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        return true
    }

    /// Periodically verifies the Python sidecars are actually serving and
    /// respawns any that died or wedged. Runs only while backends are "on"
    /// (started via startAll), so it never fights a deliberate Stop.
    func startSidecarWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                let research = await self.probe(port: self.researchPort)
                self.researchHealthy = research
                if research { self.unhealthyCounts[.research] = 0 }
                else { self.maintainInstances(kind: .research, spawn: { self.startResearchSidecar() }) }

                let memory = await self.probe(port: self.memoryPort)
                self.memoryHealthy = memory
                if memory { self.unhealthyCounts[.memory] = 0 }
                else { self.maintainInstances(kind: .memory, spawn: { self.startMemorySidecar() }) }

                let brain = await self.probe(port: self.brainPort)
                self.brainHealthy = brain
                if brain { self.unhealthyCounts[.brain] = 0 }
                else { self.maintainInstances(kind: .brain, spawn: { self.startBrainSidecar() }) }
            }
        }
    }

    private func maintainInstances(kind: BackendKind, spawn: () -> Void) {
        let count = (unhealthyCounts[kind] ?? 0) + 1
        unhealthyCounts[kind] = count
        // Allow a slow warm-up two probe cycles before acting, to avoid thrash.
        guard count >= 2 else { return }
        unhealthyCounts[kind] = 0
        if states[kind]?.process?.isRunning == true {
            states[kind]?.process?.terminate()
            states[kind]?.process = nil
        }
        statusMessage = "\(kind.rawValue) sidecar was unresponsive — restarting…"
        Diagnostics.shared.recordRespawn(kind.rawValue)
        spawn()
    }

    func stopAll() {
        watchdogTask?.cancel()
        watchdogTask = nil
        unhealthyCounts = [:]
        researchHealthy = false
        memoryHealthy = false
        brainHealthy = false
        adoptedLLM = false
        llmHealthy = false
        stopImageServer()
        for kind in BackendKind.allCases where kind != .image {
            terminateForcefully(states[kind]?.process)
            states[kind]?.process = nil
        }
        statusMessage = "All backends stopped."
        Diagnostics.shared.record(.info, source: "sidecars", "all backends stopped")
    }

    private var selectedTextModelPathForStartup: String? {
        UserDefaults.standard.string(forKey: "selectedTextModelPath")
    }

    // MARK: - Image backend (sd server, OpenAI-compatible API)

    var imageBackendPath: String? {
        guard let root = rootFolder else { return nil }
        let p = root.appendingPathComponent("app/backend/mac/sd").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    var isImageBackendAvailable: Bool { imageBackendPath != nil }

    private var imageServerPort: Int {
        let stored = UserDefaults.standard.integer(forKey: "sdServerPort")
        return stored > 0 ? stored : 1234
    }

    private var imageURL: URL {
        URL(string: "http://127.0.0.1:\(imageServerPort)/v1")!
    }

    private var imageLogURL: URL? {
        guard let root = rootFolder else { return nil }
        let dir = root.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sd-server.log")
    }

    /// Starts (or reuses) the local `sd` image server for a model and waits
    /// until it answers `/v1/models`. The sd build only exposes an HTTP image
    /// API (no CLI output flag), and its 7 GB SDXL checkpoint is loaded as
    /// q8_0 with CPU offload so it fits in 16 GB of unified memory.
    func ensureImageServer(modelPath: String?) async -> URL? {
        guard let sdPath = imageBackendPath else {
            statusMessage = "Image backend (sd) not found."
            return nil
        }
        let model = modelPath ?? defaultImageModel()
        guard let model, FileManager.default.fileExists(atPath: model) else {
            statusMessage = "No image model selected. Choose one in Models."
            return nil
        }
        // Reject a broken/tiny download (e.g. an HF error page) that slipped
        // through: a real .safetensors checkpoint is hundreds of MB, so fail
        // fast with a clear message instead of hanging the sd server for minutes.
        let size = (try? FileManager.default.attributesOfItem(atPath: model)[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= 50 * 1024 * 1024 else {
            statusMessage = "Image model '\((model as NSString).lastPathComponent)' is invalid (only \(size / (1024*1024)) MB). Remove it and re-download."
            return nil
        }

        if let proc = states[.image]?.process, proc.isRunning,
           imageStartedForModel == model {
            return imageURL
        }

        stopImageServer()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sdPath)
        proc.arguments = [
            "-m", model,
            "--type", "q8_0",
            "--offload-to-cpu",
            "--diffusion-fa",
            "--vae-on-cpu",
            "--clip-on-cpu",
            "--mmap"
        ]
        // Log to a file rather than a pipe — sd's progress output would fill a
        // pipe buffer and deadlock the server.
        if let log = imageLogURL {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            imageLogHandle = FileHandle(forWritingAtPath: log.path)
        }
        proc.standardOutput = imageLogHandle ?? FileHandle.nullDevice
        proc.standardError = imageLogHandle ?? FileHandle.nullDevice

        do {
            try proc.run()
            states[.image] = BackendState(process: proc, port: imageServerPort, path: sdPath)
            imageStartedForModel = model
            statusMessage = "Starting image server (q8_0)…"
        } catch {
            statusMessage = "Failed to start image server: \(error.localizedDescription)"
            return nil
        }

        // Model conversion + load can take 30-90s from the external drive.
        let healthURL = imageURL.appendingPathComponent("models")
        for _ in 0..<120 {
            if await Self.imageServerUp(healthURL: healthURL) {
                statusMessage = "Image server ready."
                return imageURL
            }
            if !proc.isRunning { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        statusMessage = "Image server did not become ready."
        return nil
    }

    nonisolated static func imageServerUp(healthURL: URL) async -> Bool {
        guard let (_, resp) = try? await URLSession.shared.data(from: healthURL),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    func stopImageServer() {
        guard let proc = states[.image]?.process else { return }
        terminateForcefully(proc)
        states[.image] = BackendState(process: nil, port: 0, path: nil)
        imageLogHandle?.closeFile()
        imageLogHandle = nil
    }

    /// Terminates a backend process with a short grace period, escalating to
    /// SIGKILL so nothing is left running in the background after quit.
    private func terminateForcefully(_ proc: Process?) {
        guard let proc, proc.isRunning else { return }
        proc.terminate()
        // Give it a moment to exit cleanly (SIGTERM), then force-kill.
        let deadline = Date().addingTimeInterval(3.0)
        while proc.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()
        }
    }

    // MARK: - LLM/GPU handoff

    /// Stops the text (LLM) backend so the image server has GPU room on this
    /// 16 GB machine. Returns true when the LLM was actually paused.
    @discardableResult
    func pauseLLMForImageWork() -> Bool {
        guard llmRunning else { return false }
        states[.text]?.process?.terminate()
        states[.text]?.process?.waitUntilExit()
        llmPausedForImages = true
        statusMessage = "Paused the LLM backend to free GPU memory for image generation."
        return true
    }

    /// Restarts the LLM backend after image generation paused it.
    func resumeLLMImagePause() {
        guard llmPausedForImages else { return }
        llmPausedForImages = false
        startOrEnsureLLM(modelPath: llmStartedForModel)
        if llmRunning {
            statusMessage = "LLM backend resumed."
        }
    }

    func defaultImageModel() -> String? {
        guard let root = rootFolder else { return nil }
        let dir = root.appendingPathComponent("app/models")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for f in files where f.hasSuffix(".safetensors") || f.hasSuffix(".ckpt") || f.hasSuffix(".gguf") {
            let url = dir.appendingPathComponent(f)
            guard fileExistsReal(at: url) else { continue }
            return url.path
        }
        return nil
    }

    // MARK: - Model discovery & download

    func listTextModels() -> [String] {
        guard let dir = modelsDir() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files
            .filter { $0.hasSuffix(".gguf") && !$0.contains("mmproj") }
            .filter { fileExistsReal(at: dir.appendingPathComponent($0)) }
            .sorted()
            .map { dir.appendingPathComponent($0).path }
    }

    /// Returns true only if the file exists AND is not a dangling symlink.
    /// A model file whose target no longer exists (e.g. a stale external-volume
    /// path) must not be offered as "installed", or backends will fail to load it.
    private func fileExistsReal(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // `fileExists` returns true for a broken symlink; check the target resolves.
        var isSymlink: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isSymlink)
        do {
            let vals = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if vals.isSymbolicLink == true {
                let resolved = url.resolvingSymlinksInPath()
                return FileManager.default.fileExists(atPath: resolved.path)
            }
        } catch {}
        return true
    }

    private func imageModelsDir() -> URL? {
        guard let root = rootFolder else { return nil }
        let dir = root.appendingPathComponent("app/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func listImageModels() -> [String] {
        guard let dir = imageModelsDir() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files
            .filter { $0.hasSuffix(".safetensors") || $0.hasSuffix(".ckpt") || $0.hasSuffix(".gguf") }
            .filter { fileExistsReal(at: dir.appendingPathComponent($0)) }
            .sorted()
            .map { dir.appendingPathComponent($0).path }
    }

    /// Downloads an HF resolve URL into the text-models folder (where
    /// `listTextModels` scans), streaming straight to a file so a multi-GB
    /// model never loads into RAM. Several downloads may run concurrently;
    /// each destination path has exactly one in-flight session. `onProgress`
    /// is called on the main actor with real byte-level progress (0...1).
    ///
    /// Transient network failures are retried automatically (up to 3 attempts),
    /// cleaning the partial file before each retry so a stalled CDN transfer
    /// eventually completes rather than fizzling out.
    func downloadModel(urlString: String, filename: String,
                       onProgress: @escaping (Double) -> Void) async {
        await downloadInto(modelsDir(), urlString: urlString, filename: filename,
                           onProgress: onProgress)
    }

    /// Downloads an SD image checkpoint (`.safetensors`/`.ckpt`/`.gguf`) into the
    /// image-models folder scanned by `listImageModels`. Same retry/concurrency
    /// semantics as `downloadModel`, but targets the Stable Diffusion model dir.
    func downloadImageModel(urlString: String, filename: String,
                       onProgress: @escaping (Double) -> Void) async {
        await downloadInto(imageModelsDir(), urlString: urlString, filename: filename,
                           onProgress: onProgress)
    }

    private func downloadInto(_ dir: URL?, urlString: String, filename: String,
                       onProgress: @escaping (Double) -> Void) async {
        guard let url = URL(string: urlString) else { return }
        let dest = dir?.appendingPathComponent(filename)
            ?? WorkspaceManager.shared.modelsURL.appendingPathComponent(filename)
        let dir = dest.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)

        for attempt in 1...3 {
            // One session per destination, so concurrent downloads of the same
            // file wait on the existing transfer instead of duplicating work.
            let session = DownloadSession.pendingSession(for: dest, make: {
                DownloadSession(destination: dest)
            })
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            let ok = await session.run(from: url, onProgress: onProgress)
            DownloadSession.removePending(for: dest)
            if ok {
                onProgress(1.0)
                return
            }
            // Failed attempt: remove any partial file and back off briefly
            // before retrying with a fresh URLSession.
            try? FileManager.default.removeItem(at: dest)
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 2_000_000_000 * UInt64(attempt))
            }
        }
        onProgress(0)
    }

    /// Permanently removes an installed model file (text GGUF or image
    /// checkpoint) from the workspace. Returns false if the file could not be
    /// removed (e.g. it is outside the workspace, or the volume is read-only).
    /// The caller is expected to refresh the installed lists afterwards.
    @discardableResult
    func deleteModel(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            statusMessage = "Could not delete '\((path as NSString).lastPathComponent)': \(error.localizedDescription)"
            return false
        }
    }

    /// Shows a file picker synchronously on the main actor; copies the chosen model
    /// weights into the workspace Models folder and returns its path.
    @MainActor
    func importImageModel() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import image model weights"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let src = panel.url else { return nil }
        let dest = imageModelsDir()?.appendingPathComponent(src.lastPathComponent)
            ?? WorkspaceManager.shared.modelsURL.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.copyItem(at: src, to: dest)
        return dest.path
    }

    // MARK: - Shutdown

    func shutdownAll() {
        for kind in BackendKind.allCases {
            states[kind]?.process?.terminate()
        }
    }
}
