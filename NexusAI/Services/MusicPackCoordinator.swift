import Foundation
import AVFoundation
import AppKit
import CoreGraphics
import CoreText
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Music Pack model
// ---------------------------------------------------------------------------

/// Cover / video canvas aspect ratios selectable in the Music Studio.
enum ImageAspect: String, CaseIterable, Identifiable {
    case square = "Square (1:1)"
    case wide = "Wide (16:9)"
    case vertical = "Vertical (9:16)"

    var id: String { rawValue }

    /// Cover render size in pixels.
    var size: (width: Int, height: Int) {
        switch self {
        case .square: return (1024, 1024)
        case .wide: return (1600, 900)
        case .vertical: return (900, 1600)
        }
    }
}

/// How much harmonic detail / mastering to throw at the track.
enum MusicPackQuality: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case rich = "Rich"

    var id: String { rawValue }

    var complexity: FastMusicGenerator.Complexity {
        switch self {
        case .fast: return .simple
        case .balanced: return .medium
        case .rich: return .rich
        }
    }
}

/// Everything the Music Studio asks for when generating a pack.
struct MusicPackSpec {
    var prompt: String
    var genre: AudioMixer.Genre
    var duration: Double
    var quality: MusicPackQuality
    var includeVideo: Bool
    var aspect: ImageAspect
}

/// The result of a successful pack generation.
struct MusicPack {
    var title: String
    var audioURL: URL
    var coverURL: URL
    var videoURL: URL?
}

// ---------------------------------------------------------------------------
// Procedural cover art (zero model, always works)
// ---------------------------------------------------------------------------

enum MusicCoverRenderer {
    /// Draws a genre-styled gradient cover with the prompt title and the Nexie
    /// studio badge, writes it as a PNG into the temp cache, and returns its
    /// URL. Pure CoreGraphics so it can run off the main thread.
    static func render(title: String, genre: AudioMixer.Genre, aspect: ImageAspect) async -> URL? {
        let (w, h) = aspect.size
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let (top, bottom) = palette(for: genre)
        let colors = [top, bottom]
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        colors: colors as CFArray, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: Double(h)),
                               end: CGPoint(x: Double(w), y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // A few soft translucent orbs for depth.
        ctx.setBlendMode(.plusLighter)
        let orbComponents = top.components ?? [1, 1, 1, 1]
        for i in 0..<5 {
            let r = Double(w) * 0.18
            let cx = Double(w) * (0.2 + 0.6 * Double(i % 3))
            let cy = Double(h) * (0.2 + 0.6 * Double((i * 7) % 3))
            ctx.setFillColor(CGColor(red: orbComponents[0] + 0.3, green: orbComponents[1] + 0.3,
                                     blue: orbComponents[2] + 0.4, alpha: 0.16))
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }
        ctx.setBlendMode(.normal)

        // Title text (wrapped) + studio badge.
        let titleLines = wrapped(title, maxLines: 3, maxWidth: CGFloat(w) * 0.8)
        let lineHeight = CGFloat(h) * 0.075
        let startY = Double(h) * 0.42 + Double(titleLines.count) * 0.5 * Double(lineHeight)
        ctx.textMatrix = .identity
        for (i, line) in titleLines.enumerated() {
            drawText(line, in: ctx, size: lineHeight * 0.72, x: Double(w) * 0.1,
                     y: startY - Double(i) * Double(lineHeight), width: Double(w) * 0.8,
                     color: .white)
        }

        drawText("NEXIE STUDIO", in: ctx, size: CGFloat(h) * 0.022, x: Double(w) * 0.1,
                 y: Double(h) * 0.08, width: Double(w) * 0.5, color: .white.withAlphaComponent(0.75))

        guard let image = ctx.makeImage() else { return nil }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        guard let data else { return nil }
        let url = await TempMediaCache.shared.url(ext: "png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func palette(for genre: AudioMixer.Genre) -> (top: CGColor, bottom: CGColor) {
        func c(_ hex: UInt32) -> CGColor {
            CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch genre {
        case .ambient:        return (c(0x1b3b5b), c(0x0a1118))
        case .rock, .metal:   return (c(0x3d1a1a), c(0x0c0c10))
        case .jazz:           return (c(0x4a2c5c), c(0x151018))
        case .edm:            return (c(0x2040a0), c(0x081030))
        case .hiphop:         return (c(0x3a3a12), c(0x0a0a08))
        case .classical:      return (c(0x6a4a22), c(0x181008))
        case .ballad, .folk:  return (c(0x7a5a32), c(0x241810))
        case .latin, .reggae: return (c(0x8a4a12), c(0x2008a0))
        case .pop, .funk:     return (c(0xb0306a), c(0x3a0a22))
        case .soul, .rnb:     return (c(0x5a2a5c), c(0x140a16))
        case .gospel:         return (c(0x8a6a1a), c(0x2a1808))
        case .country:        return (c(0x5a7a22), c(0x1a2208))
        default:              return (c(0x2a3a5c), c(0x0e1420))
        }
    }

    private static func wrapped(_ text: String, maxLines: Int, maxWidth: CGFloat) -> [String] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ["Untitled"] }
        let words = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var lines: [String] = []
        var current = ""
        func fits(_ s: String) -> Bool {
            let attr = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 28)]
            let w = (s as NSString).size(withAttributes: attr).width
            return w <= maxWidth
        }
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if fits(candidate) || current.isEmpty {
                current = candidate
            } else {
                lines.append(current)
                current = word
                if lines.count == maxLines - 1 { break }
            }
        }
        if current.isEmpty == false && lines.count < maxLines { lines.append(current) }
        return lines.isEmpty ? ["Untitled"] : lines
    }

    private static func drawText(_ text: String, in ctx: CGContext, size: CGFloat,
                                 x: Double, y: Double, width: Double, color: NSColor) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.saveGState()
        ctx.setBlendMode(.normal)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y + Double(size))
        ctx.scaleBy(x: 1, y: -1)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

