import Foundation
import AVFoundation
import AppKit

/// A shared, disposable media player that can play BOTH audio files
/// (AVAudioPlayer) and video files (AVPlayer) with explicit play / pause / stop
/// controls. One instance is owned by ContentView and shared between the Audio
/// and Movie studios so a single playing item is interrupted cleanly when the
/// user starts another.
@MainActor
final class MediaPlayer: ObservableObject {
    enum Kind: Equatable {
        case audio
        case video
    }

    @Published private(set) var url: URL?
    @Published private(set) var kind: Kind = .audio
    @Published private(set) var isLoaded = false
    @Published private(set) var isPlaying = false
    @Published private(set) var rate: Float = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published var error: String?

    private var audioPlayer: AVAudioPlayer?
    private var avPlayer: AVPlayer?
    private var timeObserver: Any?

    /// Loads the given media and prepares for playback (does not auto-play).
    func load(_ url: URL, kind: Kind) {
        stop()
        self.url = url
        self.kind = kind

        switch kind {
        case .audio:
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.prepareToPlay()
                p.volume = 1.0
                audioPlayer = p
                duration = p.duration
                isLoaded = true
                error = nil
            } catch {
                self.error = "Could not load audio: \(error.localizedDescription)"
                isLoaded = false
            }
        case .video:
            loadVideo(url)
        }
    }

    /// Loads an in-memory audio buffer for playback (no file on disk).
    /// Used for generated speech so it never needs to be written/saved.
    func loadAudio(_ data: Data) {
        stop()
        self.kind = .audio
        do {
            let p = try AVAudioPlayer(data: data)
            p.prepareToPlay()
            p.volume = 1.0
            audioPlayer = p
            duration = p.duration
            isLoaded = true
            error = nil
        } catch {
            self.error = "Could not load audio: \(error.localizedDescription)"
            isLoaded = false
        }
    }

    private func loadVideo(_ url: URL) {
        self.url = url
        let p = AVPlayer(url: url)
        avPlayer = p
        isLoaded = true
        error = nil
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                 queue: .main) { [weak self] t in
            Task { @MainActor in self?.currentTime = t.seconds }
        }
        Task { @MainActor [weak self] in
            guard let item = p.currentItem else { return }
            let seconds = try? await item.asset.load(.duration).seconds
            if let seconds, seconds.isFinite { self?.duration = seconds }
        }
    }

    func playPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard isLoaded else { return }
        switch kind {
        case .audio:
            audioPlayer?.play()
        case .video:
            avPlayer?.play()
        }
        isPlaying = true
        rate = 1
    }

    func pause() {
        guard isLoaded else { return }
        switch kind {
        case .audio:
            audioPlayer?.pause()
        case .video:
            avPlayer?.pause()
        }
        isPlaying = false
        rate = 0
    }

    /// Stops playback, rewinds to the start, and releases the loaded media.
    func stop() {
        guard isLoaded else { return }
        switch kind {
        case .audio:
            audioPlayer?.stop()
            audioPlayer = nil
        case .video:
            avPlayer?.pause()
            if let obs = timeObserver { avPlayer?.removeTimeObserver(obs) }
            timeObserver = nil
            avPlayer = nil
        }
        isLoaded = false
        isPlaying = false
        rate = 0
        currentTime = 0
        url = nil
    }

    /// For a video player, expose the underlying AVPlayer (used by AVKit's
    /// VideoPlayer view for the on-screen transport controls).
    func avPlayerForVideo() -> AVPlayer? { avPlayer }

    deinit {
        if let obs = timeObserver { avPlayer?.removeTimeObserver(obs) }
    }
}
