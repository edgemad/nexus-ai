import Foundation

/// Ensures an async race resume overwrites the caller's continuation at most
/// once, so the timeout watchdog and the operation can't both win.
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume<Value>(_ continuation: CheckedContinuation<Value, Never>, _ value: Value) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}

/// Executes the golden eval suite against a completion backend and scores the
/// results with EvalScorer. Deterministic given the completions, so a fixed
/// set of answers always produces the same board.
enum EvalRunner {
    static let systemPrompt = """
    You are a precise, grounded assistant. Answer concisely from facts. If you \
    don't know, say so. When asked for sourced information, cite inline like [1].
    """

    static func run(suite: [EvalCase] = EvalSuite.golden,
                    using complete: @escaping @Sendable (String) async -> String) async -> EvalBoard {
        await EvalLoop.run(suite: suite, using: complete)
    }

    /// Runs `operation`, falling back to `fallback` if it takes longer than
    /// `seconds`. The winner resumes the caller once; a stuck backend is
    /// cancelled and dropped rather than allowed to block the caller.
    static func withTimeout<Value>(_ seconds: TimeInterval,
                                   operation: @escaping @Sendable () async -> Value,
                                   fallback: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let once = OnceResume()
            let operationTask = Task {
                let value = await operation()
                once.resume(continuation, value)
            }
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                operationTask.cancel()
                once.resume(continuation, fallback())
            }
            _ = watchdog
        }
    }

    /// Golden loop against the on-device LLM, with a per-case timeout and
    /// bounded concurrency so a slow model can't tie the whole app up.
    static func runLive(llm: LLMService) async -> EvalBoard {
        await run { prompt in
            await withTimeout(45) {
                await llm.complete(messages: [
                    LLMMessage(role: "system", content: systemPrompt),
                    LLMMessage(role: "user", content: prompt),
                ])
            } fallback: {
                ""
            }
        }
    }

    static func boardSummary(_ board: EvalBoard) -> String {
        var lines = [
            "Eval: \(board.passed)/\(board.total) passed · mean score \(board.meanTotal)",
            "",
        ]
        for report in board.reports {
            let mark = report.score.passed(report.subject.passThreshold) ? "✓" : "✗"
            lines.append("\(mark) [\(report.subject.category)] \(report.subject.id) — score \(report.score.total) (\(report.score.keywordCoverage)% coverage, +\(report.score.evidenceAward) evidence, −\(report.score.forbiddenPenalty) forbidden)")
        }
        lines.append("")
        lines.append("Scored deterministically: keyword coverage + cited-evidence award − forbidden-term penalty, capped 0–100.")
        return lines.joined(separator: "\n")
    }
}