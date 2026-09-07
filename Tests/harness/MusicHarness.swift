import Foundation

/// Verifies the fast music generator (audio synthesis), procedural cover art,
/// and Ken Burns video pipeline from the command line. Exercises the same code
/// paths that Music Studio drives in the UI.
@main
struct MusicHarness {
    static func main() async {
        var failures = 0

        // Force TempMediaCache initialization on MainActor before any I/O.
        _ = await MainActor.run { _ = TempMediaCache.shared.directory }

        // 1. Fast audio generation (calm / simple / 6 s).
        do {
            let fast = FastMusicGenerator()
            if let url = await fast.generate(prompt: "calm ambient pad",
                                             genre: .ambient,
                                             mood: .calm,
                                             complexity: .simple,
                                             durationSec: 6) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int) ?? 0
                if size > 10_000 {
                    print("PASS calm-audio (\(size) bytes)")
                } else {
                    print("FAIL calm-audio too small (\(size) bytes)")
                    failures += 1
                }
            } else {
                print("FAIL calm-audio returned nil")
                failures += 1
            }
        }

        // 2. Fast audio generation (energetic / rich / 8 s).
        do {
            let fast = FastMusicGenerator()
            if let url = await fast.generate(prompt: "energetic metal riff",
                                             genre: .metal,
                                             mood: .energetic,
                                             complexity: .rich,
                                             durationSec: 8) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int) ?? 0
                if size > 20_000 {
                    print("PASS energetic-audio (\(size) bytes)")
                } else {
                    print("FAIL energetic-audio too small (\(size) bytes)")
                    failures += 1
                }
            } else {
                print("FAIL energetic-audio returned nil")
                failures += 1
            }
        }

        // 3. Cover art (square, ambient).
        do {
            if let url = await MusicCoverRenderer.render(title: "Test cover art",
                                                          genre: .ambient,
                                                          aspect: .square) {
                let data = try? Data(contentsOf: url)
                if let data, data.count > 5_000 {
                    print("PASS cover-art (\(data.count) bytes)")
                } else {
                    print("FAIL cover-art too small (\(data?.count ?? 0) bytes)")
                    failures += 1
                }
            } else {
                print("FAIL cover-art returned nil")
                failures += 1
            }
        }

        // 4. Full pipeline: audio + cover + video (5 s, square aspect).
        do {
            let fast = FastMusicGenerator()
            guard let audio = await fast.generate(prompt: "dreamy synth pad",
                                                  genre: .edm,
                                                  mood: .dreamy,
                                                  complexity: .medium,
                                                  durationSec: 5) else {
                print("FAIL pipeline-audio returned nil")
                failures += 1
                return
            }
            guard let cover = await MusicCoverRenderer.render(title: "Pipeline test",
                                                              genre: .edm,
                                                              aspect: .square) else {
                print("FAIL pipeline-cover returned nil")
                failures += 1
                return
            }
            if let video = await MusicPackVideoRenderer.render(cover: cover, audio: audio,
                                                               duration: 5, aspect: .square) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: video.path)
                let size = (attrs?[.size] as? Int) ?? 0
                if size > 20_000 {
                    print("PASS pipeline-video (\(size) bytes)")
                } else {
                    print("FAIL pipeline-video too small (\(size) bytes)")
                    failures += 1
                }
            } else {
                print("FAIL pipeline-video returned nil")
                failures += 1
            }
        }

        // 5. AudioMixer genre prompt mapping still works (unchanged regression).
        do {
            let mixer = AudioMixer()
            let tests: [(String, AudioMixer.Genre)] = [
                ("ambient relaxing music", .ambient),
                ("hard rock guitar", .rock),
                ("jazz swing", .jazz),
                ("edm club dance", .edm)
            ]
            var allCorrect = true
            for (prompt, expected) in tests {
                let got = mixer.genreFromPrompt(prompt)
                if got != expected { allCorrect = false }
            }
            if allCorrect { print("PASS genre-mapping") } else {
                print("FAIL genre-mapping"); failures += 1
            }
        }

        if failures == 0 {
            print("ALL MUSIC CHECKS PASSED")
        } else {
            print("\(failures) MUSIC CHECK(S) FAILED")
            exit(1)
        }
    }
}