// ---------------------------------------------------------------------------
// Ken Burns video (cover image + audio, zero external models)
// ---------------------------------------------------------------------------

enum MusicPackVideoRenderer {
    /// Renders a slow zoom-and-pan Ken Burns video of the cover over the audio
    /// track and returns a H.264/mov. Composition happens off the main thread.
    static func render(cover: URL, audio: URL, duration: Double,
                       aspect: ImageAspect) async -> URL? {
        let (videoWidth, videoHeight) = aspect.size
        guard let image = (NSImage(contentsOf: cover)?.cgImage(forProposedRect: nil, context: nil, hints: nil)) else {
            return nil
        }
        let fps: Int64 = 30
        let frames = Int(duration * Double(fps))
        guard frames > 0 else { return nil }

        let videoURL = await TempMediaCache.shared.url(ext: "mp4")
        do {
            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
            writer.movieFragmentInterval = .zero
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: videoWidth,
                    kCVPixelBufferHeightKey as String: videoHeight
                ])
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: .zero)

            let isPortrait = videoHeight > videoWidth
            let bgRect = CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight)

            for frame in 0..<frames {
                while !input.isReadyForMoreMediaData {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                guard let pool = adaptor.pixelBufferPool else { return nil }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let pb = buffer else { return nil }

                CVPixelBufferLockBaseAddress(pb, [])
                let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(pb),
                    width: videoWidth, height: videoHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)

                if let c = context {
                    c.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1))
                    c.fill(bgRect)

                    let progress = Double(frame) / Double(max(frames - 1, 1))
                    let zoom = 1.0 + 0.14 * progress
                    // Slow diagonal drift.
                    let dx = CGFloat(isPortrait ? 0.0 : 20.0 * progress)
                    let dy = CGFloat(isPortrait ? 20.0 * progress : 0.0)

                    let drawn = imageRectAspectFill(image, view: bgRect)
                    c.saveGState()
                    c.translateBy(x: bgRect.midX + dx * (zoom - 1), y: bgRect.midY + dy * (zoom - 1))
                    c.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
                    c.translateBy(x: -bgRect.midX, y: -bgRect.midY)
                    c.interpolationQuality = .high
                    c.draw(image, in: drawn)
                    c.restoreGState()
                }

                CVPixelBufferUnlockBaseAddress(pb, [])
                adaptor.append(pb, withPresentationTime: CMTime(value: Int64(frame), timescale: CMTimeScale(fps)))
            }

            input.markAsFinished()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            if writer.status != .completed { return nil }
        } catch {
            
            return nil
        }

        // Mux video track with the audio track into a final .mov.
        let finalURL = await TempMediaCache.shared.url(ext: "mov")
        let composition = AVMutableComposition()
        let videoSource = AVURLAsset(url: videoURL)
        let audioSource = AVURLAsset(url: audio)
        do {
            let videoAssetTrack = videoSource.tracks(withMediaType: .video).first
            guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                try? FileManager.default.removeItem(at: videoURL)
                return nil
            }
            if let videoAssetTrack {
                try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoAssetTrack.timeRange.duration),
                                               of: videoAssetTrack, at: .zero)
            }
            if let audioAssetTrack = audioSource.tracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoTrack.timeRange.duration),
                                               of: audioAssetTrack, at: .zero)
            }
            guard let exporter = AVAssetExportSession(asset: composition,
                                                      presetName: AVAssetExportPresetHighestQuality) else {
                try? FileManager.default.removeItem(at: videoURL)
                return nil
            }
            exporter.outputURL = finalURL
            exporter.outputFileType = .mov
            exporter.shouldOptimizeForNetworkUse = true
            await exporter.export()
            try? FileManager.default.removeItem(at: videoURL)
            guard exporter.status == .completed else { return nil }
            return finalURL
        } catch {
            try? FileManager.default.removeItem(at: videoURL)
            return nil
        }
    }

    private static func imageRectAspectFill(_ image: CGImage, view: CGRect) -> CGRect {
        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return view }
        let scale = max(view.width / iw, view.height / ih)
        let w = iw * scale
        let h = ih * scale
        return CGRect(x: view.midX - w / 2, y: view.midY - h / 2, width: w, height: h)
    }
}

