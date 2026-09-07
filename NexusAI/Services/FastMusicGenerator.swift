import Foundation
import AVFoundation

/// A zero-model, CPU-only music generator that produces short, coherent
/// instrumental beds from a prompt + genre + mood + complexity. Richer harmony
/// (per-mood chord progressions with harmonic partial stacks), a sub-bass line
/// an octave down, and a kick + hi-hat drum pattern — all rendered, normalized
/// and limited in one pass, then written as a 16-bit stereo WAV into
/// `TempMediaCache` so the rest of the app can play/export it like any other
/// generated media.
///
/// This is the "fast path" companion to `AudioMixer.synthMusic`: still zero
/// external models and near-instant, but more musical than plain sine chords.
final class FastMusicGenerator {
    enum Mood: String, CaseIterable {
        case calm, dreamy, energetic, uplifting, dark
    }

    enum Complexity: String, CaseIterable {
        case simple, medium, rich
    }

    private let sampleRate = 44100.0
    private let channels = 2

    /// Synthesizes a track and returns its temp WAV URL, or nil on failure.
    func generate(
        prompt: String,
        genre: AudioMixer.Genre,
        mood: Mood,
        complexity: Complexity,
        durationSec: Double
    ) async -> URL? {
        guard durationSec > 0.5 else { return nil }
        let totalSamples = Int(durationSec * sampleRate)

        var left = [Int16](repeating: 0, count: totalSamples)
        var right = [Int16](repeating: 0, count: totalSamples)

        let progression = chordProgression(for: genre, mood: mood)
        let chordLen = Int(sampleRate * 4.0)          // 4 seconds per chord
        let bpm = tempo(for: genre, mood: mood)
        let beatLen = 60.0 / bpm
        let beatFrame = Int(beatLen * sampleRate)

        let toneAmp: Double = complexity == .rich ? 0.16 : (complexity == .medium ? 0.20 : 0.24)
        let partialCount = complexity == .rich ? 5 : (complexity == .medium ? 4 : 3)

        for i in 0..<totalSamples {
            let chordIndex = (i / chordLen) % progression.count
            let chord = progression[chordIndex]
            let inChord = i % chordLen
            let env = envelope(pos: Double(inChord) / Double(chordLen), mood: mood)

            // Harmonic bed: sum partials with 1/p rolloff for a warm tone.
            for (idx, freq) in chord.enumerated() {
                let brightness = complexity == .rich ? 1.0 : (complexity == .medium ? 0.85 : 0.7)
                var acc = 0.0
                for p in 1...partialCount {
                    let f = freq * Double(p) * brightness
                    let v = sin(2.0 * .pi * f * Double(i) / sampleRate) / Double(p)
                    acc += v
                }
                let weight: Double = idx == 0 ? 1.0 : (idx == 1 ? 0.9 : 0.8)
                let tone = acc * toneAmp * weight * env
                addSample(tone, to: &left, &right, at: i)
            }

            // Bass an octave below the root, following the chord.
            let root = chord[0]
            let bassFreq = root * 0.5
            let bassAmp: Double = complexity == .rich ? 0.32 : 0.36
            let bass = sin(2.0 * .pi * bassFreq * Double(i) / sampleRate) * bassAmp * env
                + sin(2.0 * .pi * root * Double(i) / sampleRate) * 0.06 * env
            addSample(bass, to: &left, &right, at: i)

            // Percussion keyed to the beat grid.
            let inBeat = Double(i % beatFrame) / Double(beatFrame)
            let slow = (mood == .calm || mood == .dreamy)
            let beatPulse = slow ? (i / beatFrame) % 2 == 0 : true

            if beatPulse && inBeat < 0.10 {
                // Kick: pitch-dropping sine with fast exponential decay.
                let decay = exp(-inBeat * beatLen * 9.0)
                let t = Double(i) / sampleRate
                let kickFreq = 55.0 + (1.0 - inBeat * 10.0).clamped(to: 0...1) * 35.0
                let kick = sin(2.0 * .pi * kickFreq * t) * 0.7 * decay * 0.55
                addSample(kick, to: &left, &right, at: i)
            }

            // Hi-hat on the offbeat (and 16ths when energetic).
            let hatOnOffbeat = (inBeat >= 0.5 && inBeat < 0.53)
            let hatOnSixteenth = mood == .energetic || mood == .uplifting ? (inBeat >= 0.25 && inBeat < 0.26) : false
            if hatOnOffbeat || hatOnSixteenth {
                let decay = exp(-(inBeat >= 0.5 ? (inBeat - 0.5) : (inBeat - 0.25)) * beatLen * 40.0)
                let noise = Double.random(in: -1...1) * decay * 0.10
                let click = sin(2.0 * .pi * 9000.0 * Double(i) / sampleRate) * 0.05 * decay
                addSample(noise + click, to: &left, &right, at: i)
            }
        }

        // Master bus.
        let interleaved = interleave(left: left, right: right)
        let normalized = normalizePeak(interleaved)
        let limited = limiter(normalized, ceiling: 0.89)

        let url = await TempMediaCache.shared.url(ext: "wav")
        return writeWAV(samples: limited, sampleRate: sampleRate, channels: channels, to: url) ? url : nil
    }

