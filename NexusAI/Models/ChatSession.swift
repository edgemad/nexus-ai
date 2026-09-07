import Foundation

struct ChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var isArchived: Bool
    var folderTag: String?
    /// The task-specific bot driving this conversation, if any.
    var botID: UUID?
    /// The prompt preset applied to this conversation, if any.
    var presetID: UUID?

    init(id: UUID = UUID(), title: String = "New Chat",
         messages: [ChatMessage] = [], folderTag: String? = nil,
         botID: UUID? = nil, presetID: UUID? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isPinned = false
        self.isArchived = false
        self.folderTag = folderTag
        self.botID = botID
        self.presetID = presetID
    }

    var subtitle: String {
        messages.last.map { $0.role == .user ? $0.text : "Assistant reply" } ?? "Empty chat"
    }

    mutating func touch() {
        updatedAt = Date()
    }

    // Decoding tolerates older saved files that predate optional fields
    // like botID/presetID, so previously saved chats are never dropped.
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, isPinned, isArchived, folderTag, botID, presetID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New Chat"
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        folderTag = try c.decodeIfPresent(String.self, forKey: .folderTag)
        botID = try c.decodeIfPresent(UUID.self, forKey: .botID)
        presetID = try c.decodeIfPresent(UUID.self, forKey: .presetID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(messages, forKey: .messages)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encodeIfPresent(folderTag, forKey: .folderTag)
        try c.encodeIfPresent(botID, forKey: .botID)
        try c.encodeIfPresent(presetID, forKey: .presetID)
    }
}