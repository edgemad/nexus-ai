import Foundation

@main
struct MiniVideoTest {
    static func main() async {
        print("MINI START")
        let fast = FastMusicGenerator()
        guard let audio = await fast.generate(prompt: "test", genre: .ambient, mood: .calm, complexity: .simple, durationSec: 3) else {
            print("MINI audio nil"); return
        }
        print("MINI audio ok")
        guard let cover = await MusicCoverRenderer.render(title: "T", genre: .ambient, aspect: .square) else {
            print("MINI cover nil"); return
        }
        print("MINI cover ok")
        let video = await MusicPackVideoRenderer.render(cover: cover, audio: audio, duration: 3, aspect: .square)
        print("MINI video = \(String(describing: video))")
    }
}