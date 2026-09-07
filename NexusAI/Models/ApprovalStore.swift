import Foundation
import SwiftUI

struct ApprovalItem: Identifiable, Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, detail, icon, requestedAt, status, expiresAt
    }

    var id = UUID()
    let title: String
    let detail: String
    let icon: String
    let requestedAt: Date
    var status: Status
    /// Pending approvals auto-deny once this time passes so stale permission
    /// requests can't hang in the queue (or approve long after the user has
    /// forgotten about them).
    var expiresAt: Date = Date().addingTimeInterval(600)

    enum Status: String, Codable {
        case pending, approved, denied

        var label: String {
            switch self {
            case .pending: return "Pending"
            case .approved: return "Approved"
            case .denied: return "Denied"
            }
        }

        var color: Color {
            switch self {
            case .pending: return .yellow
            case .approved: return .green
            case .denied: return .red
            }
        }
    }
}

/// A resolved approval verdict, kept in an append-only durable log so past
/// decisions stay auditable after the pending item scrolls away.
struct ApprovalDecision: Identifiable, Codable {
    var id = UUID()
    let approvalID: UUID
    let title: String
    let detail: String
    let icon: String

    enum Verdict: String, Codable {
        case approved, denied, expired

        var label: String {
            switch self {
            case .approved: return "Approved"
            case .denied: return "Denied"
            case .expired: return "Auto-denied (expired)"
            }
        }
    }

    var verdict: Verdict
    var requestedAt: Date
    var decidedAt: Date

    /// How long the user (or the expiry timer) took to decide.
    var duration: TimeInterval { decidedAt.timeIntervalSince(requestedAt) }
}

/// Retains an approval subscription for as long as the token is held alive.
final class ApprovalSubscription {
    private let onCancel: () -> Void
    fileprivate init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    deinit { onCancel() }
}

/// The durable, event-driven approval registry. Decisions (approve, deny, or
/// auto-expiry) never call back into captured closures; instead every decision
/// publishes a single `(approvalID, allowed)` event that any number of
/// subscribers — the agent executor, self-improvement service, tests — can key
/// off. Because events are keyed by the persisted `approvalID`, subscribers
/// survive relaunches: a decision made hours later (even one that auto-expired)
/// will still reach whoever is watching that id.
@MainActor
final class ApprovalStore: ObservableObject {
    static let shared = ApprovalStore()

    /// Pending approvals deny themselves after this long, so a stale request
    /// can't be approved long after the model moved on (or vice versa).
    static let kApprovalTimeout: TimeInterval = {
        #if DEBUG
        return 60
        #else
        return 600
        #endif
    }()

