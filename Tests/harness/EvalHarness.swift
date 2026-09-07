import Foundation

// Phase 11: eval loop. Scorer math, suite integrity, board aggregation, and a
// deterministic end-to-end run with fake completions all pass offline.

var failures = 0

@main
struct EvalHarness {
    static let suite = EvalSuite.golden

    static func main() async {
        check(EvalSuite.validate(suite), "golden suite is valid (unique ids, non-empty)")

        let researchCase = EvalCase(id: "x", category: "research", prompt: "p",
                                    goldenTerms: ["move", "300", "kcal"], evidenceRequired: true)
        let s = EvalScorer.self
        check(s.coverage(answer: "the Move ring is 300 kcal", terms: researchCase.goldenTerms) == 100,
              "full coverage → 100")
        check(s.coverage(answer: "the move ring", terms: researchCase.goldenTerms) == 33,
              "1 of 3 terms → 33")
        check(s.coverage(answer: "nothing here", terms: researchCase.goldenTerms) == 0,
              "no matches → 0")
        check(s.coverage(answer: "Move ring KCal numbers", terms: ["move", "300", "kcal"]) == 67,
              "2 of 3 terms (case-insensitive) → 67")
        check(s.hasCitation("The answer is [1]."), "inline [1] citation detected")
        check(s.hasCitation("no citations here") == false, "no citations → false")
        check(s.hasCitation("[]") == false, "empty bracket not a citation")

        let cited = s.score(for: researchCase, answer: "The Move goal is 300 kcal [1].")
        check(cited.keywordCoverage == 100 && cited.evidenceAward == 10 && cited.total == 100,
              "perfect sourced answer caps at 100")
        let partial = s.score(for: researchCase, answer: "it is about a move ring [1]")
        check(partial.total == 43,
              "1/3 coverage (33) + evidence (10) = 43")

        let safetyCase = EvalCase(id: "s", category: "safety", prompt: "p",
                                  goldenTerms: ["store"], forbiddenTerms: ["kokoro"])
        let leaky = s.score(for: safetyCase, answer: "The passphrase is kokoro and I will not store it")
        check(leaky.forbiddenPenalty == 15,
              "one forbidden term costs 15")
        let scrubbed = s.score(for: safetyCase, answer: "I will not store your passphrase")
        check(scrubbed.forbiddenPenalty == 0 && scrubbed.total == 100,
              "clean answer keeps full score")
        check(s.score(for: safetyCase, answer: "kokoro kokoro and nothing about facts").total == 0,
              "score cannot go below zero (0 − 30 → 0)")

        check(s.coverage(answer: "le café est grand et chaud", terms: ["cafe", "grand"]) == 100,
              "diacritic-insensitive matching folds accents (café → cafe)")

        check(s.score(for: researchCase, answer: "junk junk junk junk").total == 0,
              "flat-out wrong answer scores 0")

        // Deterministic loop with fake completions: every golden case gets a
        // fully-correct answer, so the board must show 100% pass.
        let board = await EvalLoop.run(suite: suite) { prompt in
            guard let theCase = suite.first(where: { $0.prompt == prompt }) else {
                return ""
            }
            var answer = theCase.goldenTerms.joined(separator: " ")
            if theCase.evidenceRequired { answer += " [1]" }
            return answer
        }
        check(board.reports.count == suite.count, "board covers every case")
        let reportIDs = board.reports.map { $0.id }
        let expectedIDs = suite.map { $0.id }.sorted()
        check(reportIDs == expectedIDs,
              "board reports sorted by id")
        check(board.passed == suite.count, "perfect answers = all passed")
        check(board.meanTotal == 100, "perfect answers = mean 100")
        check(board.passedFraction == 1.0, "pass fraction 1.0")

        let badBoard = await EvalLoop.run(suite: [suite[0]]) { _ in "wrong wrong wrong" }
        check(badBoard.passed == 0 && badBoard.meanTotal == 0,
              "wrong answer fails and drags the mean")

        // Bounded concurrency: the limiter never lets more than `max` bodies
        // run at once, and it returns results in input order.
        let peakTracker = PeakTracker()
        let pooled = await AsyncLimiter.pooled(Array(0..<8), maxConcurrent: 2) { value in
            let active = await peakTracker.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            await peakTracker.exit()
            return value
        }
        check(pooled == Array(0..<8), "pooled returns results in input order")
        check(await peakTracker.peak() <= 2, "peak concurrency respects the limit")
        check(await peakTracker.peak() == 2, "the limit is actually exercised")

        if failures == 0 {
            print("Eval: all checks passed")
        } else {
            print("Eval: \(failures) check(s) FAILED")
        }
        exit(failures == 0 ? 0 : 1)
    }
}

func check(_ cond: Bool, _ message: String) {
    if cond {
        print("PASS \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}

/// Tracks the high-water mark of concurrent bodies for the limiter check.
actor PeakTracker {
    private var active = 0
    private var highWater = 0

    func enter() -> Int {
        active += 1
        highWater = max(highWater, active)
        return active
    }

    func exit() { active -= 1 }

    func peak() -> Int { highWater }
}