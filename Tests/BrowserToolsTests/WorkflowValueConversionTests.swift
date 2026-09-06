import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// `BrowserToolSession.workflowValue` is the CLI's whole argument path: `alohajet type
// <ref> <text> --submit` becomes `["submit": true, "replace": true, ...]` and goes
// through here. It is also the one function in the package that has to be written twice,
// once per platform — `CFGetTypeID` does not exist off Apple — so it is exactly the shape
// that passes on the machine you develop on and silently differs on the machine CI runs.

@Suite("workflow value conversion")
struct WorkflowValueConversionTests {

    /// A boolean must not come out as a number. On Darwin `1 as NSNumber` also casts to
    /// `Bool`, so the discrimination is not free, and a `submit: 1` where the tool expects
    /// `submit: true` fails an argument check with a message about the wrong thing.
    @Test func boolsStayBools() {
        #expect(BrowserToolSession.workflowValue(true) == .bool(true))
        #expect(BrowserToolSession.workflowValue(false) == .bool(false))
    }

    /// And a number must not come out as a boolean, which is the failure mode the
    /// CoreFoundation check exists to prevent.
    @Test func numbersStayNumbers() {
        #expect(BrowserToolSession.workflowValue(1) == .number(1))
        #expect(BrowserToolSession.workflowValue(0) == .number(0))
        #expect(BrowserToolSession.workflowValue(2.5) == .number(2.5))
        #expect(BrowserToolSession.workflowValue(-3) == .number(-3))
    }

    /// Through `JSONSerialization`, which is where the `NSNumber` ambiguity actually
    /// comes from — a hand-built Swift dictionary never produces one.
    @Test func jsonBoolsAndNumbersSurviveDecoding() throws {
        let data = Data(#"{"submit":true,"replace":false,"index":0,"max_chars":1500}"#.utf8)
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard case let .object(members) = BrowserToolSession.workflowValue(decoded) else {
            Issue.record("a JSON object did not convert to an object")
            return
        }
        #expect(members["submit"] == .bool(true))
        #expect(members["replace"] == .bool(false))
        #expect(members["index"] == .number(0))
        #expect(members["max_chars"] == .number(1500))
    }

    @Test func stringsArraysAndNestedObjects() {
        #expect(BrowserToolSession.workflowValue("hi") == .string("hi"))
        #expect(BrowserToolSession.workflowValue(["a", 1]) == .array([.string("a"), .number(1)]))
        #expect(BrowserToolSession.workflowValue(["k": ["n": 2]]) == .object(["k": .object(["n": .number(2)])]))
    }

    /// Anything unrepresentable becomes `.null` rather than failing the call: a bad
    /// argument should reach the tool and be refused there, with the tool's own message.
    @Test func theUnrepresentableBecomesNull() {
        #expect(BrowserToolSession.workflowValue(Date()) == .null)
        #expect(BrowserToolSession.workflowValue(NSNull()) == .null)
    }
}
