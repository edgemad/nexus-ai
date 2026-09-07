import Foundation

/// One cited web source backing an evidence-backed answer (Phase 9).
struct ResearchSource: Identifiable, Codable, Equatable {
    let title: String
    let url: String
    let snippet: String

    var id: String { url }
}

/// Structured outcome of a research round: the synthesized answer plus the
/// evidence that backs it and a 0–100 verdict confidence.
struct ResearchResult: Codable {
    let answer: String
    let sources: [ResearchSource]
    let confidence: Int?
    let marinated: Bool
}

/// What ChatStore hands onward after a research round. Sources are empty when
/// the fallback path could not recover any URLs.
struct ResearchOutcome {
    let text: String
    let sources: [ResearchSource]
    let confidence: Int?

    static let empty = ResearchOutcome(text: "", sources: [], confidence: nil)
}

/// Deterministic evidence scoring used by the Swift fallback path (and the
/// test harness). Mirrors the Python sidecar's formula so both report the same
/// confidence for the same answer/sources.
enum EvidenceScorer {
    /// Unique, sorted inline citation indexes, e.g. "[2] ... [1] [3]" → [1,2,3].
    static func citationIndexes(_ text: String) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        var remaining = text[...]
        while let range = remaining.range(of: #"\[(\d{1,2})\]"#, options: .regularExpression) {
            let token = String(remaining[range])
            if let n = Int(token.dropFirst().dropLast()) {
                if !seen.contains(n) {
                    seen.insert(n)
                    out.append(n)
                }
            }
            remaining = remaining[range.upperBound...]
        }
        return out.sorted()
    }

    /// Citations that actually trace to a real source index.
    static func traceCount(text: String, sourceCount: Int) -> Int {
        citationIndexes(text).filter { $0 >= 1 && $0 <= sourceCount }.count
    }

    /// 0–95 verdict confidence. Starts low and climbs with (a) at least one
    /// valid inline citation, (b) how many of the gathered sources are used,
    /// (c) whether a reflection/marination pass ran. Mirrors the Python
    /// sidecar's `trace_confidence` exactly.
    static func confidence(text: String, sourceCount: Int, marinated: Bool) -> Int {
        guard !text.isEmpty, sourceCount > 0 else { return 0 }
        let trace = traceCount(text: text, sourceCount: sourceCount)
        var score = trace > 0 ? 50 : 30
        score += Int(Double(min(trace, sourceCount)) / Double(sourceCount) * 30.0)
        if marinated { score += 15 }
        return min(score, 95)
    }
}