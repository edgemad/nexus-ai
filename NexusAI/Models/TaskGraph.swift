import Foundation
import SwiftUI

/// What a graph step actually does when executed.
enum TaskNodeKind: String, Codable {
    /// A question/query answered by the local model (non-streaming).
    case prompt
    /// An approval-gated shell command.
    case shell
    /// A read-only tool payload (list_directory/read_file/search_files JSON).
    case tool
    /// A plumbing node that just joins upstream results into a summary.
    case join
}

enum TaskNodeStatus: String, Codable {
    case pending, running, awaitingApproval, succeeded, failed, skipped, cancelled

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .awaitingApproval: return "Awaiting approval"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .gray
        case .running: return .blue
        case .awaitingApproval: return .yellow
        case .succeeded: return .green
        case .failed: return .red
        case .skipped: return .secondary
        case .cancelled: return .secondary
        }
    }
}

enum TaskRunStatus: String, Codable {
    case drafted, running, awaitingApproval, completed, failed, cancelled

    var label: String {
        switch self {
        case .drafted: return "Drafted"
        case .running: return "Running"
        case .awaitingApproval: return "Awaiting approval"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .drafted: return .gray
        case .running: return .blue
        case .awaitingApproval: return .yellow
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

/// One step in a task graph. Dependencies are the node ids that must
/// `succeeded` before this node may run (`id`-based edges are implicit in the
/// list, which keeps the record small and cycle-checkable).
struct TaskNode: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var kind: TaskNodeKind
    /// Human instruction or, for `.shell`/`.tool`, the exact payload:
    /// shell command string or read-only tool JSON.
    var payload: String
    /// Node ids that must succeed first.
    var dependencies: [UUID]
    var status: TaskNodeStatus
    /// Line-bounded output captured for the Run Inspector and result caching.
    var result: String?
    /// Number of times the node has been attempted (retry budget).
    var attempts: Int
    var startedAt: Date?
    var finishedAt: Date?

    init(id: UUID = UUID(), title: String, kind: TaskNodeKind, payload: String,
         dependencies: [UUID] = [], status: TaskNodeStatus = .pending,
         result: String? = nil, attempts: Int = 0) {
        self.id = id
        self.title = title
        self.kind = kind
        self.payload = payload
        self.dependencies = dependencies
        self.status = status
        self.result = result
        self.attempts = attempts
    }
}

/// A durable, DAG-runnable unit of work. Survives relaunches; finished runs
/// keep their node results as a cached audit trail.
struct TaskGraphRun: Identifiable, Codable {
    let id: UUID
    var title: String
    var goal: String
    var createdAt: Date
    var updatedAt: Date
    var nodes: [TaskNode]
    var status: TaskRunStatus
    /// Collapsed final answer assembled from succeeded node results.
    var resultSummary: String?

    init(id: UUID = UUID(), title: String, goal: String, nodes: [TaskNode],
         createdAt: Date = Date(), status: TaskRunStatus = .drafted) {
        self.id = id
        self.title = title
        self.goal = goal
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.nodes = nodes
        self.status = status
    }

    var nodeCount: Int { nodes.count }
    var succeededCount: Int { nodes.filter { $0.status == .succeeded }.count }
    var failedCount: Int { nodes.filter { $0.status == .failed }.count }

    func node(_ id: UUID) -> TaskNode? { nodes.first { $0.id == id } }

    func dependenciesSatisfied(_ node: TaskNode) -> Bool {
        node.dependencies.allSatisfy { dep in
            nodes.first { $0.id == dep }?.status == .succeeded
        }
    }
}

/// Pure scheduling logic, kept free of app singletons so harnesses can test it
/// without the engine's main-actor machinery.
enum TaskGraphScheduler {
    static let maxParallel = 3

    /// Nodes that are runnable right now (pending, deps satisfied) — up to
    /// `maxParallel`, prefering shell/tool nodes so a blocked approval never
    /// starves independent work.
    static func nextReady(_ graph: TaskGraphRun) -> [TaskNode] {
        var runnable = graph.nodes.filter {
            $0.status == .pending && graph.dependenciesSatisfied($0)
        }
        if runnable.count > maxParallel {
            runnable = Array(runnable.prefix(maxParallel))
        }
        return runnable
    }

    /// DFS-based cycle detection over the edge set implied by node deps.
    static func hasCycle(_ nodes: [TaskNode]) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        enum Visit { case unvisited, visiting, done }
        var state: [UUID: Visit] = [:]
        for id in byID.keys { state[id] = .unvisited }

        func visit(_ id: UUID) -> Bool {
            switch state[id] {
            case .some(.visiting): return true
            case .some(.done): return false
            default: break
            }
            state[id] = .visiting
            let deps = byID[id]?.dependencies ?? []
            for dep in deps where byID[dep] != nil {
                if visit(dep) { return true }
            }
            state[id] = .done
            return false
        }

        return byID.keys.contains { visit($0) }
    }

    /// True when every node has a terminal status and can never run again.
    static func isSettled(_ graph: TaskGraphRun) -> Bool {
        graph.nodes.allSatisfy {
            $0.status == .succeeded || $0.status == .failed
            || $0.status == .skipped || $0.status == .cancelled
        }
    }

    /// True when the graph is a DAG and every dependency id resolves to a real node.
    static func isWellFormed(_ graph: TaskGraphRun) -> Bool {
        guard !hasCycle(graph.nodes) else { return false }
        let ids = Set(graph.nodes.map { $0.id })
        for node in graph.nodes where !node.dependencies.allSatisfy({ ids.contains($0) }) {
            return false
        }
        return true
    }

    /// A graphical ASCII sketch of the dependency structure for the inspector.
    static func describeEdges(_ graph: TaskGraphRun) -> String {
        var lines: [String] = []
        for node in graph.nodes {
            let deps = node.dependencies.compactMap { depID in
                graph.nodes.first { $0.id == depID }?.title
            }
            let hint = deps.isEmpty ? "start" : deps.joined(separator: ", ")
            lines.append("\(node.title)  ←  \(hint)")
        }
        return lines.joined(separator: "\n")
    }
}