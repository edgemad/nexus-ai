import SwiftUI

struct AutomationsView: View {
    @ObservedObject var store: AutomationStore
    @ObservedObject var activity: ActivityStore
    @State private var showingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Automations")
                    .font(.title2.bold())
                Spacer()
                Button {
                    showingNew = true
                } label: {
                    Label("Create automation", systemImage: "plus")
                }
            }

            if store.automations.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No automations yet")
                        .font(.headline)
                    Text("Create one to schedule recurring workflows.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.automations) { automation in
                            automationRow(automation)
                        }
                    }
                }
                .frame(minHeight: 200)
            }
        }
        .cardStyle()
        .sheet(isPresented: $showingNew) {
            NewAutomationSheet(store: store, activity: activity, isPresented: $showingNew)
        }
    }

    private func automationRow(_ automation: Automation) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(automation.status.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.name)
                    .font(.headline)
                Text(automation.schedule)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Last run: \(automation.lastRun)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(automation.status.rawValue.capitalized) {
                store.toggle(automation)
                activity.log(icon: "clock.arrow.circlepath",
                             title: automation.status == .active ? "Automation paused" : "Automation resumed",
                             detail: "\(automation.name)", color: automation.status.color)
            }
            Button {
                store.remove(automation)
                activity.log(icon: "trash", title: "Automation removed", detail: automation.name, color: .red)
            } label: {
                Image(systemName: "trash")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct NewAutomationSheet: View {
    @ObservedObject var store: AutomationStore
    @ObservedObject var activity: ActivityStore
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var schedule = "Every day at 8:00 AM"

    private let schedules = [
        "Every day at 8:00 AM",
        "Every 6 hours",
        "Every 12 hours",
        "Every Monday at 9:00 AM",
        "On file change in a folder"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New automation")
                .font(.title2.bold())
            TextField("Automation name", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Schedule", selection: $schedule) {
                ForEach(schedules, id: \.self) { Text($0) }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        store.add(name: trimmed, schedule: schedule)
                        activity.log(icon: "plus.circle", title: "Automation created",
                                     detail: trimmed, color: .green)
                    }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
