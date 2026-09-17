import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// THE RULE THE PROVIDER ENFORCES, VERBATIM: "schema must have type 'object' and not have
// 'oneOf'/'anyOf'/'allOf'/'enum'/'const'/'not' at the top level."
//
// A schema that breaks it does not degrade the tool — OpenAI answers HTTP 400 for the whole
// `tools` array, so every turn of every session fails before a token is generated. `page_type`
// and `page_select` advertised a top-level `anyOf` and did exactly that in production, while
// both suites stayed green. Nothing between this table and the wire inspects the tree: the
// host copies `inputSchema` across and stringifies it, so this is where it has to be caught.
//
// Nested combinators are legal and deliberately not asserted against — only the top level.

@Suite("Advertised schema shape") struct AdvertisedSchemaShapeTests {
    @Test func everyAdvertisedSchemaIsAPlainObject() throws {
        for tool in getNativeAgentToolSchemas() {
            let schema = try #require(tool.inputSchema, "\(tool.name) advertises no schema")
            #expect(schema.string("type") == "object", "\(tool.name): parameters must be a JSON-Schema object")
            #expect(schema.object("properties") != nil, "\(tool.name): parameters must carry properties")
            for keyword in ["anyOf", "oneOf", "allOf", "enum", "const", "not"] {
                #expect(schema[keyword] == nil,
                        "\(tool.name): \"\(keyword)\" at the top level of parameters — the provider rejects the whole request")
            }
        }
    }
}
