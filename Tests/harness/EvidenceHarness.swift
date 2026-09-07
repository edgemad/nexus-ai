import Foundation

// EvidenceHarness — Phase 9 evidence-backed research primitives.
//
// Verifies inline-citation parsing, trace counting and the deterministic
// confidence formula (same numbers as the Python sidecar), plus Codable
// round-trips and that old saved chats (which predate sources/confidence)
// still decode with defaults.
@main
struct EvidenceHarness {
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

    static func main() {
        // ---- Citation parsing ----
        check(EvidenceScorer.citationIndexes("[2] x [1] and [9] [2]") == [1, 2, 9],
              "citations parsed, deduped, sorted: [1, 2, 9]")
        check(EvidenceScorer.citationIndexes("no cites here") == [],
              "no citations → empty")
        check(EvidenceScorer.citationIndexes("see [a] and [12b]") == [],
              "non-numeric brackets are ignored")

        // ---- Trace counting ----
        let full = "According to [1] and [3], the deal runs through [2]."
        check(EvidenceScorer.traceCount(text: full, sourceCount: 3) == 3,
              "all three cites trace to sources")
        check(EvidenceScorer.traceCount(text: full, sourceCount: 2) == 2,
              "out-of-range cite [3] is not traced with two sources")

        // ---- Confidence formula (mirrors Python sidecar) ----
        check(EvidenceScorer.confidence(text: "", sourceCount: 3, marinated: false) == 0,
              "empty answer → 0")
        check(EvidenceScorer.confidence(text: "I think so", sourceCount: 3, marinated: false) == 30,
              "uncited answer → 30 base")
        check(EvidenceScorer.confidence(text: "[1] and [2]", sourceCount: 3, marinated: false) == 70,
              "2/3 traced → 70")
        check(EvidenceScorer.confidence(text: "[1] and [2]", sourceCount: 3, marinated: true) == 85,
              "marinated adds 15 → 85")
        check(EvidenceScorer.confidence(text: "[1] [2] [3] [4]", sourceCount: 4, marinated: true) == 95,
              "full coverage + marinated capped at 95")
        check(EvidenceScorer.confidence(text: "x", sourceCount: 0, marinated: false) == 0,
              "no sources → 0")
        check(EvidenceScorer.traceCount(text: "[1]", sourceCount: 5) >= 1,
              "at least one citation present")

        // ---- ResearchSource Codable ----
        let src = ResearchSource(title: "Apple Newsroom", url: "https://www.apple.com/newsroom",
                                 snippet: "Apple today announced…")
        if let data = try? JSONEncoder().encode(src),
           let back = try? JSONDecoder().decode(ResearchSource.self, from: data) {
            check(back == src, "ResearchSource Codable round-trip")
            check(back.id == src.url, "ResearchSource identity is its URL")
        } else {
            fail("ResearchSource round-trip failed")
        }

        // ---- ResearchResult Codable with optional confidence ----
        let result = ResearchResult(answer: "A grounded answer [1].", sources: [src],
                                    confidence: 65, marinated: false)
        if let data = try? JSONEncoder().encode(result),
           let back = try? JSONDecoder().decode(ResearchResult.self, from: data) {
            check(back.answer == result.answer && back.marinated == result.marinated,
                  "ResearchResult Codable round-trip")
            check(back.confidence == 65, "confidence survives round-trip")
        } else {
            fail("ResearchResult round-trip failed")
        }

        // ---- Old saved-chat tolerance (pre-Phase-9 schema) ----
        let legacyJSON = #"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","text":"Hello","date":700000000}"#
        if let data = legacyJSON.data(using: .utf8),
           let legacy = try? JSONDecoder().decode(ChatMessage.self, from: data) {
            check(legacy.text == "Hello" && legacy.sources.isEmpty,
                  "legacy chat decodes with default empty sources")
            check(legacy.researchConfidence == nil,
                  "legacy chat has nil confidence")
        } else {
            fail("legacy chat decode failed")
        }

        // ---- ChatMessage with evidence round-trip ----
        let evidenced = ChatMessage(role: .assistant, text: "Grounded [1].", date: Date(),
                                    sources: [src], researchConfidence: 75)
        if let data = try? JSONEncoder().encode(evidenced),
           let back = try? JSONDecoder().decode(ChatMessage.self, from: data) {
            check(back.sources.count == 1 && back.sources[0].url == src.url,
                  "message sources survive round-trip")
            check(back.researchConfidence == 75, "message confidence survives round-trip")
        } else {
            fail("evidenced ChatMessage round-trip failed")
        }

        print()
        print("Evidence: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}