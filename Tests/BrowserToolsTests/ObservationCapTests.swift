import Testing
import Foundation
@testable import BrowserTools

/// Covers `AgentDOMService.cappedObservation` -- the per-observation token cap that keeps one
/// huge page from blowing a small model's context window (`ALOHAJET_MAX_OBS_TOKENS`). These are
/// deterministic over a synthetic markdown so they do not depend on which pages a live crawl
/// happens to visit.
@Suite("Observation token cap")
struct ObservationCapTests {
    private let big = String(repeating: "A", count: 8000)
        + "MIDDLE_UNIQUE_MARKER"
        + String(repeating: "Z", count: 8000)

    // REGRESSION: the first implementation gated on `tokenCount`, which is 0 when the BPE encoder
    // cannot load -- so the cap silently never fired. It must fire via the char/4 fallback when
    // tokenCount is 0.
    @Test func capFiresViaCharFallbackWhenTokenCountIsZero() {
        let (out, reported) = AgentDOMService.cappedObservation(markdown: big, tokenCount: 0, cap: 2000)
        #expect(out.count < big.count)
        #expect(out.contains("observation truncated"))
        #expect(reported == 2000)
    }

    @Test func capFiresWithRealTokenCount() {
        let (out, reported) = AgentDOMService.cappedObservation(markdown: big, tokenCount: 6000, cap: 2000)
        #expect(out.count < big.count)
        #expect(out.contains("observation truncated"))
        #expect(reported == 2000)
    }

    // Head-biased head+tail slice: top-of-page and trailing content survive, the middle is what
    // is dropped.
    @Test func capKeepsHeadAndTailDropsMiddle() {
        let (out, _) = AgentDOMService.cappedObservation(markdown: big, tokenCount: 0, cap: 2000)
        #expect(out.hasPrefix("AAA"))
        #expect(out.hasSuffix("ZZZ"))
        #expect(!out.contains("MIDDLE_UNIQUE_MARKER"))
    }

    @Test func noTruncationWhenUnderBudget() {
        let small = String(repeating: "x", count: 1000)  // ~250 est tokens < 2000
        let (out, reported) = AgentDOMService.cappedObservation(markdown: small, tokenCount: 0, cap: 2000)
        #expect(out == small)
        #expect(reported == 0)
    }

    @Test func noTruncationWhenCapNil() {
        let (out, reported) = AgentDOMService.cappedObservation(markdown: big, tokenCount: 9999, cap: nil)
        #expect(out == big)
        #expect(reported == 9999)
    }

    @Test func noTruncationWhenCapZeroOrNegative() {
        let (out0, _) = AgentDOMService.cappedObservation(markdown: big, tokenCount: 0, cap: 0)
        let (outNeg, _) = AgentDOMService.cappedObservation(markdown: big, tokenCount: 0, cap: -5)
        #expect(out0 == big)
        #expect(outNeg == big)
    }

    /// A TRUNCATED TABLE MUST SAY SO. The cap keeps the head and the TAIL, so a cut page still
    /// ends in its footer and reads as complete -- and on a grid the dropped middle IS the answer.
    ///
    /// Run 33948730992, task 184 ("give me the name of the products that have 0 units left"): the
    /// model filtered the grid correctly in ONE navigation and then answered from the 8-9 rows
    /// that survived the cap. Three reps truncated at slightly different points and returned three
    /// different product lists, none right, none aware it was reading part of a table.
    @Test func aTruncatedTableReportsHowManyRowsWentMissing() {
        let rows = (0..<200).map { "| | \(1000 + $0) | Product \($0) | Configurable | $54.00 | 0.0000 |" }
        let newline = "\n"
        let page = "Tab: x" + newline + "URL: http://h/admin" + newline
            + String(repeating: "preamble" + newline, count: 20)
            + rows.joined(separator: newline)
            + String(repeating: newline + "footer", count: 40)
        let (out, _) = AgentDOMService.cappedObservation(markdown: page, tokenCount: 0, cap: 2500)
        #expect(out.contains("TABLE ROW"))
        #expect(out.contains("INCOMPLETE"))
        #expect(out.contains("do not answer from it"))
        // The COUNT is the point: a number the model can act on, not "some text is hidden".
        #expect(out.contains("INCLUDING"))
        #expect(out.contains(where: { $0.isNumber }))
    }

    /// Prose with no table keeps the old wording, so a page that was merely long is not accused
    /// of hiding a list it never had.
    @Test func truncatedProseIsNotCalledATable() {
        let page = String(repeating: "a long paragraph of ordinary prose. ", count: 4000)
        let (out, _) = AgentDOMService.cappedObservation(markdown: page, tokenCount: 0, cap: 2000)
        #expect(!out.contains("TABLE ROW"))
        #expect(out.contains("scroll or read a specific section"))
    }
}
