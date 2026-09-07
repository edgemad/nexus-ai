import SwiftUI

struct TasksView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var activity: ActivityStore
    @State private var showingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tasks")
                    .font(.title2.bold())
                Spacer()
                Button {
                    showingNew = true
                } label: {
                    Label("New task", systemImage: "plus")
                }
            }

            if store.tasks.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No tasks yet")
                        .font(.headline)
                    Text("Create a multi-step task to track approval-gated work.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.tasks) { task in
                            taskRow(task)
                        }
                    }
                }
                .frame(minHeight: 200)
            }
        }
        .cardStyle()
        .sheet(isPresented: $showingNew) {
            NewTaskSheet(store: store, activity: activity, isPresented: $showingNew)
        }
    }

    private func taskRow(_ task: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(task.status.color)
                    .frame(width: 8, height: 8)
                Text(task.title)
                    .font(.headline)
                Text(task.status.label)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(task.status.color.opacity(0.18))
                    .clipShape(Capsule())
                if task.requiresApproval {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.secondary)
                        .help("Requires approval")
                }
                Spacer()
                Text(task.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !task.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(task.steps) { step in
                        HStack(spacing: 8) {
                            Button {
                                store.markStepCompleted(task.id, step.id)
                            } label: {
                                Image(systemName: step.status == .completed ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(step.status.color)
                            }
                            .buttonStyle(.plain)
                            .disabled(step.status == .completed)
                            Text(step.title)
                                .font(.subheadline)
                                .strikethrough(step.status == .completed, color: .secondary)
                                .foregroundStyle(step.status == .completed ? .secondary : .primary)
                            Spacer()
                            if task.status == .running && task.currentStepIndex == index(of: step, in: task) {
                                Text("now")
                                    .font(.caption2.bold())
                                    .foregroundStyle(task.status.color)
                            }
                        }
                    }
                }
                .padding(.leading, 4)
            }

            if let result = task.result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Spacer()
                if task.status == .waitingForApproval {
                    Button("Approve & start") {
                        store.start(task.id)
                        activity.log(icon: "play.fill", title: "Task started",
                                     detail: task.title, color: .green)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Deny") {
                        store.setStatus(task.id, .cancelled)
                        activity.log(icon: "xmark", title: "Task denied",
                                     detail: task.title, color: .red)
                    }
                } else if task.status == .failed || task.status == .paused || task.status == .planned {
                    Button("Resume") {
                        store.start(task.id)
                        activity.log(icon: "play.fill", title: "Task resumed",
                                     detail: task.title, color: .blue)
                    }
                }
                if task.status == .running {
                    Button("Pause") {
                        store.setStatus(task.id, .paused)
                    }
                }
                if task.status == .running || task.status == .paused || task.status == .waitingForApproval {
                    Button("Cancel") {
                        store.setStatus(task.id, .cancelled)
                        activity.log(icon: "xmark.circle", title: "Task cancelled",
                                     detail: task.title, color: .orange)
                    }
                }
                Button(role: .destructive) {
                    store.remove(task.id)
                    activity.log(icon: "trash", title: "Task removed", detail: task.title, color: .red)
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func index(of step: TaskStep, in task: TaskRecord) -> Int? {
        task.steps.firstIndex(where: { $0.id == step.id })
    }
}

private struct NewTaskSheet: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var activity: ActivityStore
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var stepsText = ""
    @State private var requiresApproval = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New task")
                .font(.title2.bold())
            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("One step per line")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $stepsText)
                .font(.body)
                .frame(height: 120)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Toggle("Require approval before starting", isOn: $requiresApproval)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let steps = stepsText
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !trimmedTitle.isEmpty, !steps.isEmpty {
                        store.create(title: trimmedTitle, steps: steps, requiresApproval: requiresApproval)
                        activity.log(icon: "plus.circle", title: "Task created",
                                     detail: trimmedTitle, color: .green)
                    }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || stepsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}