import Foundation

/// The app's storage schema chain, registered per store so each file upgrades
/// independently:
///
///   v0 — legacy raw payload (pre-envelope files, e.g. written before versioned
///        persistence landed). Loaded and re-wrapped on save.
///   v1 — enveloped, initial model shapes.
///   v2 — current. v1→v2 passes both upgrade files this build wrote (v1) *and*
///        repair hypothetical older payloads missing fields the current models
///        require, so those blobs decode instead of being dropped.
///
/// Registered once (idempotent). `registerAll` runs the first time any store
/// calls `loadOrMigrate`, and is also warmed explicitly at app launch.
@MainActor
enum ModelMigrations {
    private static var registered = false

    static let allStores = [
        "activity", "approvals", "approval_history",
        "automations", "tasks", "actions", "executions",
    ]

    static func registerAll() {
        guard !registered else { return }
        registered = true
        let ctrl = PersistenceController.shared

        // Legacy recovery: pre-envelope stores load as version 0; this step
        // passes their payload through so the rest of the chain applies.
        for file in allStores {
            ctrl.registerMigration(fromVersion: 0, for: file) { $0 }
        }

        // v1 → v2 normalization / repair passes.
        ctrl.registerMigration(fromVersion: 1, for: "activity") {
            ensureKey($0, key: "colorName", fallback: "blue")
        }
        ctrl.registerMigration(fromVersion: 1, for: "approvals") {
            // Backfill the auto-deny deadline (10 minutes from now in the
            // reference-date encoding the app's JSONEncoder uses).
            ensureKey($0, key: "expiresAt",
                      fallback: Date().timeIntervalSinceReferenceDate + 600)
        }
        ctrl.registerMigration(fromVersion: 1, for: "tasks") {
            repairTasks($0)
        }
        for file in ["automations", "approval_history", "actions", "executions"] {
            ctrl.registerMigration(fromVersion: 1, for: file) { $0 }
        }
    }

    /// Adds `key: fallback` to any array element missing it. Element order and
    /// existing values are never touched.
    private static func ensureKey(_ data: Data, key: String, fallback: Any) -> Data {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return data }
        var out = arr
        for i in out.indices where out[i][key] == nil {
            out[i][key] = fallback
        }
        return (try? JSONSerialization.data(withJSONObject: out)) ?? data
    }

    /// Tasks gained `currentStepIndex`/`updatedAt`; older payloads get sane
    /// defaults (resume-at-start, timestamp inherited from creation).
    private static func repairTasks(_ data: Data) -> Data {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return data }
        var out = arr
        for i in out.indices {
            if out[i]["currentStepIndex"] == nil { out[i]["currentStepIndex"] = 0 }
            if out[i]["updatedAt"] == nil, let createdAt = out[i]["createdAt"] {
                out[i]["updatedAt"] = createdAt
            }
        }
        return (try? JSONSerialization.data(withJSONObject: out)) ?? data
    }
}