import Foundation
import SwiftUI

/// Manages the on-disk workspace folder, chat persistence, and archives.
@MainActor
final class WorkspaceManager: ObservableObject {
    @Published private(set) var rootURL: URL

    @Published var outputsURL: URL
    @Published var modelsURL: URL
    @Published var archivesURL: URL
    @Published var chatsURL: URL
    var profileDataURL: URL {
        rootURL.appendingPathComponent("profiles.json")
    }

    static let shared = WorkspaceManager()

    private init() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("NexusAI Workspace", isDirectory: true)
        rootURL = root
        outputsURL = root.appendingPathComponent("Outputs", isDirectory: true)
        modelsURL = root.appendingPathComponent("Models", isDirectory: true)
        archivesURL = root.appendingPathComponent("Archives", isDirectory: true)
        chatsURL = root.appendingPathComponent("Chats", isDirectory: true)
        createFolders()
    }

    func ensure() {
        createFolders()
    }

    private func createFolders() {
        for url in [rootURL, outputsURL, modelsURL, archivesURL, chatsURL] {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    /// A unique output subfolder for generated media, sorted by date.
    func newOutputFolder() -> URL {
        let fm = DateFormatter()
        fm.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = outputsURL.appendingPathComponent(fm.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Chat persistence

    func saveChat(_ chat: ChatSession) throws {
        let data = try JSONEncoder().encode(chat)
        let url = chatsURL.appendingPathComponent("\(chat.id.uuidString).chat.json")
        try data.write(to: url, options: .atomic)
    }

    func loadChats() -> [ChatSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: chatsURL,
                                                      includingPropertiesForKeys: nil) else { return [] }
        var chats: [ChatSession] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let chat = try? JSONDecoder().decode(ChatSession.self, from: data) {
                chats.append(chat)
            }
        }
        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }

    func deleteChatFile(_ chat: ChatSession) {
        let url = chatsURL.appendingPathComponent("\(chat.id.uuidString).chat.json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Move a chat's JSON into the archive or to a destination folder.
    func archiveChat(_ chat: ChatSession) {
        let src = chatsURL.appendingPathComponent("\(chat.id.uuidString).chat.json")
        let dest = archivesURL.appendingPathComponent("\(chat.id.uuidString).chat.json")
        if FileManager.default.fileExists(atPath: src.path) {
            try? FileManager.default.moveItem(at: src, to: dest)
        }
    }
}
