import Foundation

/// Test-only WorkspaceManager so PersistenceController (and therefore the
/// stores under test) writes into a throwaway temp directory instead of the
/// real ~/NexusAI Workspace/Data/ during `xcodebuild test`.
@MainActor
final class WorkspaceManager {
    static let shared = WorkspaceManager()
    private(set) var rootURL: URL
    private init() {
        rootURL = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("NexusTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
}