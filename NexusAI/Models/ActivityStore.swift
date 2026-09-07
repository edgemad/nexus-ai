import Foundation
import SwiftUI

struct ActivityEvent: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let icon: String
    let title: String
    let detail: String
    let colorName: String

    /// SwiftUI `Color` is not Codable-friendly across versions, so events carry
    /// a stable color *name* and resolve it back for display only.
    var color: Color {
        ActivityEvent.color(from: colorName)
    }

    init(date: Date = Date(), icon: String, title: String, detail: String, color: Color = .blue) {
        self.date = date
        self.icon = icon
        self.title = title
        self.detail = detail
        self.colorName = ActivityEvent.name(of: color)
    }

    private static func name(of color: Color) -> String {
        let map: [(Color, String)] = [
            (.red, "red"), (.orange, "orange"), (.yellow, "yellow"), (.green, "green"),
            (.blue, "blue"), (.purple, "purple"), (.pink, "pink"), (.teal, "teal"),
            (.cyan, "cyan"), (.gray, "gray"), (.white, "white"), (.black, "black"),
        ]
        return map.first { $0.0 == color }?.1 ?? "blue"
    }

    private static func color(from name: String) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        case "cyan": return .cyan
        case "gray": return .gray
        case "white": return .white
        case "black": return .black
        default: return .blue
        }
    }
}

@MainActor
final class ActivityStore: ObservableObject {
    @Published var events: [ActivityEvent] = []

    init() {
        if let saved = PersistenceController.shared.loadOrMigrate([ActivityEvent].self, file: "activity") {
            events = saved
        } else if AssistantSettings.shared.demoMode {
            // Sample data loads only in Demo mode; a fresh install starts empty.
            loadSample()
        }
    }

    func log(icon: String, title: String, detail: String, color: Color = .blue) {
        events.insert(ActivityEvent(date: Date(), icon: icon, title: title, detail: detail, color: color), at: 0)
        persist()
    }

    func flushAll() {
        events.removeAll()
        persist()
    }

    private func persist() {
        PersistenceController.shared.save(events, file: "activity")
    }

    private func loadSample() {
        let now = Date()
        events = [
            ActivityEvent(date: now.addingTimeInterval(-300), icon: "checkmark.shield", title: "Approval granted",
                          detail: "Allowed Norton AI to access ~/Projects/api-keys.json", color: .green),
            ActivityEvent(date: now.addingTimeInterval(-900), icon: "chart.line.uptrend.xyaxis", title: "System check completed",
                          detail: "CPU 34%, memory 62%, disk 45% — all normal", color: .blue),
            ActivityEvent(date: now.addingTimeInterval(-1800), icon: "doc.text", title: "File indexed",
                          detail: "Added 12 documents from ~/Documents/Research", color: .purple),
            ActivityEvent(date: now.addingTimeInterval(-3600), icon: "bubble.left.and.bubble.right", title: "Chat session ended",
                          detail: "Summarized and stored 3 new facts to memory", color: .orange),
            ActivityEvent(date: now.addingTimeInterval(-7200), icon: "clock.arrow.circlepath", title: "Automation ran",
                          detail: "“Daily brief” completed at 8:00 AM", color: .teal)
        ]
    }
}