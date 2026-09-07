import AppKit
import SwiftUI

/// Glue between the SwiftUI lifecycle and the long-running local backends.
///
/// - `applicationDidFinishLaunching`: warms the llama, image (sd), and audio
///   (whisper / kokoro) backends in the background so they are already running
///   by the time the user asks for a generation — no cold-start wait.
/// - `applicationWillTerminate`: tears every backend process down cleanly so
///   no orphaned servers keep using the 16 GB machine's memory after quit.
final class NexusAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Diagnostics.shared.beginSession() }
        log("applicationDidFinishLaunching")
        installSignalHandler()
        // Respect an explicit opt-out, but default to auto-start on.
        let shouldAutoStart = !UserDefaults.standard.bool(forKey: "disableAutoStartBackends")
        guard shouldAutoStart else {
            log("auto-start disabled via UserDefaults")
            return
        }

        Task { @MainActor in
            // Ensure every store's migration chain is registered before the
            // first store loads, so older data upgrades on boot regardless of
            // when the UI touches a store.
            ModelMigrations.registerAll()
            log("migrations registered")
            BackendManager.shared.startAll()
            log("startAll() invoked")
            // Rolling backups of the durable stores: baseline at launch, then on
            // an interval and after bursts of store writes.
            BackupManager.shared.startScheduling()
            log("backup scheduler started")
            // Pre-warm whisper/Kokoro audio so the first speech request is instant.
            let speech = SpeechEngine(backend: BackendManager.shared)
            await speech.prewarmAudio()
            log("audio prewarm complete")
            // Periodically clear generated-media temp files so nothing persisted
            // from a previous session lingers (media only exists while running).
            startMediaCachePurger()
            // Version ritual: detect a version change since last run. On an
            // upgrade, force a backup first, then verify the snapshot.
            UpdateManager.shared.onUpgraded = {
                BackupManager.shared.backupNow(force: true)
            }
            UpdateManager.shared.onVerifySnapshot = {
                BackupManager.shared.verifyLatestSnapshot()
            }
            UpdateManager.shared.begin()
            log("update manager began")
        }
    }

    private var purgeTimer: Timer?
    @MainActor private func startMediaCachePurger() {
        TempMediaCache.shared.prune(olderThan: 60)
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                // Generous threshold so media currently on screen/playing isn't
                // removed mid-session; the real cleanup happens on quit.
                TempMediaCache.shared.prune(olderThan: 3600)
            }
        }
    }

    /// Several exit paths (a SIGTERM from Finder's Force Quit, session logout,
    /// or pkill) never call `applicationWillTerminate`. Trap SIGTERM so orphaned
    /// backends are always cleaned up whatever the exit route.
    private var termSource: DispatchSourceSignal?
    private func installSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler {
            self.log("SIGTERM received — stopping backends")
            // The source is bound to .main, so we're already on the main actor.
            MainActor.assumeIsolated {
                Diagnostics.shared.markCleanExit()
                BackendManager.shared.stopAll()
                TempMediaCache.shared.clearAll()
            }
            self.log("backends stopped on SIGTERM")
            exit(0)
        }
        termSource?.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("applicationWillTerminate")
        // Termination must be synchronous: we're about to exit, so async work
        // (Task) would never be awaited before the process ends. stopAll() is
        // @MainActor and this callback already runs on the main thread.
        MainActor.assumeIsolated {
            Diagnostics.shared.markCleanExit()
            BackendManager.shared.stopAll()
            TempMediaCache.shared.clearAll()
        }
        log("stopAll() complete")
    }

    private func log(_ msg: String) {
        MainActor.assumeIsolated {
            Diagnostics.shared.record(.debug, source: "app", msg)
        }
        let line = "[\(Date())] \(msg)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("NexusAI Workspace/logs/appdelegate.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}
