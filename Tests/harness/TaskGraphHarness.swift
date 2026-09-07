import Foundation

// TaskGraphHarness — pure-DAG scheduler verification (Phase 8).
//
// Compiles against the real Models/TaskGraph.swift with no app singletons:
// cycle detection, dependency resolution, readiness ordering, settled
// detection, well-formedness, and edge sketches.
@main
struct TaskGraphHarness {
    static var checks = 0
    static var failures = 0

    static func fail(_ msg: String) {
        print("FAIL \(msg)")
        failures += 1
    }
    static func check(_ cond: Bool, _ msg: String) {
        checks += 1
        if cond { print("PASS \(msg)") } else { fail(msg) }
    }

    static func node(_ title: String, deps: [UUID] = []) -> TaskNode {
        TaskNode(title: title, kind: .prompt, payload: title, dependencies: deps)
    }

    static func main() {
        let a = node("A")
        let b = node("B", deps: [a.id])
        let c = node("C", deps: [a.id])
        let d = node("D", deps: [b.id, c.id])
        let e = node("E")

        // ---- Diamond DAG ----
        var graph = TaskGraphRun(title: "Diamond", goal: "test", nodes: [a, b, c, d, e])
        check(TaskGraphScheduler.isWellFormed(graph), "diamond is well formed")
        check(!TaskGraphScheduler.hasCycle(graph.nodes), "diamond has no cycle")

        let first = TaskGraphScheduler.nextReady(graph).map { $0.title }.sorted()
        check(first == ["A", "E"], "first ready = A, E (got \(first))")

        graph.nodes[0].status = .succeeded
        let second = TaskGraphScheduler.nextReady(graph).map { $0.title }.sorted()
        check(second == ["B", "C", "E"], "after A: ready = B, C, E (got \(second))")

        graph.nodes[1].status = .succeeded
        check(TaskGraphScheduler.nextReady(graph).map { $0.title }.sorted() == ["C", "E"],
              "after A+B: ready = C, E (D still blocked)")
        check(!graph.dependenciesSatisfied(graph.nodes[3]),
              "D stays gated while its dependency C is pending")
        graph.nodes[2].status = .succeeded
        check(TaskGraphScheduler.nextReady(graph).map { $0.title }.sorted() == ["D", "E"],
              "after A+B+C: D ready (got \(TaskGraphScheduler.nextReady(graph).map { $0.title }))")
        graph.nodes[3].status = .succeeded
        check(!TaskGraphScheduler.isSettled(graph), "E still pending ⇒ not settled")
        graph.nodes[4].status = .succeeded
        check(TaskGraphScheduler.isSettled(graph), "fully succeeded graph is settled")

        // ---- Cycle detection ----
        var cycB = node("CyB", deps: [])
        let cycA = node("CyA", deps: [cycB.id])
        cycB.dependencies = [cycA.id]
        let cyclic = TaskGraphRun(title: "Cycle", goal: "x", nodes: [cycA, cycB])
        check(TaskGraphScheduler.hasCycle(cyclic.nodes), "two-node cycle detected")
        check(!TaskGraphScheduler.isWellFormed(cyclic), "cyclic graph is not well formed")

        // ---- Self-dependency ----
        var selfNode = node("Self")
        selfNode.dependencies = [selfNode.id]
        check(TaskGraphScheduler.hasCycle([selfNode]), "self-loop detected")

        // ---- Dangling dependency ----
        let stick = TaskNode(title: "Stick", kind: .prompt, payload: "x",
                             dependencies: [UUID()])
        let dangling = TaskGraphRun(title: "Dangling", goal: "x", nodes: [stick])
        check(!TaskGraphScheduler.isWellFormed(dangling), "dangling dep is not well formed")

        // ---- Blocked-by-failed still gated ----
        var stuckDep = node("Dep")
        let blocked = node("Blocked", deps: [stuckDep.id])
        var stuckGraph = TaskGraphRun(title: "Stuck", goal: "x", nodes: [stuckDep, blocked])
        stuckDep.status = .failed
        stuckGraph.nodes[0] = stuckDep
        check(!stuckGraph.dependenciesSatisfied(stuckGraph.nodes[1]),
              "blocked-by-failed dep still gates the dependent")

        // ---- Parallel cap ----
        let wide = TaskGraphRun(title: "Wide", goal: "x",
                                nodes: (0..<7).map { node("N\($0)") })
        check(TaskGraphScheduler.nextReady(wide).count == TaskGraphScheduler.maxParallel,
              "maxParallel respected (got \(TaskGraphScheduler.nextReady(wide).count))")

        // ---- Edge sketch ----
        let edges = TaskGraphScheduler.describeEdges(graph)
        check(edges.contains("D  ←  B, C"), "edge sketch lists deps")
        check(edges.contains("E  ←  start"), "edge sketch marks start nodes")

        print()
        print("TaskGraph: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}