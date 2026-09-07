import SwiftUI

struct ActivityView: View {
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent activity")
                    .font(.title2.bold())
                Spacer()
                Button("Refresh activity") { store.flushAll() }
            }

            if store.events.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No activity yet")
                        .font(.headline)
                    Text("Actions you take across the app will appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(store.events) { event in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: event.icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(event.color)
                                    .frame(width: 30, height: 30)
                                    .background(event.color.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(event.title)
                                            .font(.headline)
                                        Spacer()
                                        Text(relative(event.date))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(event.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if event.id != store.events.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
            }
        }
        .cardStyle()
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
