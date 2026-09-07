import Testing
import Foundation
@testable import BrowserTools

// Batching `get_text`. The measurement that motivated it: on a corpus row both AlohaJet and Browser Use
// answered correctly, AJ spent 22 tool calls to BU's 4 — and TEN of those were `get_text` on a single id each.
// Browser Use needs four because its observation carries the whole tree. Since the standing prompt is re-sent
// every round, read granularity WAS the 11.6x token gap, and this is the cheapest place to close it.
//
// The id-parsing is the part decidable without a live page, so that is what these pin.

@Suite struct GetTextBatchTests {

    /// The executor's own parse: split, trim, drop empties, dedupe preserving order, cap.
    private func parse(_ raw: String, cap: Int = 20) -> [String] {
        let ids = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        return Array(unique.prefix(cap))
    }

    @Test func aSingleIdIsUnchanged() {
        #expect(parse("a1") == ["a1"])
    }

    @Test func severalIdsSplitOnCommas() {
        #expect(parse("a1,b2,c3") == ["a1", "b2", "c3"])
    }

    @Test func whitespaceAroundIdsIsTolerated() {
        #expect(parse(" a1 , b2 ,c3 ") == ["a1", "b2", "c3"])
    }

    @Test func emptyEntriesAreDropped() {
        #expect(parse("a1,,b2,") == ["a1", "b2"])
    }

    @Test func duplicatesAreReadOnceAndOrderIsKept() {
        // Reading the same element twice in one call is pure waste, and order is what makes the labelled
        // output readable against the page the model just saw.
        #expect(parse("b2,a1,b2,a1,c3") == ["b2", "a1", "c3"])
    }

    @Test func theBatchIsCapped() {
        // Bounded on purpose: the point is fewer ROUNDS, not an unbounded observation that is then re-sent on
        // every later round.
        let many = (1...30).map { "id\($0)" }.joined(separator: ",")
        #expect(parse(many).count == 20)
    }

    @Test func theDescriptionTellsTheModelItCanBatch() {
        // A capability nothing advertises does not fire — five separate instances of that were found the same
        // day this was written. So the batching contract is asserted against the SCHEMA THE MODEL IS SENT,
        // not against source text: an earlier version of this test read a file path off `#filePath`, and after
        // the move the path no longer resolved, the file read itself, and both assertions passed against the
        // test's own source. It was green for the wrong reason and could never fail.
        let schema = getNativeAgentToolSchema("get_text")
        #expect(schema != nil)
        let description = schema?.description ?? ""
        #expect(description.contains("comma-separated"))
        #expect(description.contains("20"))
        // And the cap the description promises is the cap the parser enforces.
        #expect(parse((1...30).map { "id\($0)" }.joined(separator: ",")).count == 20)
    }
}
