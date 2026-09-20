import ToolABI
import Testing
import Foundation
@testable import BrowserTools

// Batching `page_type`. The measurement: across 826 tool calls from 82 stored corpus rows, `page_type` ->
// `page_type` is the MOST COMMON consecutive pair in the corpus (76), ahead of click -> click (63), and typing
// plus clicking is 46% of every call made. A form is filled one round per field while the standing prompt is
// re-sent every round — the same mechanism that made read granularity the 11.6x token gap.
//
// These drive the executor's REAL parser rather than a copy of it. The sibling `GetTextBatchTests`
// re-implements its split/dedupe inside the test, which pins a duplicate that can drift from the executor.

@Suite struct PageTypeBatchTests {

    private func value(_ fields: [[String: WorkflowValue]]) -> WorkflowValue {
        .object(["fields": .array(fields.map { .object($0) })])
    }

    @Test func theSingleFieldFormIsNotABatch() {
        // The pre-existing contract, untouched: no `fields` key means nil, and `execute` takes the old path
        // byte for byte.
        let input: WorkflowValue = .object(["aloha_id": .string("a1"), "text": .string("hello")])
        #expect(PageTypeExecutorTool.fields(input) == nil)
    }

    @Test func fieldsAreReadInOrder() {
        let got = PageTypeExecutorTool.fields(value([
            ["aloha_id": .string("user"), "text": .string("admin")],
            ["aloha_id": .string("pass"), "text": .string("admin1234")]
        ]))
        #expect(got?.map(\.alohaId) == ["user", "pass"])
        #expect(got?.map(\.text) == ["admin", "admin1234"])
    }

    @Test func aValueContainingCommasSurvivesIntact() {
        // THE REASON THIS PARAMETER IS AN ARRAY AND NOT A COMMA-SEPARATED STRING, unlike `get_text`'s ids.
        // Ids are opaque tokens; typed values are user text, and addresses, prices and sentences carry commas
        // routinely. A delimited `text` would split this into two fields in production.
        let got = PageTypeExecutorTool.fields(value([
            ["aloha_id": .string("addr"), "text": .string("Springfield, IL 62704")]
        ]))
        #expect(got?.count == 1)
        #expect(got?.first?.text == "Springfield, IL 62704")
    }

    @Test func replaceDefaultsToTruePerField() {
        // Preserving the single-field default exactly: an append default silently doubled a re-typed login
        // field in production, per the executor's own header.
        let got = PageTypeExecutorTool.fields(value([
            ["aloha_id": .string("a"), "text": .string("x")],
            ["aloha_id": .string("b"), "text": .string("y"), "replace": .bool(false)]
        ]))
        #expect(got?.map(\.replace) == [true, false])
    }

    @Test func anItemMissingItsIdOrTextIsSkippedNotFatal() {
        // One malformed entry must not cost the round: the well-formed fields still get filled, and the
        // executor's receipt names what happened.
        let got = PageTypeExecutorTool.fields(value([
            ["aloha_id": .string("ok"), "text": .string("v")],
            ["text": .string("no id")],
            ["aloha_id": .string("no text")]
        ]))
        #expect(got?.map(\.alohaId) == ["ok"])
    }

    @Test func anEmptyOrAbsentListIsNotABatch() {
        #expect(PageTypeExecutorTool.fields(.object(["fields": .array([])])) == nil)
        #expect(PageTypeExecutorTool.fields(.object([:])) == nil)
        // Every item malformed is also not a batch — falling through to the single-field path produces the
        // actionable "requires an aloha_id ... or a fields list" error rather than a silent no-op success.
        #expect(PageTypeExecutorTool.fields(value([["replace": .bool(true)]])) == nil)
    }

    @Test func theBatchIsCapped() {
        let many = (1...30).map { ["aloha_id": WorkflowValue.string("id\($0)"), "text": WorkflowValue.string("v")] }
        #expect(PageTypeExecutorTool.fields(value(many))?.count == 20)
    }

    @Test func theDescriptionTellsTheModelItCanFillAWholeForm() {
        // A capability nothing advertises does not fire; that failure was found five separate times in one day.
        //
        // Asserted against the REGISTRY the agent is actually handed, not against the source text: a constant
        // that says the right thing still advertises nothing if it is never wired into a schema the model
        // receives — the exact gap that let a registered-but-unadvertised lever fire zero times.
        let schema = getNativeAgentToolSchemas().first { $0.name == "page_type" }
        #expect(schema != nil)
        let text = schema?.description ?? ""
        #expect(text.contains("fields"))
        #expect(text.contains("one call"))
    }

    @Test func theBatchParameterIsInTheSchemaWithAnItemShape() {
        // A provider running strict function-calling rejects an array parameter with no `items`, which costs
        // the tool the whole call rather than degrading it. Every other array in that file declares one.
        let schema = getNativeAgentToolSchemas().first { $0.name == "page_type" }
        let encoded = String(describing: schema?.inputSchema ?? .null)
        #expect(encoded.contains("fields"))
        #expect(encoded.contains("items"))
    }
}
