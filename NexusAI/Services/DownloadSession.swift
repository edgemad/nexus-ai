import Foundation

/// A single progressing model download backed by URLSessionDownloadTask so it
/// streams to disk (never loads into RAM) and reports real byte-level progress.
///
/// URLSession follows the HF `resolve/…` → CDN 302 redirect automatically; the
/// delegate only observes `didWriteData` to report progress and moves the
/// finished file into place. Each session handles exactly one download, so many
/// can run concurrently — coordination lives in the caller (ModelStore).
final class DownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// In-flight sessions keyed by destination path, so a second request for the
    /// same file waits on the existing one instead of duplicating the work.
    /// These static helpers are called from arbitrary `Task`s (different model
    /// downloads run concurrently), so access is guarded by a lock.
    private static var pending: [String: DownloadSession] = [:]
    private static let pendingLock = NSLock()

    /// Returns the existing session for `dest` or creates + stores a new one.
    /// The returned closure is invoked under the lock so only one session ever
    /// exists per destination.
    static func pendingSession(for dest: URL,
                               make: () -> DownloadSession) -> DownloadSession {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if let existing = pending[dest.path] { return existing }
        let s = make()
        pending[dest.path] = s
        return s
    }

    static func removePending(for dest: URL) {
        pendingLock.lock()
        pending[dest.path] = nil
        pendingLock.unlock()
    }

    private let destination: URL
    private var continuation: CheckedContinuation<Bool, Never>?
    private var onProgress: (Double) -> Void = { _ in }
    private var session: URLSession?
    private var didFinish = false
    private var task: URLSessionDownloadTask?

    /// Serial queue so delegate callbacks (delivered on an arbitrary thread)
    /// update the caller's progress/success state on one consistent thread.
    private let callbackQueue = DispatchQueue(label: "nexus.download", qos: .userInitiated)

    /// The smallest a real model file can ever be. GGUF/safetensors checkpoints
    /// are hundreds of MB; anything far tinier is an HTTP error page that must
    /// not be saved as an "installed model" (it would pass `fileExists` but
    /// fail every load attempt).
    private let minimumValidModelBytes: Int64 = 10 * 1024 * 1024 // 10 MB

    init(destination: URL) {
        self.destination = destination
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForResource = 7200 // very large models take a long while
        cfg.timeoutIntervalForRequest = 120   // let slow-first-byte CDNs be patient
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// Runs the download and returns success. Safe to call once per instance.
    func run(from url: URL, onProgress: @escaping (Double) -> Void) async -> Bool {
        self.onProgress = onProgress
        try? FileManager.default.removeItem(at: destination)
        let download = session?.downloadTask(with: url)
        download?.resume()
        task = download
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                if didFinish { c.resume(returning: false) } else { continuation = c }
            }
        } onCancel: {
            // Resume must happen exactly once; if cancelled mid-flight, finish.
            task?.cancel()
            callbackQueue.async { [weak self] in self?.finish(success: false) }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, totalBytesWritten > 0 else { return }
        let fraction = min(0.999, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        // Progress callbacks update SwiftUI @MainActor state, so deliver them
        // on the main thread to avoid a data race (the delegate fires on a
        // background queue).
        DispatchQueue.main.async { [weak self] in self?.onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // IMPORTANT: the temp file at `location` is only guaranteed to exist
        // during this delegate call, so move it into place synchronously here
        // (URLSession cleans it up when the callback returns). Only the
        // success reporting is deferred to the serial queue.
        //
        // Validation: HF `resolve/…` redirects (302) to a CDN and the delegate
        // observes the final response. A failed/404 download returns a tiny
        // error page (e.g. 15-byte "Entry not found") that would otherwise be
        // saved as a "model" and then fail at load time. Reject non-200
        // responses and anything too small to ever be a real model so the app
        // reports a clear download error instead of a phantom installed file.
        let placed: Bool
        var validSize = false
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: location.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            validSize = bytes >= minimumValidModelBytes
        } catch {
            validSize = false
        }
        let statusOK = (downloadTask.response as? HTTPURLResponse)?.statusCode == 200
        let isValid = statusOK && validSize
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if isValid {
                try FileManager.default.moveItem(at: location, to: destination)
            } else {
                try? FileManager.default.removeItem(at: location)
            }
            placed = true
        } catch {
            placed = false
        }
        let ok = placed && isValid && FileManager.default.fileExists(atPath: destination.path)
        callbackQueue.async { [weak self] in self?.finish(success: ok) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            callbackQueue.async { [weak self] in self?.finish(success: false) }
        }
    }

    private func finish(success: Bool) {
        guard !didFinish else { return }
        didFinish = true
        continuation?.resume(returning: success)
        continuation = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
