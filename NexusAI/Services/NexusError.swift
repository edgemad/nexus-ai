import Foundation

/// Machine-readable failure categories shared across subsystems (providers,
/// sidecars, tools, research, memory). Every surfaced error should carry a
/// code so the UI can act (retry, configure, escalate) instead of guessing.
enum NexusErrorCode: String, Codable, CaseIterable, Equatable {
    case modelUnavailable
    case modelDownloadFailed
    case modelCorrupted
    case sidecarUnavailable
    case memoryUnavailable
    case researchFailed
    case sourceNotFetched
    case noSourcesRetrieved
    case toolBlocked
    case toolTimeout
    case approvalDenied
    case approvalExpired
    case apiKeyMissing
    case apiKeyInvalid
    case cloudUnavailable
    case networkUnavailable
    case taskCancelled
    case permissionDenied
    case fileNotFound
    case invalidInput
    case notSupported
    case unknown
}

/// A typed, codable error value: safe to log, store in a run history, or show
/// to the user. Never embed API keys or other secrets in any field.
struct NexusError: Error, Codable, Equatable {
    var code: NexusErrorCode
    var message: String
    var retryable: Bool
    var requestID: String?

    init(_ code: NexusErrorCode, _ message: String, retryable: Bool = false,
         requestID: String? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.requestID = requestID
    }

    static func fail(_ code: NexusErrorCode, _ message: String,
                     retryable: Bool = false, requestID: String? = nil) -> NexusError {
        NexusError(code, message, retryable: retryable, requestID: requestID)
    }
}

/// Short, unique, sortable IDs for tracing one request through sidecars,
/// tools, memory, research, and diagnostics. `prefix` groups the stream
/// (e.g. "shell", "research", "mmx").
enum RequestID {
    static func make(prefix: String = "req") -> String {
        let stamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let tail = String(format: "%06x", UInt32.random(in: 0..<0x1000000))
        return "\(prefix)-\(stamp)-\(tail)"
    }
}