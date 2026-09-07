import Foundation
import SwiftUI
import AVFoundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Generates a playable movie from a text prompt, entirely locally:
///
/// 1. Renders a sequence of "keyframes" with the Stable Diffusion backend
///    (same prompt, fresh seeds → coherent variations across the scene).
/// 2. Animates a Ken Burns push-in/pan between keyframes with soft crossfades.
/// 3. Synthesizes a gentle ambient music bed.
/// 4. Muxes video + audio into an H.264 QuickTime movie in the workspace
///    Outputs folder.
@MainActor
final class VideoGenerator: ObservableObject {
    @Published private(set) var isGenerating = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var stage = ""
    @Published private(set) var lastMovieURL: URL?
    @Published var error: String?
    /// Informational note (e.g. an H3 fallback notice) shown alongside errors.
    @Published var note: String?
    /// In-flight render task; kept so "Stop" can cancel it immediately
    /// (cancels the MiniMax H3 poll loop as well as the local pipeline).
    private var renderTask: Task<Void, Never>?
    enum Engine {
        /// Stable Diffusion keyframes + Ken Burns + procedural score, fully on-device.
        case local
        /// MiniMax H3 (hosted, optional API key): real motion + native stereo audio.
        case miniMax
    }

    /// How the generated movie should be composed.
    struct MovieSpec {
        var engine: Engine = .local
        var prompt: String
        var negative = "blurry, low quality, distorted, watermark, text"
        var keyframes = 4        // number of distinct scenes / keyframes
        var fps = 30
        var durationPerScene = 3.0   // seconds per scene
        var width = 1024
        var height = 576
        var steps = 16           // SD sampling steps (quality)
        var crossfade = 0.6      // seconds of blend between scenes
        var withMusic = true
    }

    // MARK: - Public API

