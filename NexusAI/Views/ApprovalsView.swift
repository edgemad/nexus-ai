import SwiftUI

struct ApprovalsView: View {
    @ObservedObject var store: ApprovalStore
    @ObservedObject var activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Protected actions")
                .font(.title2.bold())
            Text("Review actions that need your permission. Nothing consequential runs without your approval.")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("Nothing waiting for approval")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(store.items) { item in
                                approvalRow(item)
                            }
                        }
                    }

                    if !store.history.isEmpty {
                        Divider()
                        Text("Recent decisions")
                            .font(.headline)
                        LazyVStack(spacing: 8) {
                            ForEach(store.history) { decision in
                                historyRow(decision)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)
        }
        .cardStyle()
    }

    private func historyRow(_ decision: ApprovalDecision) -> some View {
        let color: Color
        switch decision.verdict {
        case .approved: color = .green
        case .denied: color = .red
        case .expired: color = .orange
        }
        return HStack(spacing: 10) {
            Image(systemName: decision.icon)
                .font(.system(size: 15))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(decision.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Requested \(relative(decision.requestedAt))  ·  decided \(relative(decision.decidedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(decision.verdict.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                if decision.duration >= 0 {
                    Text("took \(relativeDuration(decision.duration))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func approvalRow(_ item: ApprovalItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 18))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Requested: \(relative(item.requestedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if item.status == .pending {
                    Text("Auto-denies \(relative(item.expiresAt))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()

            switch item.status {
            case .pending:
                Button("Approve") {
                    store.approve(item)
                    activity.log(icon: "checkmark.shield", title: "Approval granted",
                                 detail: item.title, color: .green)
                }
                Button("Deny") {
                    store.deny(item)
                    activity.log(icon: "xmark.shield", title: "Approval denied",
                                 detail: item.title, color: .red)
                }
            default:
                Text(item.status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.status.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(item.status.color.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func relativeDuration(_ interval: TimeInterval) -> String {
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        return "\(Int(interval / 3600))h"
    }
}
