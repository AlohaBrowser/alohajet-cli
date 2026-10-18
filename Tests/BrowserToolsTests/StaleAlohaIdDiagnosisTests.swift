import Testing
import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
@testable import BrowserTools

/// Runs `staleIdDiagnosis`, sliced verbatim out of the shipped in-page runtime, against the three
/// states a failed lookup can be in. The message is the whole fix: `Element with aloha-id X not
/// found` is indistinguishable from a typo, from an element that has not rendered yet, and from an
/// id minted for a page that is no longer loaded — and on WebArena run 33843492855 the third was
/// the common case, 672 failed lookups over 22 of 33 traces, which averaged 167 steps against 57
/// for the rest. A caller that cannot tell "retry" from "re-read" retries; these assertions pin
/// that each state names itself, and that every one of them says to re-read.
@Suite struct StaleAlohaIdDiagnosisTests {

    private func diagnose(id: String, href: String, present: Int, generation: String) -> String {
        guard let context = JSContext() else {
            Issue.record("no JSContext")
            return ""
        }
        context.exceptionHandler = { _, exception in
            Issue.record("JS exception: \(exception?.toString() ?? "unknown")")
        }
        let stub = """
        var __present = \(present);
        var window = { location: { href: "\(href)" }\(generation.isEmpty ? "" : ", __alohaDocGeneration: \"\(generation)\"") };
        var document = { querySelectorAll: function() { return { length: __present }; } };
        """
        context.evaluateScript(stub)
        context.evaluateScript(sliceJSFunction(named: "staleIdDiagnosis", from: buildInpageAlohaRuntime()))
        return context.evaluateScript("staleIdDiagnosis(\"\(id)\")")?.toString() ?? ""
    }

    /// The state task 648 was actually in at step 14: navigated, nothing walked since, so the
    /// page carries no aloha-id at all and every id the caller holds is from the page before.
    @Test func anUnreadPageSaysSo() {
        let message = diagnose(id: "4f3a-2c05abf8", href: "http://h/submit/dataisbeautiful",
                               present: 0, generation: "")
        #expect(message.contains("no aloha-id at all"))
        #expect(message.contains("has not been read since it last changed"))
        #expect(message.contains("http://h/submit/dataisbeautiful"))
    }

    /// The state the generation prefix makes visible: the page HAS been walked, so it carries
    /// ids — just not this one, and the prefix proves the id was minted elsewhere rather than
    /// leaving "gone or never here" as the only available guess.
    @Test func aForeignGenerationIsNamedAsOne() {
        let message = diagnose(id: "4f3a-2c05abf8", href: "http://h/submit/dataisbeautiful",
                               present: 262, generation: "9f21")
        #expect(message.contains("minted for a different page or render"))
        #expect(message.contains("4f3a"))
        #expect(message.contains("9f21"))
        #expect(!message.contains("no aloha-id at all"))
    }

    /// A walked page, an id of this same generation, and still no match: the element really is
    /// gone. This one must NOT claim a foreign render — it is the honest "it left" case.
    @Test func aMissingElementOnAWalkedPageIsNotBlamedOnTheGeneration() {
        let message = diagnose(id: "9f21-2c05abf8", href: "http://h/forums",
                               present: 262, generation: "9f21")
        #expect(message.contains("does carry aloha-ids and none of them is that one"))
        #expect(message.contains("gone or was never on this page"))
        #expect(!message.contains("minted for a different page"))
        // No count, on purpose: a caller that hashes the result verbatim to spot a repeated action
        // would see a number that moves between two identical failed clicks as two actions. Two
        // failures in the same state must produce the same bytes.
        let again = diagnose(id: "9f21-2c05abf8", href: "http://h/forums", present: 41, generation: "9f21")
        #expect(again == message)
    }

    /// Whatever the state, the instruction is the same and it is the one the run never got:
    /// re-read, and do not retry the id or re-navigate. Task 648 re-navigated to the same URL
    /// seven times.
    @Test func everyStateEndsInTheSameInstruction() {
        let cases = [
            diagnose(id: "4f3a-2c05abf8", href: "http://h/a", present: 0, generation: ""),
            diagnose(id: "4f3a-2c05abf8", href: "http://h/a", present: 262, generation: "9f21"),
            diagnose(id: "9f21-2c05abf8", href: "http://h/a", present: 262, generation: "9f21"),
        ]
        for message in cases {
            #expect(message.hasPrefix("Element with aloha-id "))
            #expect(message.contains("Re-read the page"))
            #expect(message.contains("cannot make it resolve"))
            #expect(message.contains("re-navigating to the same URL"))
        }
    }

    /// A diagnostic that throws must not replace the error it describes. With no `document` and
    /// no `window` every probe inside falls to its catch and the message still forms.
    @Test func aBareContextStillProducesAMessage() {
        guard let context = JSContext() else { return }
        context.exceptionHandler = { _, _ in }
        context.evaluateScript(sliceJSFunction(named: "staleIdDiagnosis", from: buildInpageAlohaRuntime()))
        let message = context.evaluateScript(#"staleIdDiagnosis("4f3a-2c05abf8")"#)?.toString() ?? ""
        #expect(message.contains("Element with aloha-id 4f3a-2c05abf8 not found"))
        #expect(message.contains("Re-read the page"))
    }

    /// The same message must keep satisfying the one consumer that matches on it: `page_click`
    /// appends its other-tab note when a failed receipt contains "not found", and the diagnosis
    /// still starts with the bare sentence that check was written against.
    @Test func theDiagnosisStillStartsWithTheBareSentence() {
        let message = diagnose(id: "4f3a-2c05abf8", href: "http://h/a", present: 0, generation: "")
        #expect(message.hasPrefix("Element with aloha-id 4f3a-2c05abf8 not found."))
    }
}
#endif