    func generate(_ spec: MovieSpec) {
        guard !isGenerating else { return }
        error = nil
        note = nil
        isGenerating = true
        progress = 0
        stage = "Concepting scenes…"

        let modelPath = imageGenModelPath()
        renderTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let movieURL = await self.render(spec: spec, modelPath: modelPath)
            if Task.isCancelled { self.renderTask = nil; return }
            self.isGenerating = false
            self.progress = 1
            self.stage = ""
            self.renderTask = nil
            if let movieURL {
                self.lastMovieURL = movieURL
            }
        }
        renderTask = task
    }

    func cancel() {
        renderTask?.cancel()
        renderTask = nil
        isGenerating = false
        progress = 0
        stage = "Cancelled"
    }

    /// The last model path the user picked for image generation (fallback: any
    /// installed SD model).
    private func imageGenModelPath() -> String? {
        let stored = UserDefaults.standard.string(forKey: "selectedImageModelPath")
        if let stored, FileManager.default.fileExists(atPath: stored) { return stored }
        return BackendManager.shared.defaultImageModel()
    }

    // MARK: - Render pipeline

    private func render(spec: MovieSpec, modelPath: String?) async -> URL? {
        // MiniMax H3 path: real motion video + native stereo audio from the
        // cloud. No local image backend needed. If H3 isn't configured, or the
        // cloud call fails, we transparently fall back to the local pipeline so
        // generating a movie always works.
        if spec.engine == .miniMax {
            if !MiniMaxService.isConfigured {
                note = "MiniMax H3 needs an API key (added in the Movie Studio or Settings → MiniMax H3). Falling back to the on-device engine."
            } else {
                let duration = min(Int(round(Double(spec.keyframes) * spec.durationPerScene)), 15)
                if duration >= 4 {
                    let resolution = spec.height >= 1080 ? "2K" : "768P"
                    let ratio: String
                    switch (spec.width, spec.height) {
                    case (1920, 1080), (1280, 720), (960, 540), (1024, 576): ratio = "16:9"
                    case (1080, 1920), (720, 1280): ratio = "9:16"
                    default: ratio = "16:9"
                    }
                    do {
                        stage = "Sending prompt to MiniMax H3…"
                        let result = try await MiniMaxService.generateVideo(
                            prompt: spec.prompt, duration: duration,
                            resolution: resolution, ratio: ratio) { fraction in
                            self.progress = fraction
                            self.stage = "MiniMax H3 generating clip… \(Int(fraction * 100))%"
                        }
                        // H3 already contains audio; return it directly.
                        return result
                    } catch {
                        note = "MiniMax H3 failed (\(error.localizedDescription)). Falling back to the on-device engine."
                    }
                }
            }
        }
        // Fall back to the fully-local Ken Burns pipeline below.

        let backend = BackendManager.shared
        let pausedLLM = backend.pauseLLMForImageWork()
        defer { if pausedLLM { backend.resumeLLMImagePause() } }

        // 1) Keyframes ------------------------------------------------
        var keyframes: [URL] = []
        let total = max(2, min(spec.keyframes, 10))
        for i in 0..<total {
            if !isGenerating { return nil }
            stage = "Rendering scene \(i + 1)/\(total)…"
            progress = Double(i) / Double(total + spec.keyframes)
            let scenePrompt = scenePrompt(base: spec.prompt, index: i, total: total)

            guard let url = await renderKeyframe(modelPath: modelPath, spec: spec, prompt: scenePrompt) else {
                error = "Scene \(i + 1) failed. Check that an image model is selected in Models."
                return nil
            }
            keyframes.append(url)
        }

        // 2) Movie rendering ------------------------------------------
        let videoURL = TempMediaCache.shared.directory
        let rawVideo: URL
        do {
            stage = "Animating and encoding video…"
            rawVideo = try await encodeVideo(keyframes: keyframes, spec: spec)
        } catch let failure {
            self.error = "Encoding failed: \(failure.localizedDescription)"
            return nil
        }

        // 3) Audio bed ------------------------------------------------
        var audioURL: URL?
        if spec.withMusic {
            stage = "Composing audio track…"
            audioURL = writeMusic(spec: spec)
        }

        // 4) Mux & finalize -------------------------------------------
        let finalURL = videoURL.appendingPathComponent("movie-\(Int(Date().timeIntervalSince1970)).mov")
        return await mux(video: rawVideo, audio: audioURL, to: finalURL)
    }

    /// Each scene keeps the core prompt but varies the shot/composition so the
    /// movie reads as a progression rather than a loop.
    private func scenePrompt(base: String, index: Int, total: Int) -> String {
        let shots = [
            "wide establishing shot, cinematic framing",
            "slow push-in, detailed focus on the subject",
            "medium shot, dramatic angle, rich background",
            "close-up, fine detail, shallow depth of field",
            "sweeping pan across the scene, epic scale",
            "dramatic counter-angle, strong composition"
        ]
        let shot = shots[index % shots.count]
        let pacing = "film still from a movie, \(shot), cinematic color grading, volumetric light, high detail"
        return base.isEmpty ? pacing : "\(base), \(pacing)"
    }

    private func renderKeyframe(modelPath: String?, spec: MovieSpec, prompt: String) async -> URL? {
        let backend = BackendManager.shared
        guard backend.imageBackendPath != nil else { return nil }
        let model = modelPath ?? backend.defaultImageModel()
        guard let model else { return nil }

        guard let base = await backend.ensureImageServer(modelPath: model) else { return nil }

        let folder = TempMediaCache.shared.directory
        let outURL = folder.appendingPathComponent("keyframe-\(Int(Date().timeIntervalSince1970 * 1000)).png")

        let ok = await ImageGenerator.generateViaServer(
            baseURL: base, prompt: prompt, negative: spec.negative,
            width: spec.width, height: spec.height, steps: spec.steps,
            sourceImagePath: nil, strength: 0.75, outputURL: outURL)
        guard ok, FileManager.default.fileExists(atPath: outURL.path) else { return nil }
        return outURL
    }

    // MARK: - Video encoding (Ken Burns + crossfade)

    private func encodeVideo(keyframes: [URL], spec: MovieSpec) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: outputURLForRaw(spec: spec), fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: spec.fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Video", code: 1)
        }
        writer.startSession(atSourceTime: .zero)

        // Preload keyframe CGImages for fast reuse.
        var images: [CGImage] = []
        for url in keyframes {
            images.append(loadImage(url))
        }

        let totalFrames = Int(Double(spec.fps) * spec.durationPerScene * Double(images.count))
        var rendered = 0

        while !input.isReadyForMoreMediaData {
            await Task.yield()
        }

        for frame in 0..<totalFrames {
            if !isGenerating { break }
            autoreleasepool {
                guard let pool = createPixelBuffer(width: spec.width, height: spec.height) else { return }
                drawFrame(buffer: pool, images: images, frame: frame, spec: spec)
                if input.isReadyForMoreMediaData {
                    adaptor.append(pool, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(spec.fps)))
                }
            }
            rendered += 1
            progress = 0.55 + 0.35 * (Double(rendered) / Double(totalFrames))
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "Video", code: 2)
        }
        return writer.outputURL
    }

    private func outputURLForRaw(spec: MovieSpec) -> URL {
        TempMediaCache.shared.directory
            .appendingPathComponent("raw-\(Int(Date().timeIntervalSince1970)).mov")
    }

    private func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return pb
    }

    private func loadImage(_ url: URL) -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return placeholderImage()
        }
        return img
    }

    private func placeholderImage() -> CGImage {
        let size = CGSize(width: 1280, height: 720)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.12, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }

    /// Draws the interpolated frame into a BGRA pixel buffer: Ken Burns motion
    /// on the current keyframe plus a crossfade into the next one.
    private func drawFrame(buffer: CVPixelBuffer, images: [CGImage],
                           frame: Int, spec: MovieSpec) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }

