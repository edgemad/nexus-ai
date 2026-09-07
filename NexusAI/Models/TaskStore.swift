import Foundation
import SwiftUI

struct TaskStep: Identifiable, Codable {
    var id = UUID()
    var title: String
    var status: TaskRecord.Status

    init(_ title: String, status: TaskRecord.Status = .planned) {
        self.title = title
        self.status = status
    }
}

struct TaskRecord: Identifiable, Codable {
    var id = UUID()
    var title: String
    var steps: [TaskStep]
    var status: Status
    var requiresApproval: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Where the runner currently is; surfaced so resumed tasks continue where
    /// they left off after a relaunch.
    var currentStepIndex: Int
    var result: String?

    enum Status: String, Codable {
        case planned, waitingForApproval, running, paused, completed, failed, cancelled

        var label: String {
            switch self {
            case .planned: return "Planned"
            case .waitingForApproval: return "Waiting for approval"
            case .running: return "Running"
            case .paused: return "Paused"
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        var color: Color {
            switch self {
            case .planned: return .gray
            case .waitingForApproval: return .yellow
            case .running: return .blue
            case .paused: return .orange
            case .completed: return .green
            case .failed: return .red
            case .cancelled: return .secondary
            }
        }
    }
}

/// Durable registry of multi-step, potentially approval-gated work. Distinct
/// from the automation scheduler: tasks are one-shot units of work that the
/// agent (or the user) creates and that survive relaunches, unlike the
/// read-only scheduled automations list.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskRecord] = []

    init() {
        if let saved = PersistenceController.shared.loadOrMigrate([TaskRecord].self, file: "tasks") {
            tasks = saved
        }
        // No demo data: tasks are a genuine working set, not a showcase.
    }

    @discardableResult
    func create(title: String, steps: [String], requiresApproval: Bool = true) -> TaskRecord {
        let record = TaskRecord(
            title: title,
            steps: steps.map { TaskStep($0) },
            status: requiresApproval ? .waitingForApproval : .planned,
            requiresApproval: requiresApproval,
            createdAt: Date(),
            updatedAt: Date(),
            currentStepIndex: 0,
            result: nil
        )
        tasks.insert(record, at: 0)
        persist()
        return record
    }

    func start(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard [.planned, .waitingForApproval, .paused, .failed].contains(tasks[i].status) else { return }
        tasks[i].status = .running
        tasks[i].updatedAt = Date()
        if let stepIdx = tasks[i].steps.firstIndex(where: { $0.status == .planned }) {
            tasks[i].steps[stepIdx].status = .running
            tasks[i].currentStepIndex = stepIdx
        }
        persist()
    }

    /// Marks a step completed and advances the task to the next planned step,
    /// or completes the whole task when no steps remain.
    func markStepCompleted(_ taskID: UUID, _ stepID: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }),
              let j = tasks[i].steps.firstIndex(where: { $0.id == stepID }),
              tasks[i].steps[j].status != .completed else { return }
        tasks[i].steps[j].status = .completed
        tasks[i].updatedAt = Date()
        if let next = tasks[i].steps.firstIndex(where: { $0.status == .planned }) {
            tasks[i].status = .running
            tasks[i].currentStepIndex = next
        } else {
            tasks[i].status = .completed
            tasks[i].result = nil
        }
        persist()
    }

    func setStatus(_ id: UUID, _ status: TaskRecord.Status) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].status = status
        tasks[i].updatedAt = Date()
        persist()
    }

    func setResult(_ id: UUID, _ result: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].result = result
        tasks[i].updatedAt = Date()
        persist()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        tasks.removeAll()
        persist()
    }

    private func persist() {
        PersistenceController.shared.save(tasks, file: "tasks")
    }
}