import Foundation

@MainActor
final class WorkspaceManager {
    static let shared = WorkspaceManager()
    private(set) var rootURL: URL
    private init() {
        rootURL = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("NexusHarness", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
}