let ctx = CGContext(data: base, width: spec.width, height: spec.height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                       CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx else { return }

        let duration = CGFloat(spec.durationPerScene)
        let t = CGFloat(frame) / CGFloat(spec.fps)
        let sceneIndex = min(Int(t / duration), images.count - 1)
        let frac = (t - CGFloat(sceneIndex) * duration) / duration
        let cross = CGFloat(spec.crossfade) / duration

        // Blending into the next scene near the end of this one.
        let blend = min(max((frac - (1 - cross)) / cross, 0), 1)
        let nextIndex = min(sceneIndex + 1, images.count - 1)
        let hasNext = sceneIndex < nextIndex

        // Ken Burns: A pushes in while B gently recedes.
        let zoomA: CGFloat = 1.05 + 0.05 * frac
        let zoomB: CGFloat = 1.10 - 0.05 * frac
        let panA = 0.10 * sin(frac * .pi)

        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))

        draw(images[sceneIndex], in: ctx,
             zoom: zoomA, pan: panA, spec: spec)
        if hasNext {
            ctx.setAlpha(blend)
            draw(images[nextIndex], in: ctx,
                 zoom: zoomB, pan: -panA, spec: spec)
            ctx.setAlpha(1)
        }
    }

    private func draw(_ image: CGImage, in ctx: CGContext, zoom: CGFloat,
                      pan: CGFloat, spec: MovieSpec) {
        let frameW = CGFloat(spec.width)
        let frameH = CGFloat(spec.height)
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        // Cover-fit the source into the frame, then apply zoom + pan.
        let scale = zoom * max(frameW / imgW, frameH / imgH)
        let w = imgW * scale
        let h = imgH * scale
        let x = (frameW - w) / 2 + pan * frameW
        let y = (frameH - h) / 2 - pan * frameH * 0.5

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: - Ambient music bed

    /// Synthesizes a gentle chord pad (Am–F–C–G) as a stereo WAV file.
    private func writeMusic(spec: MovieSpec) -> URL? {
        let sampleRate = 44_100
        let seconds = max(2.0, spec.durationPerScene * Double(spec.keyframes))
        let totalSamples = Int(Double(sampleRate) * seconds)
        let chordDuration = Double(sampleRate) * (seconds / 4.0)

        var left = [Int16](repeating: 0, count: totalSamples)
        var right = [Int16](repeating: 0, count: totalSamples)

        let chords: [(Double, Double, Double)] = [
            (220.0, 261.63, 329.63),  // Am
            (174.61, 220.0, 261.63),  // F
            (196.0, 261.63, 329.63),  // C
            (196.0, 246.94, 293.66)   // G
        ]

        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            let chordIdx = min(Int(Double(i) / chordDuration), chords.count - 1)
            let c = chords[chordIdx]

            // Slow amplitude envelope: attack then gentle fade.
            let pos = Double(i).truncatingRemainder(dividingBy: chordDuration) / chordDuration
            let env = min(1.0, pos / 0.1) * (1.0 - 0.25 * pos)

            let vib = 1.0 + 0.0015 * sin(2 * .pi * 5.0 * t)
            var v = 0.0
            for (idx, f) in [c.0, c.1, c.2].enumerated() {
                let freq = f * vib
                let amp = idx == 0 ? 0.30 : 0.18
                v += amp * sin(2 * .pi * freq * t)
            }
            // Subtle octave shimmer.
            v += 0.05 * sin(2 * .pi * c.2 * 2 * t)

            let sample = Int16(clamping: Int(v * env * 9000))
            left[i] = sample
            right[i] = sample
        }

        // Write WAV (16-bit PCM, stereo).
        let audioURL = TempMediaCache.shared.directory
            .appendingPathComponent("music-\(Int(Date().timeIntervalSince1970)).wav")
        guard let url = writeWAV(stereoLeft: left, right: right, sampleRate: sampleRate, to: audioURL) else {
            return nil
        }
        return url
    }

    private func writeWAV(stereoLeft: [Int16], right: [Int16],
                          sampleRate: Int, to url: URL) -> URL? {
        let bytesPerSample = 2
        let channels = 2
        let dataSize = stereoLeft.count * bytesPerSample * channels
        let headerSize = 44
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: le32(UInt32(dataSize + headerSize - 8)))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(contentsOf: le32(16))
        data.append(contentsOf: le16(1))           // PCM
        data.append(contentsOf: le16(UInt16(channels)))
        data.append(contentsOf: le32(UInt32(sampleRate)))
        data.append(contentsOf: le32(UInt32(sampleRate * channels * bytesPerSample)))
        data.append(contentsOf: le16(UInt16(channels * bytesPerSample)))
        data.append(contentsOf: le16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: le32(UInt32(dataSize)))

        for i in 0..<stereoLeft.count {
            data.append(contentsOf: le16(UInt16(bitPattern: stereoLeft[i])))
            data.append(contentsOf: le16(UInt16(bitPattern: right[i])))
        }

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // MARK: - Mux (video + optional audio) to final .mov

    private func mux(video: URL, audio: URL?, to finalURL: URL) async -> URL? {
        let composition = AVMutableComposition()

        do {
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid),
                  let videoAssetTrack = try await AVURLAsset(url: video).loadTracks(withMediaType: .video).first else {
                try? FileManager.default.removeItem(at: video)
                return nil
            }
            let range = CMTimeRange(start: .zero, duration: videoAssetTrack.timeRange.duration)
            try videoTrack.insertTimeRange(range, of: videoAssetTrack, at: .zero)

            if let audio {
                let aT = try await AVURLAsset(url: audio).loadTracks(withMediaType: .audio).first
                if let aT, let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: aT.timeRange.duration),
                                                   of: aT, at: .zero)
                }
            }

            guard let exporter = AVAssetExportSession(asset: composition,
                                                      presetName: AVAssetExportPresetHighestQuality) else {
                try? FileManager.default.removeItem(at: video)
                if let audio { try? FileManager.default.removeItem(at: audio) }
                return nil
            }
            exporter.outputURL = finalURL
            exporter.outputFileType = .mov
            exporter.shouldOptimizeForNetworkUse = true
            await exporter.export()
            try? FileManager.default.removeItem(at: video)
            if let audio { try? FileManager.default.removeItem(at: audio) }
            return exporter.status == .completed ? finalURL : nil
        } catch {
            try? FileManager.default.removeItem(at: video)
            if let audio { try? FileManager.default.removeItem(at: audio) }
            return nil
        }
    }
}