    /// Effective TTL for NEW pending approvals; `approval.ttlSeconds` overrides
    /// the compiled default (Settings → Security → Approval TTL).
    static var ttlSeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "approval.ttlSeconds")
        return stored >= 5 ? stored : kApprovalTimeout
    }

    /// Effective cap on retained history records; `approval.historyLimit`
    /// overrides the compiled default.
    static var historyLimit: Int {
        let stored = UserDefaults.standard.integer(forKey: "approval.historyLimit")
        return stored >= 10 ? stored : kHistoryLimit
    }

    @Published var items: [ApprovalItem] = []
    /// Append-only log of resolved verdicts (approve/deny/auto-expire).
    @Published private(set) var history: [ApprovalDecision] = []

    /// Cap on retained history records (older ones are trimmed).
    static let kHistoryLimit = 200

    private var listeners: [UUID: (UUID, Bool) -> Void] = [:]

    init() {
        if let saved = PersistenceController.shared.loadOrMigrate([ApprovalItem].self, file: "approvals") {
            items = saved
            sweepExpired()
        } else if AssistantSettings.shared.demoMode {
            // Sample data loads only in Demo mode; a fresh install starts empty.
            loadSample()
        }
        if let savedHistory = PersistenceController.shared.loadOrMigrate([ApprovalDecision].self, file: "approval_history") {
            history = savedHistory
        }
        startExpirySweep()
    }

    @discardableResult
    func add(title: String, detail: String, icon: String = "gearshape") -> UUID {
        let item = ApprovalItem(title: title, detail: detail, icon: icon,
                                requestedAt: Date(),
                                status: .pending,
                                expiresAt: Date().addingTimeInterval(Self.ttlSeconds))
        items.insert(item, at: 0)
        persist()
        return item.id
    }

    /// Subscribes to decide events. The returned token keeps the subscription
    /// alive; drop it to unsubscribe. Each handler receives `(approvalID, allow)`
    /// for every user decision and every auto-expiry.
    func subscribe(_ handler: @escaping (UUID, Bool) -> Void) -> ApprovalSubscription {
        let token = UUID()
        listeners[token] = handler
        return ApprovalSubscription { [weak self] in
            self?.listeners[token] = nil
        }
    }

    // MARK: - Decision funnel

    func approve(_ item: ApprovalItem) { decide(item, allow: true) }

    func deny(_ item: ApprovalItem) { decide(item, allow: false) }

    func decide(approvalID id: UUID, allow: Bool) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        decide(item, allow: allow)
    }

    private func decide(_ item: ApprovalItem, allow: Bool) {
        guard item.status == .pending, item.expiresAt > Date() else { return }
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].status = allow ? .approved : .denied
        record(ApprovalDecision(approvalID: item.id, title: item.title, detail: item.detail,
                                icon: item.icon, verdict: allow ? .approved : .denied,
                                requestedAt: item.requestedAt, decidedAt: Date()))
        listeners.values.forEach { $0(item.id, allow) }
        persist()
    }

    /// Reopens an already-granted approval that never actually ran (used when
    /// restoring an agent action that was approved moments before a quit).
    /// Denied or expired approvals are left untouched.
    func resetApprovalToPending(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              items[idx].status == .approved else { return }
        items[idx].status = .pending
        items[idx].expiresAt = Date().addingTimeInterval(Self.ttlSeconds)
        persist()
    }

    /// Marks a pending item past its expiration as denied, firing subscribers
    /// so any corresponding agent action is rejected too.
    func sweepExpired() {
        let now = Date()
        let expired = items.filter { $0.status == .pending && $0.expiresAt < now }
        guard !expired.isEmpty else { return }
        for item in expired {
            guard let idx = items.firstIndex(where: { $0.id == item.id }),
                  items[idx].status == .pending else { continue }
            items[idx].status = .denied
            record(ApprovalDecision(approvalID: item.id, title: item.title, detail: item.detail,
                                    icon: item.icon, verdict: .expired,
                                    requestedAt: item.requestedAt, decidedAt: Date()))
            listeners.values.forEach { $0(item.id, false) }
        }
        persist()
    }

    var pendingCount: Int {
        items.filter { $0.status == .pending }.count
    }

    /// Appends a verdict to the auditable history log, bounded to
    /// `historyLimit` records, and persists it.
    private func record(_ decision: ApprovalDecision) {
        history.insert(decision, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        PersistenceController.shared.save(history, file: "approval_history")
    }

    /// Periodically auto-denies expired pending approvals even while the app
    /// stays open and the Approvals view is never visited.
    private func startExpirySweep() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.sweepExpired()
            }
        }
    }

    private func persist() {
        PersistenceController.shared.save(items, file: "approvals")
    }

    private func loadSample() {
        items = [
            ApprovalItem(title: "Run script in working folder", detail: "Nexie wants to run `pip install -r requirements.txt` in ~/Projects/app",
                         icon: "terminal", requestedAt: Date().addingTimeInterval(-600), status: .pending),
            ApprovalItem(title: "Install browser plugin", detail: "A plugin “web.scraper” requested installation",
                         icon: "globe", requestedAt: Date().addingTimeInterval(-1200), status: .pending),
            ApprovalItem(title: "Modify settings", detail: "Change scheduled automation frequency to daily",
                         icon: "slider.horizontal.3", requestedAt: Date().addingTimeInterval(-3600), status: .approved),
            ApprovalItem(title: "Delete local snapshot", detail: "Remove memory snapshot dated 2 weeks ago",
                         icon: "trash", requestedAt: Date().addingTimeInterval(-7200), status: .denied)
        ]
    }
}