    // MARK: - Music logic

    private func chordProgression(for genre: AudioMixer.Genre, mood: Mood) -> [[Double]] {
        switch mood {
        case .calm, .dreamy:
            return [
                [220.0, 261.63, 329.63],   // Am
                [174.61, 220.0, 261.63],   // F
                [196.0, 261.63, 329.63],   // C
                [196.0, 246.94, 293.66]    // G
            ]
        case .energetic, .uplifting:
            return [
                [261.63, 329.63, 392.0],   // C
                [196.0, 261.63, 329.63],   // G
                [174.61, 220.0, 261.63],   // F
                [220.0, 261.63, 329.63]    // Am
            ]
        case .dark:
            return [
                [110.0, 130.81, 164.81],   // Am (low)
                [98.0, 123.47, 146.83],    // G#dim
                [110.0, 146.83, 164.81],   // Am(add9)
                [110.0, 130.81, 164.81]
            ]
        }
    }

    private func tempo(for genre: AudioMixer.Genre, mood: Mood) -> Double {
        let base: Double
        switch mood {
        case .calm, .dreamy: base = 70
        case .energetic, .uplifting: base = 115
        case .dark: base = 90
        }
        var factor = 1.0
        switch genre {
        case .edm: factor = 1.15
        case .rock, .metal: factor = 1.1
        case .latin, .funk: factor = 1.08
        case .hiphop, .pop: factor = 1.05
        case .ambient: factor = 0.85
        case .ballad, .classical: factor = 0.92
        case .reggae: factor = 0.9
        case .jazz: factor = 0.95
        default: factor = 1.0
        }
        return base * factor
    }

    private func envelope(pos: Double, mood: Mood) -> Double {
        guard pos >= 0, pos < 1 else { return 0 }
        // 6% attack, gentle 30% release so chords breathe into each other.
        let attack = min(1.0, pos * 16.0)
        let release = min(1.0, max(0, (1.0 - pos) * 3.0))
        var env = attack * release
        if mood == .energetic { env = min(1.0, env * 1.15) }
        return env
    }

    private func addSample(_ sample: Double, to left: inout [Int16], _ right: inout [Int16], at i: Int) {
        guard i < left.count else { return }
        let s = Int16(clamping: Int(sample * 32767.0))
        left[i] = left[i] &+ s
        right[i] = right[i] &+ s
    }

    private func interleave(left: [Int16], right: [Int16]) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(left.count * 2)
        for i in 0..<left.count {
            out.append(left[i])
            out.append(right[i])
        }
        return out
    }

    private func normalizePeak(_ samples: [Int16]) -> [Int16] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0 else { return samples }
        let target = 0.9 * 32767.0
        var gain = target / Double(peak)
        if Double(peak) < 0.15 * 32767 { gain = min(gain, target / (0.15 * 32767)) }
        guard gain > 0 else { return samples }
        return samples.map { Int16(clamping: Int(Double($0) * gain)) }
    }

    private func limiter(_ samples: [Int16], ceiling: Double) -> [Int16] {
        let knee = ceiling * 0.72
        let drive = 1.0 - knee
        return samples.map { v -> Int16 in
            let av = abs(Double(v) / 32767.0)
            if av < knee { return v }
            let sign: Double = v >= 0 ? 1 : -1
            let shaped = tanh((av - knee) / max(drive, 1e-6)) * (1.0 - knee) + knee
            return Int16(clamping: Int(sign * shaped * 32767.0))
        }
    }

    private func writeWAV(samples: [Int16], sampleRate: Double, channels: Int, to url: URL) -> Bool {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        let byteRate = Int(sampleRate) * channels * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: le32(UInt32(36 + dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: le32(16))
        data.append(contentsOf: le16(1))                       // PCM
        data.append(contentsOf: le16(UInt16(channels)))
        data.append(contentsOf: le32(UInt32(sampleRate)))
        data.append(contentsOf: le32(UInt32(byteRate)))
        data.append(contentsOf: le16(UInt16(channels * bytesPerSample)))
        data.append(contentsOf: le16(16))                      // bit depth
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: le32(UInt32(dataSize)))
        for s in samples {
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

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}