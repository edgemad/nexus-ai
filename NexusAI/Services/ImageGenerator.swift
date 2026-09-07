import Foundation
import SwiftUI

/// Drives the local stable-diffusion.cpp backend (`sd`) for text-to-image
/// generation, and img2img for "remix/remake".
///
/// The installed sd build exposes an OpenAI-compatible HTTP image API instead
/// of a CLI output flag, so generation goes through `/v1/images/generations`
/// (txt2img) and `/v1/images/edits` (img2img).
@MainActor
final class ImageGenerator: ObservableObject {
    @Published private(set) var isGenerating = false
    @Published private(set) var lastImageURL: URL?
    @Published var error: String?
    /// 0...1 generation progress for the UI. Because the sd HTTP endpoint
    /// blocks until the image is complete, this advances deterministically
    /// through the known pipeline phases (server prep → request → save) and
    /// finishes at 1 on success.
    @Published private(set) var progress: Double = 0
    @Published private(set) var stage = ""

    private let backend: BackendManager
    /// In-flight generation task; kept so "Stop" can cancel it immediately.
    private var generationTask: Task<Void, Never>?

    init(backend: BackendManager) {
        self.backend = backend
    }

    /// Cancels an in-progress generation (stops the blocking network request)
    /// and returns the UI to idle.
    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        progress = 0
        stage = ""
    }

    /// Generate an image from a prompt using the given model path.
    /// When `sourceImage` is provided (img2img), `strength` controls how much
    /// of the source is retained (0 = unchanged, 1 = full re-draw).
    func generate(modelPath: String?, prompt: String, negative: String = "", width: Int = 768,
                  height: Int = 768, steps: Int = 20,
                  sourceImage: URL? = nil, strength: Double = 0.75) {
        guard backend.imageBackendPath != nil else {
            error = "Image backend (sd) not found. Configure it in Backends."
            return
        }
        let model = modelPath ?? backend.defaultImageModel()
        guard let model else {
            error = "No image model selected. Choose one in Models."
            return
        }

        isGenerating = true
        error = nil
        progress = 0
        stage = "Preparing image engine…"
        // Generated images go to the transient media cache — never autosaved to
        // Outputs. The temp file stages display *and* acts as the img2img remix
        // source; an explicit "Save image…" writes a persistent copy on demand.
        let outURL = TempMediaCache.shared.url(ext: "png")

        generationTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let paused = self.backend.pauseLLMForImageWork()
            defer { self.backend.resumeLLMImagePause() }

            self.progress = 0.04
            self.stage = "Loading model & server…"
            guard let base = await self.backend.ensureImageServer(modelPath: model) else {
                self.isGenerating = false
                self.progress = 0
                self.stage = ""
                self.error = "Image server failed to start. Check Backends."
                return
            }

            // Request phase: advance progress smoothly toward 90% over time
            // (a proxy for real sampling work, since the sd endpoint is blocking).
            self.progress = 0.25
            self.stage = "Generating image…"
            let requestDuration: TimeInterval = max(3.0, Double(steps) * 2.2)
            let ticker = self.progressTicker(start: 0.25, target: 0.90, duration: requestDuration)
            let ok = await Self.generateViaServer(
                baseURL: base, prompt: prompt, negative: negative,
                width: width, height: height, steps: steps,
                sourceImagePath: sourceImage?.path, strength: strength,
                outputURL: outURL)
            ticker.cancel()
            if Task.isCancelled { self.generationTask = nil; self.cancel(); return }
            self.progress = ok ? 1 : 0
            self.stage = ok ? "Saving…" : ""
            self.isGenerating = false
            self.generationTask = nil
            if ok {
                self.lastImageURL = outURL
            } else {
                self.error = "Image generation failed (server did not return an image). Check the Backends/Models panels and retry."
            }
        }
        generationTask = task
    }

    /// Smoothly eases `progress` from a start fraction toward a target over a
    /// duration so the UI shows a believable, monotonic bar while the
    /// (blocking) sd request runs. Cancelled when the request completes.
    private func progressTicker(start: Double, target: Double, duration: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            let began = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(began)
                let t = min(1.0, elapsed / max(0.1, duration))
                // ease-out so it feels like the bulk finishes early then slows
                let eased = 1 - pow(1 - t, 2)
                let value = start + (target - start) * eased
                if let self {
                    self.progress = value
                    self.stage = "Generating image… \(Int(value * 100))%"
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    /// Remix uses the last generated image as img2img source.
    func remix(modelPath: String?, source: URL, prompt: String) {
        generate(modelPath: modelPath, prompt: prompt, steps: 25, sourceImage: source)
    }

    // MARK: - Server client (runs off the main actor)

    /// Nonisolated core the movie generator also uses: asks the sd server for
    /// an image and writes it to `outputURL`. Returns success.
    nonisolated static func generateViaServer(baseURL: URL, prompt: String, negative: String,
                                              width: Int, height: Int, steps: Int,
                                              sourceImagePath: String?, strength: Double,
                                              outputURL: URL) async -> Bool {
        let imageData: Data
        if let source = sourceImagePath, FileManager.default.fileExists(atPath: source) {
            imageData = await requestEdits(baseURL: baseURL, prompt: prompt, negative: negative,
                                           sourcePath: source, steps: steps, strength: strength)
        } else {
            imageData = await requestGeneration(baseURL: baseURL, prompt: prompt, negative: negative,
                                                width: width, height: height, steps: steps)
        }
        guard !imageData.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try imageData.write(to: outputURL)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func requestGeneration(baseURL: URL, prompt: String, negative: String,
                                                      width: Int, height: Int, steps: Int) async -> Data {
        var body: [String: Any] = [
            "prompt": prompt, "n": 1, "size": "\(width)x\(height)",
            "steps": steps, "response_format": "b64_json"
        ]
        if !negative.isEmpty { body["negative_prompt"] = negative }
        return await post(baseURL: baseURL.appendingPathComponent("images/generations"), json: body)
    }

    private nonisolated static func requestEdits(baseURL: URL, prompt: String, negative: String,
                                                 sourcePath: String, steps: Int, strength: Double) async -> Data {
        guard let source = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)) else { return Data() }
        let boundary = "NexusSD-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("prompt", prompt)
        field("steps", "\(steps)")
        field("strength", "\(strength)")
        field("response_format", "b64_json")
        if !negative.isEmpty { field("negative_prompt", negative) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"input.png\"\r\nContent-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(source)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent("images/edits"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return await data(for: req)
    }

    /// Stable Diffusion takes ~90s+ per 768x768 image on this machine (and
    /// far longer for larger/higher-step movie keyframes). The default
    /// URLSession timeout (60s) cuts these requests off, which previously
    /// surfaced as bogus "Free GPU memory" / "model not selected" errors. Use a
    /// generous timeout so long generations aren't aborted mid-sampling.
    private static let imageRequestTimeout: TimeInterval = 900

    private nonisolated static func post(baseURL: URL, json: [String: Any]) async -> Data {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = imageRequestTimeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        return await data(for: req)
    }

    private nonisolated static func data(for req: URLRequest) async -> Data {
        var req = req
        req.timeoutInterval = imageRequestTimeout
        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return Data() }
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let list = obj["data"] as? [[String: Any]], let first = list.first else { return Data() }
        if let b64 = first["b64_json"] as? String,
           let img = Data(base64Encoded: b64) { return img }
        if let urlStr = first["url"] as? String, let url = URL(string: urlStr),
           let (img, _) = try? await URLSession.shared.data(from: url) { return img }
        return Data()
    }
}