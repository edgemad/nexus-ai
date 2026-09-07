import SwiftUI

/// Phase 8 Run Inspector: plans, surveys, and steers durable DAG task runs.
/// Left column lists every run; the right column is a live per-node inspector
/// (status, dependencies, attempts, results) with start/retry/cancel controls.
struct TaskGraphView: View {
    @ObservedObject var engine: TaskGraphEngine
    @ObservedObject var activity: ActivityStore
    @State private var showingNew = false
    @State private var selectedID: UUID?
    @State private var expanded = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Run Inspector")
                    .font(.title2.bold())
                Text(engine.isRunning ? "a run is in progress" : "idle")
                    .font(.caption.bold())
                    .foregroundStyle(engine.isRunning ? Color.green : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((engine.isRunning ? Color.green : Color.gray).opacity(0.16))
                    .clipShape(Capsule())
                Spacer()
                Button {
                    showingNew = true
                } label: {
                    Label("New run", systemImage: "plus")
                }
            }

            if engine.runs.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No runs yet")
                        .font(.headline)
                    Text("Plan a goal into a dependency graph, then inspect each step as it runs.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 14) {
                    runList
                        .frame(width: 330)
                    if let selected = selectedRun {
                        runInspector(selected)
                    } else {
                        Spacer()
                        Text("Select a run to inspect its graph.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .cardStyle()
        .sheet(isPresented: $showingNew) {
            NewRunSheet(engine: engine, activity: activity, isPresented: $showingNew)
        }
        .onAppear {
            if selectedID == nil, let first = engine.runs.first {
                selectedID = first.id
            }
        }
    }

    private var selectedRun: TaskGraphRun? {
        engine.runs.first { $0.id == selectedID }
    }

    // MARK: - Run list

    private var runList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(engine.runs) { run in
                    Button {
                        selectedID = run.id
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(run.status.color)
                                    .frame(width: 8, height: 8)
                                Text(run.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer()
                            }
                            HStack(spacing: 6) {
                                Text(run.status.label)
                                Text("·")
                                Text("\(run.succeededCount)/\(run.nodeCount) steps")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedID == run.id ? Color.accentColor.opacity(0.16)
                                                        : Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Inspector

    private func runInspector(_ run: TaskGraphRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title)
                        .font(.title3.bold())
                    Text(run.goal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                statusChip(run.status.label, color: run.status.color)
            }

            if let summary = run.resultSummary {
                Text("Summary")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text("Graph (preview)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(TaskGraphScheduler.describeEdges(run))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(3)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(run.nodes) { node in
                        nodeRow(node, run: run)
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                if run.status == .running {
                    Button("Cancel") {
                        engine.cancel(run.id)
                        activity.log(icon: "xmark.circle", title: "Run cancelled",
                                     detail: run.title, color: .orange)
                    }
                } else if run.status == .drafted || run.status == .failed {
                    Button("Start") {
                        engine.start(run.id)
                        activity.log(icon: "play.fill", title: "Run started",
                                     detail: run.title, color: .blue)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if run.failedCount > 0 {
                    Button("Retry \(run.failedCount) failed") {
                        engine.retry(run.id)
                    }
                }
                Button(role: .destructive) {
                    engine.remove(run.id)
                    if selectedID == run.id { selectedID = engine.runs.first?.id }
                    activity.log(icon: "trash", title: "Run removed", detail: run.title, color: .red)
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func nodeRow(_ node: TaskNode, run: TaskGraphRun) -> some View {
        let isExpanded = expanded.contains(node.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if isExpanded {
                        expanded.remove(node.id)
                    } else {
                        expanded.insert(node.id)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 12)

                Image(systemName: kindIcon(node.kind))
                    .font(.caption)
                    .foregroundStyle(node.status.color)
                    .frame(width: 18)

                Circle()
                    .fill(node.status.color)
                    .frame(width: 8, height: 8)

                Text(node.title)
                    .font(.subheadline.bold())
                    .strikethrough(node.status == .skipped || node.status == .cancelled,
                                   color: .secondary)
                if node.attempts > 1 {
                    Text("×\(node.attempts)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                        .help("Attempted \(node.attempts) times")
                }
                Spacer()
                Text(node.status.label)
                    .font(.caption2.bold())
                    .foregroundStyle(node.status.color)
            }

            if isExpanded {
                Text(node.payload)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !node.dependencies.isEmpty {
                    let depTitles = node.dependencies.compactMap { dep in
                        run.nodes.first { $0.id == dep }?.title
                    }
                    Text("After: \(depTitles.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let result = node.result {
                    Divider().opacity(0.3)
                    Text("Output")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Text(result)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(10)
        .background(node.status.color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .clipShape(Capsule())
    }

    private func kindIcon(_ kind: TaskNodeKind) -> String {
        switch kind {
        case .prompt: return "bubble.left.and.bubble.right"
        case .shell: return "terminal"
        case .tool: return "magnifyingglass"
        case .join: return "link"
        }
    }
}

/// Creates a run either from a model-planned graph (goal text) or a simple
/// linear step list (one step per line).
private struct NewRunSheet: View {
    @ObservedObject var engine: TaskGraphEngine
    @ObservedObject var activity: ActivityStore
    @Binding var isPresented: Bool
    @State private var goal = ""
    @State private var stepsText = ""
    @State private var planning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New run")
                .font(.title2.bold())
            TextField("What should the run accomplish?", text: $goal)
                .textFieldStyle(.roundedBorder)
                .onSubmit { plan() }

            Text("Or give exact steps, one per line (linear run, no model needed)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $stepsText)
                .font(.body.monospaced())
                .frame(height: 110)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                if planning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Planning with Nexus AI…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create linear") {
                    createLinear()
                }
                .disabled(!canCreateLinear)
                Button("Plan with Nexus AI") {
                    plan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGoalEmpty || planning)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var isGoalEmpty: Bool {
        goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canCreateLinear: Bool {
        let lines = stepsText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !lines.isEmpty && lines.contains("\n")
    }

    private func createLinear() {
        let lines = stepsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !isGoalEmpty, !lines.isEmpty else { return }
        var nodes: [TaskNode] = []
        for (i, line) in lines.enumerated() {
            let deps = i == 0 ? [] : [nodes[i - 1].id]
            nodes.append(TaskNode(
                title: String(line.prefix(60)),
                kind: .prompt,
                payload: "Step \(i + 1): \(line)",
                dependencies: deps
            ))
        }
        createRun(title: goal, nodes: nodes, detail: "\(nodes.count) linear steps")
    }

    private func plan() {
        let prompt = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        planning = true
        Task { @MainActor in
            let run = await engine.importPlan(from: prompt)
            planning = false
            activity.log(icon: "point.3.connected.trianglepath.dotted",
                         title: "Run planned",
                         detail: "\(run.title) · \(run.nodeCount) steps",
                         color: .blue)
            isPresented = false
        }
    }

    private func createRun(title: String, nodes: [TaskNode], detail: String) {
        do {
            let run = try engine.create(title: title, goal: goal, nodes: nodes)
            activity.log(icon: "plus.circle", title: "Run created",
                         detail: "\(run.title) · \(detail)", color: .green)
            isPresented = false
        } catch {
            activity.log(icon: "exclamationmark.triangle", title: "Run rejected",
                         detail: "\(error.localizedDescription)", color: .red)
        }
    }
}