// ---------------------------------------------------------------------------
// Coordinator
// ---------------------------------------------------------------------------

/// Drives a single pack generation end-to-end: FastMusicGenerator audio → cover
/// art → optional Ken Burns video. Owned by ContentView; the Music Studio view
/// binds to its progress / stage / result state.
@MainActor
final class MusicPackCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var stage = ""
    @Published private(set) var lastPack: MusicPack?
    @Published var error: String?

    private let generator = FastMusicGenerator()
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        progress = 0
        stage = ""
        error = nil
    }

    func generate(_ spec: MusicPackSpec) {
        guard !isRunning else { return }
        let trimmedPrompt = spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            error = "Describe the music pack you want first."
            return
        }
        isRunning = true
        error = nil
        lastPack = nil
        progress = 0.02
        stage = "Preparing…"

        let quality = spec.quality.complexity
        let mood = mood(for: spec.genre)

        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // 1) Audio (fast path, zero model).
                self.stage = "Synthesizing audio…"
                self.progress = 0.08
                guard let audio = await self.generator.generate(
                    prompt: trimmedPrompt, genre: spec.genre,
                    mood: mood, complexity: quality,
                    durationSec: spec.duration) else {
                    self.fail("Audio synthesis failed.")
                    return
                }
                if Task.isCancelled { self.cancel(); return }
                self.progress = 0.5

                // 2) Cover art (procedural, no image model required).
                self.stage = "Designing cover…"
                self.progress = 0.55
                guard let cover = await MusicCoverRenderer.render(
                    title: trimmedPrompt, genre: spec.genre, aspect: spec.aspect) else {
                    self.fail("Cover art rendering failed.")
                    return
                }
                if Task.isCancelled { self.cancel(); return }
                self.progress = 0.68

                // 3) Optional Ken Burns video.
                var video: URL?
                if spec.includeVideo {
                    self.stage = "Composing video…"
                    self.progress = 0.72
                    video = await MusicPackVideoRenderer.render(
                        cover: cover, audio: audio, duration: spec.duration,
                        aspect: spec.aspect)
                    if Task.isCancelled { self.cancel(); return }
                    if video == nil {
                        self.stage = "Video failed; audio + cover kept."
                    }
                }

                self.progress = 1
                self.stage = "Done"
                self.lastPack = MusicPack(title: trimmedPrompt,
                                          audioURL: audio,
                                          coverURL: cover,
                                          videoURL: video)
                self.isRunning = false
                self.task = nil
            }
        }
    }

    private func fail(_ message: String) {
        error = message
        stage = ""
        progress = 0
        isRunning = false
        task = nil
    }

    /// Maps a mixing genre to the closest musical mood for the fast generator.
    private func mood(for genre: AudioMixer.Genre) -> FastMusicGenerator.Mood {
        switch genre {
        case .ambient, .ballad, .classical, .folk: return .calm
        case .jazz, .soul, .rnb: return .dreamy
        case .metal: return .dark
        case .hiphop, .edm, .rock, .latin, .funk: return .energetic
        default: return .uplifting
        }
    }
}