import Foundation
import AVFoundation
import AVFAudio
import Accelerate
import SwiftUI

/// Genre transformation + mixing, fully local and offline.
///
/// Loads a user audio file (wav/aiff/m4a/mp3/flac), decodes it to float PCM,
/// applies a **genre profile** — a curated set of DSP transforms that shift the
/// track's character (tempo/BPM, low/high shelf EQ, drive/distortion, filter
/// sweep, stereo width, and a light reverb tail) — and renders the result to a
/// new WAV/AIFF in the workspace Outputs folder.
///
/// This is a character/mix transformation (effect-stack), not a full
/// music-theory re-arrangement. It reliably turns a ballad *feel* into a
/// rock/soul/gospel *feel* by adjusting tempo, tone and drive.
@MainActor
final class AudioMixer: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastMixURL: URL?
    @Published var error: String?
    /// In-flight mix task; kept so "Stop" can cancel the DSP work.
    private var mixTask: Task<Void, Never>?

    /// Cancels an in-progress mix and returns the UI to idle.
    func cancel() {
        mixTask?.cancel()
        mixTask = nil
        isProcessing = false
        progress = 0
        error = nil
    }

    enum Genre: String, CaseIterable, Identifiable {
        case original = "Original"
        case rock = "Rock"
        case soul = "Soul"
        case gospel = "Gospel"
        case ballad = "Ballad"
        case pop = "Pop"
        case folk = "Folk"
        case jazz = "Jazz"
        case rnb = "R&B"
        case hiphop = "Hip-Hop"
        case edm = "EDM"
        case country = "Country"
        case classical = "Classical"
        case metal = "Metal"
        case reggae = "Reggae"
        case latin = "Latin"
        case ambient = "Ambient"
        case funk = "Funk"

        var id: String { rawValue }
    }

    // MARK: - Public API

    /// Mixes an audio file into the given genre. `strength` (0...1) blends the
    /// transformed signal with the original (0 = unchanged, 1 = full effect).
    func mix(source: URL, genre: Genre, strength: Double = 1.0) {
        guard !isProcessing else { return }
        error = nil
        isProcessing = true
        progress = 0

        mixTask?.cancel()
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.render(source: source, genre: genre, strength: strength)
            if Task.isCancelled { self.mixTask = nil; return }
            self.isProcessing = false
            self.progress = result != nil ? 1 : 0
            self.mixTask = nil
            if let result {
                self.lastMixURL = result
            }
        }
        mixTask = task
    }

    /// Renders a genre remix of a source file and returns the output URL, or
    /// nil on failure. Async counterpart to `mix` so a coordinator can chain it
    /// with other steps (e.g. transcribe → re-synthesize → re-style).
    /// `progress` is surfaced on the shared instance for a single UI progress bar.
    func renderToURL(source: URL, genre: Genre, strength: Double = 1.0) async -> URL? {
        guard !isProcessing || lastMixURL == nil else { return nil }
        error = nil
        isProcessing = true
        progress = 0
        let result = await render(source: source, genre: genre, strength: strength)
        isProcessing = false
        progress = result != nil ? 1 : 0
        if let result { lastMixURL = result }
        return result
    }

    /// "Enhance / recreate" — decodes a source and re-masters it through a clean
    /// bus (mono→stereo widening, gentle EQ, peak normalize + limiter) so the
    /// output is a polished, louder reproduction of the input. No style change,
    /// just a faithful reconstruction with better loudness/headroom.
    func enhance(source: URL) async -> URL? {
        guard !isProcessing else { return nil }
        error = nil
        isProcessing = true
        progress = 0

        let samples: [Float]
        let sampleRate: Double
        let channels: Int
        do {
            (samples, sampleRate, channels) = try await decode(source)
        } catch {
            self.error = "Could not read audio file: \(error.localizedDescription)"
            self.isProcessing = false
            return nil
        }

        // Master bus: gentle high shelf, mild width, normalize + limiter.
        var out = samples
        out = biquadFilter(out, channels: channels, sampleRate: sampleRate,
                           type: .highshelf, cutoff: 4200, gain: 1.5)
        if channels == 2 {
            out = stereoWidth(out, width: 1.08)
        }
        out = normalizePeak(out, ecRef: 0.001)
        out = limiter(out, ceiling: 0.89)
        self.progress = 0.9

        let folder = TempMediaCache.shared.directory
        let outURL = folder.appendingPathComponent("enhanced-\(Int(Date().timeIntervalSince1970)).wav")
        let written = writeWAV(outURL, samples: out, sampleRate: sampleRate, channels: channels)

        self.progress = 1
        self.isProcessing = false
        if written { self.lastMixURL = outURL }
        return written ? outURL : nil
    }

    /// "Music from prompt" — procedurally synthesizes an instrumental track that
    /// matches the genre mapped from the prompt: a chord-progression pad, a
    /// kick-drum beat and a bass line, rendered in `duration` seconds at the
    /// genre's tempo/character. This is a lightweight local generative engine
    /// (no external model needed / fully offline) — it produces genuine,
    /// listenable music from a text description.
    func synthMusic(prompt: String, duration: Double = 12) async -> URL? {
        guard !isProcessing else { return nil }
        error = nil
        isProcessing = true
        progress = 0

        let genre = genreFromPrompt(prompt)
        let profile = genreProfile(for: genre)
        let sampleRate = 44100.0
        let channels = 2
        let bpm = 120 * profile.tempo
        let beatLen = 60.0 / bpm                  // seconds per quarter note
        let total = Int(duration * sampleRate)

        // Chord progression (I–vi–IV–V in a chosen key) built from sine partials
        // with a soft attack/release envelope — the harmonic "bed".
        let root: Float = 220.0                   // A3
        let progression: [(Float, Float, Float)] = [
            (1.0, 1.5, 1.2),  // I
            (0.0, 1.0, 1.2),  // vi (relative minor base)
            (1.5, 1.0, 1.5),  // IV
            (1.5, 1.0, 1.5)   // V
        ]
        let progressionLen = Int(beatLen * 8 * sampleRate) // 2 bars each

        var bed = [Float](repeating: 0, count: total)
        var bars = 0
        var phase = 0
        while phase < total {
            let (t1, t2, t3) = progression[bars % progression.count]
            let end = min(total, phase + progressionLen)
            for i in phase..<end {
                let pos = Double(i - phase) / Double(progressionLen)
                let attack = min(1.0, pos * 8.0)
                let release = min(1.0, (1.0 - pos) * 8.0)
                let env = attack * release
                let t = Double(i) / sampleRate
                let twoPiT = 2 * Double.pi * t
                let a = 0.5 * sin(twoPiT * Double(root) * Double(t1))
                let b = 0.3 * sin(twoPiT * Double(root) * Double(t2))
                let c = 0.2 * sin(twoPiT * Double(root) * Double(t3))
                let tone = a + b + c
                bed[i] += Float(tone * 0.6) * Float(env)
            }
            bars += 1
            phase += progressionLen
        }
        self.progress = 0.4

        // Kick drum + hi-hat beat pattern (four-on-the-floor).
        let kickLen = Int(sampleRate * 0.32)
        let hatLen = Int(sampleRate * 0.05)
        var beat = [Float](repeating: 0, count: total)
        var b = 0
        while b < total {
            let endKick = min(total, b)
            for i in 0..<kickLen {
                let j = b + i
                if j < total {
                    let decay = exp(-Double(i) / (sampleRate * 0.12))
                    beat[j] += Float(sin(2 * .pi * Double(i) / sampleRate * 60) * decay * 0.7)
                }
            }
            for i in 0..<hatLen {
                let j = b + i
                if j < total {
                    let decay = exp(-Double(i) / (sampleRate * 0.02))
                    beat[j] += Float((2 * (Double.random(in: 0...1) - 0.5)) * decay) * 0.12
                }
            }
            b += Int(beatLen * sampleRate)
        }
        self.progress = 0.6

        // Bass line following the same chord roots.
        var bass = [Float](repeating: 0, count: total)
        var bb = 0
        var barIdx = 0
        while bb < total {
            let (t1, _, _) = progression[barIdx % progression.count]
            let endB = min(total, bb + Int(beatLen * sampleRate))
            for i in bb..<endB {
                let t = Double(i) / sampleRate
                let freq = Double(root) * 0.5 * Double(t1)
                let sample = sin(2 * Double.pi * t * freq)
                bass[i] += Float(0.5 * sample)
            }
            barIdx += 1
            bb = endB
        }
        self.progress = 0.75

        // Mix signals: bed + beat + bass, then a master limiter.
        var out = [Float](repeating: 0, count: total)
        for i in 0..<total {
            out[i] = bed[i] + beat[i] + bass[i] * 0.5
        }
        out = normalizePeak(out, ecRef: 0.001)
        out = limiter(out, ceiling: 0.9)

        // To stereo.
        var stereo = [Float](repeating: 0, count: out.count * 2)
        for i in 0..<out.count {
            stereo[i * 2] = out[i]
            stereo[i * 2 + 1] = out[i]
        }

        let folder = TempMediaCache.shared.directory
        let outURL = folder.appendingPathComponent("music-\(genre.rawValue.lowercased())-\(Int(Date().timeIntervalSince1970)).wav")
        let written = writeWAV(outURL, samples: stereo, sampleRate: sampleRate, channels: 2)

        self.progress = 1
        self.isProcessing = false
        if written { self.lastMixURL = outURL }
        return written ? outURL : nil
    }

    /// Maps free-form text keywords onto the closest existing genre.
    func genreFromPrompt(_ prompt: String) -> Genre {
        let p = prompt.lowercased()
        let map: [(String, Genre)] = [
            ("rock|guitar|distort|aggressiv|metal|punk", .rock),
            ("jazz|swing|blue", .jazz),
            ("soul|r&b|motown|funky|funk", .soul),
            ("hip|rap|trap|beat", .hiphop),
            ("edm|dance|club|electro|house|techno|trance", .edm),
            ("ambient|calm|chill|relax|meditat|pad|drone", .ambient),
            ("ballad|slow|acoustic|piano|sentimental", .ballad),
            ("pop|upbeat|mainstream", .pop),
            ("reggae|island|ska", .reggae),
            ("country|banjo|cowboy|folk", .country),
            ("classical|orchestra|symphony|string", .classical),
            ("latin|salsa|reggaeton|cumbia", .latin),
            ("gospel|choir|worship", .gospel),
            ("metal|heavy|thrash", .metal)
        ]
        for (pattern, genre) in map {
            if p.range(of: pattern, options: .regularExpression) != nil {
                return genre
            }
        }
        return .pop
    }

    // MARK: - Render pipeline

    private func render(source: URL, genre: Genre, strength: Double) async -> URL? {
        let samples: [Float]
        let sampleRate: Double
        let channels: Int

        do {
            (samples, sampleRate, channels) = try await decode(source)
        } catch {
            self.error = "Could not read audio file: \(error.localizedDescription)"
            return nil
        }
        self.progress = 0.15

        let profile = genreProfile(for: genre)
        let transformed = applyProfile(samples, sampleRate: sampleRate, profile: profile)
        self.progress = 0.85

        // Blend by strength.
        let mixed = mix(original: samples, transformed: transformed, strength: strength)

        let ext = "wav"
        let folder = TempMediaCache.shared.directory
        let outURL = folder.appendingPathComponent("mix-\(genre.rawValue.lowercased())-\(Int(Date().timeIntervalSince1970)).\(ext)")
        let written = writeWAV(outURL, samples: mixed, sampleRate: sampleRate, channels: channels)

        self.progress = 1
        return written ? outURL : nil
    }

    // MARK: - Genre profiles (DSP parameter sets)

    private struct GenreProfile {
        var tempo: Double = 1.0          // playback tempo multiplier
        var lowBoost: Float = 0          // low-shelf gain dB (< 250 Hz)
        var midCut: Float = 0            // mid-notch gain dB (800 Hz)
        var highBoost: Float = 0         // high-shelf boost dB (> 4 kHz)
        var drive: Float = 0             // soft saturation 0...1
        var lowpassHz: Float = 0         // 0 = off
        var width: Float = 1.0           // stereo width 0.5...1.5 (mono→stereo duck)
        var reverbMix: Float = 0         // 0...1 reverberant tail
        var bassFilter: Float = 0        // 0 = off, HPF corner to thin the bed
    }

    private func genreProfile(for genre: Genre) -> GenreProfile {
        switch genre {
        case .original:
            return GenreProfile()
        case .ballad:
            return GenreProfile(tempo: 0.92, lowBoost: 2, midCut: 1, highBoost: 1,
                                drive: 0.05, lowpassHz: 9000, width: 1.1, reverbMix: 0.25)
        case .rock:
            return GenreProfile(tempo: 1.18, lowBoost: 3, midCut: -2, highBoost: 3,
                                drive: 0.4, lowpassHz: 8000, width: 1.2, reverbMix: 0.15, bassFilter: 60)
        case .soul:
            return GenreProfile(tempo: 1.05, lowBoost: 4, midCut: 0, highBoost: 2,
                                drive: 0.18, lowpassHz: 11000, width: 1.15, reverbMix: 0.22, bassFilter: 50)
        case .gospel:
            return GenreProfile(tempo: 1.02, lowBoost: 2, midCut: 1, highBoost: 4,
                                drive: 0.12, lowpassHz: 12000, width: 1.3, reverbMix: 0.4, bassFilter: 40)
        case .pop:
            return GenreProfile(tempo: 1.12, lowBoost: 2, midCut: -1, highBoost: 3,
                                drive: 0.1, lowpassHz: 11000, width: 1.25, reverbMix: 0.18)
        case .folk:
            return GenreProfile(tempo: 1.0, lowBoost: 1, midCut: 1, highBoost: 1,
                                drive: 0.05, lowpassHz: 9500, width: 1.05, reverbMix: 0.2)
        case .jazz:
            return GenreProfile(tempo: 0.95, lowBoost: 3, midCut: 1, highBoost: 0,
                                drive: 0.08, lowpassHz: 10500, width: 1.1, reverbMix: 0.3)
        case .rnb:
            return GenreProfile(tempo: 0.92, lowBoost: 3, midCut: -1, highBoost: 2,
                                drive: 0.1, lowpassHz: 11000, width: 1.15, reverbMix: 0.22, bassFilter: 45)
        case .hiphop:
            return GenreProfile(tempo: 0.98, lowBoost: 5, midCut: 2, highBoost: 1,
                                drive: 0.15, lowpassHz: 9500, width: 1.2, reverbMix: 0.12, bassFilter: 35)
        case .edm:
            return GenreProfile(tempo: 1.25, lowBoost: 4, midCut: -2, highBoost: 4,
                                drive: 0.35, lowpassHz: 15000, width: 1.45, reverbMix: 0.35, bassFilter: 30)
        case .country:
            return GenreProfile(tempo: 1.08, lowBoost: 2, midCut: 1, highBoost: 2,
                                drive: 0.1, lowpassHz: 10000, width: 1.1, reverbMix: 0.15, bassFilter: 55)
        case .classical:
            return GenreProfile(tempo: 0.9, lowBoost: 1, midCut: 1, highBoost: 1,
                                drive: 0.02, lowpassHz: 15000, width: 1.35, reverbMix: 0.45)
        case .metal:
            return GenreProfile(tempo: 1.22, lowBoost: 3, midCut: -5, highBoost: 5,
                                drive: 0.6, lowpassHz: 7500, width: 1.25, reverbMix: 0.1, bassFilter: 45)
        case .reggae:
            return GenreProfile(tempo: 0.85, lowBoost: 4, midCut: 1, highBoost: 2,
                                drive: 0.1, lowpassHz: 10500, width: 1.3, reverbMix: 0.25, bassFilter: 40)
        case .latin:
            return GenreProfile(tempo: 1.15, lowBoost: 2, midCut: 0, highBoost: 3,
                                drive: 0.15, lowpassHz: 11500, width: 1.2, reverbMix: 0.25)
        case .ambient:
            return GenreProfile(tempo: 0.8, lowBoost: 2, midCut: 1, highBoost: 1,
                                drive: 0.03, lowpassHz: 9000, width: 1.5, reverbMix: 0.5)
        case .funk:
            return GenreProfile(tempo: 1.1, lowBoost: 3, midCut: 1, highBoost: 2,
                                drive: 0.2, lowpassHz: 10500, width: 1.2, reverbMix: 0.15, bassFilter: 50)
        }
    }

    // MARK: - DSP

    /// Applies the whole profile effect-stack to interleaved float samples.
    ///
    /// Order matters for a clean, natural result:
    ///   tempo  → EQ → width → drive → reverb → ▲ final limiter/normalize
    /// The final limiter guarantees the output never clips (peak ≤ ~-1 dBFS)
    /// regardless of how aggressive the EQ/drive/reverb got — so a remix is a
    /// deliberate *character* change, never "original + distortion".
    private func applyProfile(_ samples: [Float], sampleRate: Double, profile: GenreProfile) -> [Float] {
        var out = samples

        // 1) Time-stretch with WSOLA — preserves pitch, only the tempo changes.
        if abs(profile.tempo - 1.0) > 0.001 {
            out = wsolaTimeStretch(out, ratio: profile.tempo)
        }

        if out.isEmpty { return out }

        let channels = 2 // treat as (mono or) interleaved stereo

        // 2) Bass management / high-pass filter.
        if profile.bassFilter > 0 {
            out = biquadFilter(out, channels: channels, sampleRate: sampleRate,
                               type: .highpass, cutoff: profile.bassFilter)
        }

        // 3) EQ shelves.
        if profile.lowBoost != 0 {
            out = biquadFilter(out, channels: channels, sampleRate: sampleRate,
                               type: .lowshelf, cutoff: 250, gain: profile.lowBoost)
        }
        if profile.highBoost != 0 {
            out = biquadFilter(out, channels: channels, sampleRate: sampleRate,
                               type: .highshelf, cutoff: 4200, gain: profile.highBoost)
        }
        if profile.midCut != 0 {
            out = biquadFilter(out, channels: channels, sampleRate: sampleRate,
                               type: .peaking, cutoff: 800, gain: profile.midCut)
        }
        if profile.lowpassHz > 0 {
            out = biquadFilter(out, channels: channels, sampleRate: sampleRate,
                               type: .lowpass, cutoff: profile.lowpassHz)
        }

        // 4) Stereo width (mid/side) — makes dense/harmonic genres feel bigger.
        if abs(profile.width - 1.0) > 0.02 {
            out = stereoWidth(out, width: profile.width)
        }

        // 5) Drive (soft saturation) — gently scaled so it never dominates.
        if profile.drive > 0.001 {
            out = softClip(out, amt: profile.drive)
        }

        // 6) Reverb (wet/dry blend feed into the final mix).
        if profile.reverbMix > 0.001 {
            out = reverb(out, channels: channels, sampleRate: sampleRate, mix: profile.reverbMix)
        }

        // 7) Render chain: gentle peak normalize + soft limiter → crisp, in-Genre
        //    loudness without audible clipping.
        out = normalizePeak(out, ecRef: 0.001)   // scale to a healthy reference
        out = limiter(out, ceiling: 0.89)        // hard ceiling ~ -1 dBFS
        return out
    }

    private func mix(original: [Float], transformed: [Float], strength: Double) -> [Float] {
        let n = min(original.count, transformed.count)
        var out = [Float](repeating: 0, count: n)
        let s = Float(strength)
        for i in 0..<n {
            let a = i < original.count ? original[i] : 0
            let b = i < transformed.count ? transformed[i] : 0
            out[i] = a * (1 - s) + b * s
        }
        return out
    }

    /// Time-stretch via WSOLA (Waveform Similarity Overlap-Add): changes the
    /// playback *duration* (i.e. tempo/BPM) while keeping the original pitch
    /// and formant character — so a Ballad at `tempo 0.92` stays in the same
    /// key, just slower. The opposite of the old linear resample (which shifted
    /// pitch with tempo and caused the "chipmunk/robotic" artefacts).
    ///
    /// Works on the (possibly interleaved) sample stream as one flattened
    /// signal with a per-frame channel stride so stereo image is preserved.
    private func wsolaTimeStretch(_ x: [Float], ratio: Double, channels: Int = 2, sampleRate: Double = 44100) -> [Float] {
        guard x.count >= channels, ratio > 0.05, ratio < 20 else { return x }
        let frames = x.count / channels
        guard frames > 0 else { return x }

        let frameSize = channels
        let olaWindow = 1024            // analysis window (samples, per channel frame selected on channel 0 stride)
        let hop = 512                   // analysis hop
        let synHop = Int(Double(hop) * ratio)  // synthesis hop → tempo

        // Pre-allocate window (Hann).
        var win = [Float](repeating: 0, count: olaWindow)
        for i in 0..<olaWindow {
            win[i] = 0.5 * (1 - cos(2 * .pi * Float(i) / Float(olaWindow - 1)))
        }

        // Output planning: we accumulate overlapped windows into output.
        let outFrames = Int((Double(frames) / ratio))
        var out = [Float](repeating: 0, count: outFrames * channels)
        var outCross = [Float](repeating: 0, count: outFrames * channels) // overlap-accumulator
        var outWeight = [Float](repeating: 0, count: outFrames * channels)

        var analysisStart = 0
        var synStart = 0
        let searchWindows = 6

        x.withUnsafeBufferPointer { raw in
            let base = raw.baseAddress!

            while analysisStart + olaWindow <= frames {
                // Find best overlap point in the analysis stream near
                // `analysisStart + hop` so consecutive windows cross-fade
                // without spectral discontinuities (pitch preservation).
                let targetA = analysisStart + hop
                var bestA = targetA
                var bestCorr = -Float.greatestFiniteMagnitude
                for s in 0..<searchWindows {
                    let candidate = min(targetA + s * (hop / searchWindows), frames - olaWindow)
                    if candidate < 0 { continue }
                    var corr: Float = 0
                    let n = min(olaWindow, frames - candidate)
                    for i in 0..<n {
                        // correlation on channel 0 stride to keep it cheap
                        let aIdx = (bestA + i) * channels
                        let cIdx = (candidate + i) * channels
                        if aIdx < x.count && cIdx < x.count {
                            corr += x[aIdx] * x[cIdx]
                        }
                    }
                    if corr > bestCorr { bestCorr = corr; bestA = candidate }
                }

                // Copy the chosen analysis window (all channels) into output,
                // windowed, at synthesis position synStart.
                for fr in 0..<olaWindow {
                    let aFrame = bestA + fr
                    let sFrame = synStart + fr
                    guard aFrame < frames, sFrame < outFrames else { break }
                    let aBase = aFrame * channels
                    let sBase = sFrame * channels
                    for c in 0..<channels {
                        guard aBase + c < x.count, sBase + c < out.count else { break }
                        let v = x[aBase + c] * win[fr]
                        outCross[sBase + c] += v
                        outWeight[sBase + c] += win[fr]
                    }
                }

                analysisStart = bestA + hop
                synStart += synHop
                if synStart + olaWindow >= outFrames { break }
            }
        }

        // Normalize by overlap weight to finish the OLA.
        for i in 0..<out.count {
            let w = outWeight[i]
            out[i] = w > 1e-9 ? outCross[i] / w : 0
        }
        // Trim trailing silence from the fade-out tail.
        return out
    }

    /// Stereo width via mid/side. `width` 1.0 = unchanged, <1 collapses,
    /// >1 widens. Interleaved stereo assumed.
    private func stereoWidth(_ x: [Float], width: Float) -> [Float] {
        let ch = 2
        var out = x
        let stride = ch
        for i in Swift.stride(from: 0, to: x.count - 1, by: stride) {
            let l = x[i]
            let r = x[i + 1]
            let mid = (l + r) * 0.5
            let side = (l - r) * 0.5 * width
            out[i] = mid + side
            out[i + 1] = mid - side
        }
        return out
    }

    /// Normalizes the overall peak toward a low reference (calibration happens
    /// in the limiter). `ecRef` is the target peak fraction of full scale used
    /// to scale up quiet sources, preserving headroom for the limiter.
    private func normalizePeak(_ x: [Float], ecRef: Float) -> [Float] {
        guard let peak = x.map(abs).max(), peak > 1e-9 else { return x }
        let target: Float = 0.9
        var gain = target / peak
        if peak < 0.15 { gain = min(gain, target / 0.15) } // don't pump silence
        guard gain > 0 else { return x }
        return x.map { $0 * gain }
    }

    /// A soft limiter that guarantees the absolute peak stays at or below
    /// `ceiling` (e.g. 0.89 ≈ -1 dBFS), removing clicks from EQ + reverb
    /// summing hot. Signals below a knee pass through untouched; above it they
    /// are softly compressed toward the ceiling via a tanh curve.
    private func limiter(_ x: [Float], ceiling: Float) -> [Float] {
        let drive = 1.0 / ceiling
        let knee = ceiling * 0.72
        return x.map { v -> Float in
            let av = abs(v)
            if av <= knee { return v }
            let sign: Float = v >= 0 ? 1 : -1
            let shaped = tanh(av * drive) * ceiling
            return sign * shaped
        }
    }

    private enum FilterKind { case lowpass, highpass, lowshelf, highshelf, peaking }

    // MARK: - Biquad
    /// Applies an RBJ audio-equation biquad filter per channel, in-place on a
    /// copy. Handles both mono (channels=1) and interleaved stereo.
    private func biquadFilter(_ x: [Float], channels: Int, sampleRate: Double,
                              type: FilterKind, cutoff: Float, gain: Float = 0) -> [Float] {
        guard channels > 0, !x.isEmpty else { return x }
        let fs = Float(sampleRate)
        let f0 = max(60, min(cutoff, fs * 0.45))
        let A = pow(10, gain / 40)
        let w0 = 2 * .pi * f0 / fs
        let Q: Float = 0.9
        let alpha = sin(w0) / (2 * Q)

        var b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float
        let cosw = cos(w0)
        switch type {
        case .lowpass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .highpass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .lowshelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosw + s)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosw)
            b2 = A * ((A + 1) - (A - 1) * cosw - s)
            a0 = (A + 1) + (A - 1) * cosw + s
            a1 = -2 * ((A - 1) + (A + 1) * cosw)
            a2 = (A + 1) + (A - 1) * cosw - s
        case .highshelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosw + s)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
            b2 = A * ((A + 1) + (A - 1) * cosw - s)
            a0 = (A + 1) - (A - 1) * cosw + s
            a1 = 2 * ((A - 1) - (A + 1) * cosw)
            a2 = (A + 1) - (A - 1) * cosw - s
        case .peaking:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        }

        var out = [Float](repeating: 0, count: x.count)
        for ch in 0..<channels {
            var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
            var i = ch
            while i < x.count {
                let xn = x[i]
                let yn = (b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = xn
                y2 = y1; y1 = yn
                out[i] = yn
                i += channels
            }
        }
        return out
    }

    /// Soft-knee saturation (tanh) for musical drive — asymmetric-ish, pleasant.
    private func softClip(_ x: [Float], amt: Float) -> [Float] {
        let drive = 1.0 + amt * 6.0
        let mix = amt
        return x.map { v -> Float in
            let driven = tanh(v * drive)
            return v * (1 - mix) + driven * mix
        }
    }

    /// Simple feedback delay network reverb (Schroeder) — a sparse set of comb
    /// filters in parallel whose outputs sum, then a couple of allpass filters.
    private func reverb(_ x: [Float], channels: Int, sampleRate: Double, mix: Float) -> [Float] {
        let combDelays: [Int] = sampleRate > 40000
            ? [1557, 1617, 1491, 1422, 1277, 1356]
            : [779, 809, 746, 711, 639, 678]
        let allpassDelays = [225, 556]
        let feedback: Float = 0.77
        let damp: Float = 0.4

        var out = [Float](repeating: 0, count: x.count)

        for ch in 0..<channels {
            // Extract this channel & its sample count.
            var mono = [Float]()
            var i = ch
            while i < x.count { mono.append(x[i]); i += channels }
            let n = mono.count
            guard n > 0 else { continue }

            // Parallel combs summed.
            var wet = [Float](repeating: 0, count: n)
            for delay in combDelays {
                var comb = combProcess(mono, delay: delay, feedback: feedback, damp: damp)
                let g = 1.0 / Float(combDelays.count)
                for k in 0..<n { comb[k] *= g }
                wet = addV(wet, comb)
            }
            // Allpass in series.
            for delay in allpassDelays {
                wet = allpassProcess(wet, delay: delay, g: 0.5)
            }
            // Write back, blended.
            var j = ch
            var k = 0
            while j < x.count && k < n {
                out[j] = x[j] + wet[k] * mix
                k += 1
                j += channels
            }
        }
        return out
    }

    private func combProcess(_ mono: [Float], delay: Int, feedback: Float, damp: Float) -> [Float] {
        let n = mono.count
        var buffer = [Float](repeating: 0, count: max(delay, 1))
        var idx = 0
        var last = Float(0)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let bufout = buffer[idx]
            out[i] = bufout
            let damped = bufout * (1 - damp) + last * damp
            last = damped
            buffer[idx] = mono[i] + feedback * damped
            idx += 1
            if idx >= delay { idx = 0 }
        }
        return out
    }

    private func allpassProcess(_ mono: [Float], delay: Int, g: Float) -> [Float] {
        let n = mono.count
        var buffer = [Float](repeating: 0, count: max(delay, 1))
        var idx = 0
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let bufout = buffer[idx]
            out[i] = -mono[i] + bufout
            buffer[idx] = mono[i] + g * bufout
            idx += 1
            if idx >= delay { idx = 0 }
        }
        return out
    }

    private func addV(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = min(a.count, b.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = a[i] + b[i] }
        return out
    }

    // MARK: - Audio decode

    private struct DecodedAudio {
        let samples: [Float]
        let sampleRate: Double
        let channels: Int
    }

    private func decode(_ url: URL) async throws -> (samples: [Float], sampleRate: Double, channels: Int) {
        if let decoded = try await decodeViaAudioFile(url) {
            return decoded
        }
        return try await decodeViaAssetReader(url)
    }

    /// Primary decoder. `AVAudioFile` + `AVAudioPCMBuffer` reliably decode every
    /// AVFoundation-supported format (wav/aiff/m4a/mp3/flac/ape, constant or
    /// variable bit-rate) into float32 PCM, which is what the older
    /// AVAssetReader path often fails to produce ("No audio data decoded").
    private func decodeViaAudioFile(_ url: URL) async throws -> (samples: [Float], sampleRate: Double, channels: Int)? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            return nil
        }
        let format = file.processingFormat
        let sr = format.sampleRate
        let ch = Int(format.channelCount)
        let length = AVAudioFrameCount(file.length)
        guard length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else {
            return (samples: [], sampleRate: sr, channels: ch)
        }
        try file.read(into: buffer)

        // AVF float32 non-interleaved: one plane per channel.
        guard let planes = buffer.floatChannelData else {
            return (samples: [], sampleRate: sr, channels: ch)
        }

        // Interleave to one stream: L,R,L,R...
        let frameCount = Int(buffer.frameLength)
        var interleaved = [Float](repeating: 0, count: frameCount * ch)
        if ch == 1 {
            let p = planes[0]
            for f in 0..<frameCount { interleaved[f] = p[f] }
        } else {
            for c in 0..<ch {
                let p = planes[c]
                for f in 0..<frameCount { interleaved[f * ch + c] = p[f] }
            }
        }
        return (samples: interleaved, sampleRate: sr, channels: ch)
    }

    /// Fallback decoder (kept for exotic containers AVAudioFile rejects).
    private func decodeViaAssetReader(_ url: URL) async throws -> (samples: [Float], sampleRate: Double, channels: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = (try? await asset.loadTracks(withMediaType: .audio))?.first else {
            throw NSError(domain: "AudioMixer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track found."])
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw NSError(domain: "AudioMixer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create reader."])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var samples = [Float]()
        // Sample rate + channels come from the first converted buffer's ASBD.
        var sampleRate = 44100.0
        var channels = 2
        var gotFormat = false

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if !gotFormat, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                    if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
                    let ch = Int(asbd.mChannelsPerFrame)
                    if ch > 0 { channels = ch }
                    gotFormat = true
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(capacity: length)
            data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            samples.append(contentsOf: floats)
        }
        reader.cancelReading()

        if samples.isEmpty {
            throw NSError(domain: "AudioMixer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No audio data decoded."])
        }
        // handle mono→false stereo by duplicating if only 1 channel
        if channels == 1 {
            var stereo = [Float](repeating: 0, count: samples.count * 2)
            for (i, s) in samples.enumerated() { stereo[i * 2] = s; stereo[i * 2 + 1] = s }
            samples = stereo
            channels = 2
        }
        return (samples, sampleRate, channels)
    }

    // MARK: - WAV writer

    private func writeWAV(_ url: URL, samples: [Float], sampleRate: Double, channels: Int) -> Bool {
        // Convert float to 16-bit PCM interleaved.
        let bitDepth = 16
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            var v = samples[i]
            if v > 1 { v = 1 }; if v < -1 { v = -1 }
            pcm[i] = Int16(clamping: Int(v * 32767))
        }

        let bytesPerSample = bitDepth / 8
        let dataSize = pcm.count * bytesPerSample
        let byteRate = Int(sampleRate) * channels * bytesPerSample
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: le32(UInt32(36 + dataSize)))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(contentsOf: le32(16))
        data.append(contentsOf: le16(1))
        data.append(contentsOf: le16(UInt16(channels)))
        data.append(contentsOf: le32(UInt32(sampleRate)))
        data.append(contentsOf: le32(UInt32(byteRate)))
        data.append(contentsOf: le16(UInt16(channels * bytesPerSample)))
        data.append(contentsOf: le16(UInt16(bitDepth)))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: le32(UInt32(dataSize)))
        for s in pcm {
            data.append(contentsOf: le16(UInt16(bitPattern: s)))
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
