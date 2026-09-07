import SwiftUI

/// How verbose the assistant should be by default.
enum DetailLevel: String, Codable, CaseIterable, Identifiable {
    case brief = "Brief"
    case normal = "Normal"
    case detailed = "Detailed"
    var id: String { rawValue }
}

struct UserProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var iconName: String // SF Symbol name
    var accent: String   // hex color for the profile tint
    // Extra identity/preferences so the assistant can personalize its replies.
    var tagline: String = ""        // one-line description / role
    var preferences: String = ""    // how the user likes things
    var language: String = "English"
    var detailLevel: DetailLevel = .normal

    init(id: UUID = UUID(), name: String, iconName: String = "person.crop.circle.fill",
         accent: String = "4E9B6E", tagline: String = "",
         preferences: String = "", language: String = "English", detailLevel: DetailLevel = .normal) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.accent = accent
        self.tagline = tagline
        self.preferences = preferences
        self.language = language
        self.detailLevel = detailLevel
    }

    /// A short system-prompt fragment describing the active user.
    var contextLine: String {
        var parts = [name]
        if !tagline.isEmpty { parts.append(tagline) }
        if !preferences.isEmpty { parts.append("prefers \(preferences)") }
        if language.caseInsensitiveCompare("English") != .orderedSame {
            parts.append("respond in \(language)")
        }
        return parts.joined(separator: ". ") + "."
    }
}

/// Manages user profiles, each with identity and preferences, persisted to disk.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [UserProfile] = []
    @Published var activeProfileID: UUID?

    /// The single shared instance used across the app (theme, chat, views).
    static let shared = ProfileStore()

    private static let file = WorkspaceManager.shared.profileDataURL

    var activeProfile: UserProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    init() {
        load()
        if profiles.isEmpty {
            // First run: create a starter profile so the UI always has one.
            profiles = [UserProfile(name: "You", iconName: "person.crop.circle.fill", accent: "4E9B6E")]
            activeProfileID = profiles[0].id
            save()
        }
    }

    /// Adds a brand-new profile and makes it active (used for new users).
    @discardableResult
    func createProfile(name: String, icon: String?, accent: String?,
                       tagline: String, preferences: String, language: String,
                       detailLevel: DetailLevel = .normal) -> UserProfile {
        let p = UserProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Profile" : name,
            iconName: icon ?? "person.circle",
            accent: accent ?? "4E9B6E",
            tagline: tagline,
            preferences: preferences,
            language: language,
            detailLevel: detailLevel
        )
        profiles.append(p)
        activeProfileID = p.id
        save()
        return p
    }

    func addProfile() {
        _ = createProfile(name: "New Profile", icon: nil, accent: nil, tagline: "", preferences: "", language: "English")
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name
        save()
    }

    func setIcon(_ id: UUID, _ icon: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].iconName = icon
        save()
    }

    func updateProfile(_ id: UUID, tagline: String? = nil, preferences: String? = nil,
                       language: String? = nil, accent: String? = nil, name: String? = nil,
                       detailLevel: DetailLevel? = nil) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let name { profiles[i].name = name }
        if let tagline { profiles[i].tagline = tagline }
        if let preferences { profiles[i].preferences = preferences }
        if let language { profiles[i].language = language }
        if let accent { profiles[i].accent = accent }
        if let detailLevel { profiles[i].detailLevel = detailLevel }
        save()
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        let decoder = JSONDecoder()
        if let p = try? decoder.decode([UserProfile].self, from: data) {
            profiles = p
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    static let iconChoices = [
        "person.crop.circle.fill", "person.circle", "star.circle.fill",
        "moon.circle.fill", "bolt.circle.fill", "flame.circle.fill",
        "leaf.circle.fill", "hare.circle.fill", "tortoise.circle.fill",
        "capsule.circle.fill", "figure.mind.and.body", "sparkles"
    ]

    static let accentChoices = ["4E9B6E", "2F6FD8", "9B59B6", "E74C3C", "E67E22", "16A085", "34495E"]
}
