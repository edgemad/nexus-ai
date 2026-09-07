import Foundation

@main
struct StoreHarness {
    @MainActor
    static func main() async {
        let fileManager = FileManager.default
        let dataDir = PersistenceController.shared.dataURL

        let activityFile = dataDir.appendingPathComponent("activity.json")
        let approvalsFile = dataDir.appendingPathComponent("approvals.json")
        let automationsFile = dataDir.appendingPathComponent("automations.json")
        let tasksFile = dataDir.appendingPathComponent("tasks.json")
        let actionsFile = dataDir.appendingPathComponent("actions.json")
        let historyFile = dataDir.appendingPathComponent("approval_history.json")
        for f in [activityFile, approvalsFile, automationsFile, tasksFile, actionsFile, historyFile] {
            try? fileManager.removeItem(at: f)
        }

        // Activity: log, verify persisted + restored (colorName survives).
        let a = ActivityStore()
        a.log(icon: "test", title: "Harness event", detail: "detail", color: .purple)
        let a2 = ActivityStore()
        print("activity restore:", a2.events.count == 1 && a2.events[0].colorName == "purple" ? "PASS" : "FAIL")

        // Approvals: add returns a UUID and stores no closures on disk.
        let ap = ApprovalStore()
        let apID = ap.add(title: "Harness approval", detail: "d")
        let raw = String(data: try! Data(contentsOf: approvalsFile), encoding: .utf8) ?? ""
        let ap2 = ApprovalStore()
        print("approval restore:", ap2.items.count == 1 && ap2.items[0].id == apID ? "PASS" : "FAIL")
        print("approval closure not persisted:", !raw.contains("onDecision") ? "PASS" : "FAIL")

        // Event-driven decision: subscribing by ID sees appends AND decisions.
        var events: [(UUID, Bool)] = []
        let token = ap2.subscribe { id, allow in events.append((id, allow)) }
        ap2.decide(approvalID: apID, allow: true)
        print("decision event fired:", events.count == 1 && events[0].0 == apID && events[0].1 ? "PASS" : "FAIL")

        // Decision persists status.
        let ap3 = ApprovalStore()
        print("approval status persisted:", ap3.items[0].status == .approved ? "PASS" : "FAIL")

        // Events are keyed: deciding an unrelated id must NOT fire this listener.
        let otherID = ap3.add(title: "Other", detail: "d2")
        ap3.decide(approvalID: otherID, allow: false)
        print("stream is ID-keyed:", events.count == 1 ? "PASS" : "FAIL")
        print("history records decision:", ap3.history.count == 2 && ap3.history[0].verdict == .denied && ap3.history[1].verdict == .approved ? "PASS" : "FAIL")
        print("history persists:", ap3.history.allSatisfy { $0.approvalID == apID || $0.approvalID == otherID } ? "PASS" : "FAIL")

        // History survives a new store instance (restore path).
        let apRestore = ApprovalStore()
        print("history restores:", apRestore.history.count == 2 ? "PASS" : "FAIL")

        // Expired pending auto-denies and still fires the stream (no closure).
        let ap4 = ApprovalStore()
        var expiryEvents: [(UUID, Bool)] = []
        let token2 = ap4.subscribe { id, allow in expiryEvents.append((id, allow)) }
        let expired = ApprovalItem(title: "expired", detail: "d", icon: "gear",
                                   requestedAt: Date().addingTimeInterval(-700),
                                   status: .pending,
                                   expiresAt: Date().addingTimeInterval(-60))
        ap4.items.insert(expired, at: 0)
        ap4.sweepExpired()
        print("approval expiry denied:", ap4.items[0].status == .denied ? "PASS" : "FAIL")
        print("expiry event fired:", expiryEvents.count == 1 && expiryEvents[0].1 == false ? "PASS" : "FAIL")
        print("expiry recorded:", ap4.history.first?.verdict == .expired ? "PASS" : "FAIL")
        _ = token
        _ = token2

        // Automation: add/remove round trip.
        let au = AutomationStore()
        au.add(name: "Harness automation", schedule: "Every 1 hour")
        let au2 = AutomationStore()
        print("automation restore:", au2.automations.count == 1 && au2.automations[0].name == "Harness automation" ? "PASS" : "FAIL")

        // Task: create (waitingForApproval) -> start -> restore mid-flight.
        let t = TaskStore()
        let task = t.create(title: "Harness task", steps: ["Step one", "Step two"], requiresApproval: true)
        print("task waiting:", task.status == .waitingForApproval ? "PASS" : "FAIL")
        t.start(task.id)
        let t2 = TaskStore()
        print("task restore running:", t2.tasks.count == 1 && t2.tasks[0].status == .running && t2.tasks[0].currentStepIndex == 0 ? "PASS" : "FAIL")

        // AgentAction: Codable round trip (status raw strings + approvalID link).
        let action = AgentAction(kind: .runCommand, command: "ls", fromMessageID: UUID(),
                                 approvalID: apID, result: nil, status: .pending)
        let saved: [AgentAction] = [action, AgentAction(kind: .openURL, command: "https://x",
                                                       fromMessageID: action.id, approvalID: otherID,
                                                       result: "done", status: .done)]
        PersistenceController.shared.save(saved, file: "actions")
        let restored = PersistenceController.shared.load([AgentAction].self, file: "actions") ?? []
        print("actions round trip:", restored.count == 2 && restored[0].approvalID == apID && restored[1].status == .done ? "PASS" : "FAIL")

        for f in [activityFile, approvalsFile, automationsFile, tasksFile, actionsFile, historyFile] {
            try? fileManager.removeItem(at: f)
        }
        print("store harness done")
    }
}