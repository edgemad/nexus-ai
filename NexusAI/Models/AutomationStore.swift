import Foundation
import SwiftUI

struct Automation: Identifiable, Codable {
    var id = UUID()
    var name: String
    var schedule: String
    var status: Status
    var lastRun: String

    enum Status: String, Codable {
        case active = "active"
        case paused = "paused"
        case completed = "completed"

        var color: Color {
            switch self {
            case .active: return .green
            case .paused: return .yellow
            case .completed: return .blue
            }
        }
    }
}

@MainActor
final class AutomationStore: ObservableObject {
    @Published var automations: [Automation] = []

    init() {
        if let saved = PersistenceController.shared.loadOrMigrate([Automation].self, file: "automations") {
            automations = saved
        } else if AssistantSettings.shared.demoMode {
            // Sample data loads only in Demo mode; a fresh install starts empty.
            loadSample()
        }
    }

    func toggle(_ item: Automation) {
        if let idx = automations.firstIndex(where: { $0.id == item.id }) {
            automations[idx].status = (item.status == .active) ? .paused : .active
        }
        persist()
    }

    func remove(_ item: Automation) {
        automations.removeAll { $0.id == item.id }
        persist()
    }

    func add(name: String, schedule: String) {
        automations.insert(Automation(name: name, schedule: schedule,
                                      status: .active, lastRun: "Never"), at: 0)
        persist()
    }

    private func persist() {
        PersistenceController.shared.save(automations, file: "automations")
    }

    private func loadSample() {
        automations = [
            Automation(name: "Daily brief", schedule: "Every day at 8:00 AM", status: .active, lastRun: "Today, 8:00 AM"),
            Automation(name: "Weekly sync", schedule: "Every Monday at 9:00 AM", status: .active, lastRun: "Mon, 9:00 AM"),
            Automation(name: "Folder watcher", schedule: "On change: ~/Downloads", status: .paused, lastRun: "Fri, 3:22 PM"),
            Automation(name: "Backup memory", schedule: "Every 12 hours", status: .active, lastRun: "Today, 4:00 AM")
        ]
    }
}
