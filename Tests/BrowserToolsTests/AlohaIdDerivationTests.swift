import Testing
import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
@testable import BrowserTools

/// Runs `alohaIdFor` and the four helpers it reads, sliced verbatim out of the shipped walker,
/// against synthetic descriptors inside a JavaScriptCore context. The one place an aloha-id comes
/// from is the one place the tests read, so these assertions cannot drift from the code.
@Suite struct AlohaIdDerivationTests {

    private var derivationSource: String {
        let script = buildAgentDomTreeScript(highlight: false, focusInteractive: true)
        let names = ["alohaIdFor", "authoredIdentity", "looksGenerated", "scopeKey", "uniqueAlohaId", "hashString",
                     "documentGeneration"]
        return "const takenAlohaIds = new Set();\n"
            + names.map { sliceJSFunction(named: $0, from: script) }.joined(separator: "\n")
            + "\nconst mockElement = (attrs) => ({ getAttribute: (n) => (n in attrs ? attrs[n] : null) });\n"
    }

    private func evaluate(_ expression: String) -> String? {
        guard let context = JSContext() else {
            Issue.record("no JSContext")
            return nil
        }
        context.exceptionHandler = { _, exception in
            Issue.record("JS exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript(derivationSource)
        return context.evaluateScript(expression)?.toString()
    }

    /// The mechanism bcb8b75 describes, closed by construction: identical elements re-derive
    /// identical ids, so a re-walk cannot stamp one id onto a different element.
    @Test func sameInputYieldsSameIdInAFreshContext() {
        let expression = """
        alohaIdFor({ xpath: "/body/div[2]/button", contextPath: [] }, null)
        """
        let first = evaluate(expression)
        let second = evaluate(expression)
        #expect(first != nil && !(first ?? "").isEmpty)
        #expect(first == second)
    }

    @Test func frameScopeSaltsThePosition() {
        let value = evaluate("""
        [alohaIdFor({ xpath: "/body/div", contextPath: [] }, null),
         alohaIdFor({ xpath: "/body/div", contextPath: [{ type: "iframe", selector: "iframe#a" }] }, null)].join("|")
        """)
        let parts = (value ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 2)
        #expect(parts.first != parts.last)
    }

    @Test func authoredNameBeatsPosition() {
        let value = evaluate("""
        [alohaIdFor({ xpath: "/body/div/input", contextPath: [] }, mockElement({ id: "search-input" })),
         alohaIdFor({ xpath: "/body/div[2]/input", contextPath: [] }, mockElement({ id: "search-input" }))].join("|")
        """)
        let parts = (value ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 2)
        // Same authored name, two positions: one identity, so the second is the dedupe of the first.
        #expect(parts.last == (parts.first ?? "") + "-2")
    }

    @Test func generatedNamesFallThroughToPosition() {
        for generated in ["ember1234", "mui-5", "radix-:r1:"] {
            let value = evaluate("""
            [alohaIdFor({ xpath: "/body/div/input", contextPath: [] }, mockElement({ id: "\(generated)" })),
             hashString("|/body/div/input"),
             hashString("#\(generated)")].join("|")
            """)
            let parts = (value ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            #expect(parts.count == 3, "\(generated)")
            #expect(parts.first == parts.dropFirst().first, "\(generated) should use the position")
            #expect(parts.first != parts.last, "\(generated) should not hash its authored name")
        }
    }

    @Test func identicalIdentitiesAreDisambiguated() {
        let value = evaluate("""
        [alohaIdFor({ xpath: "/body/div", contextPath: [] }, null),
         alohaIdFor({ xpath: "/body/div", contextPath: [] }, null)].join("|")
        """)
        let parts = (value ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 2)
        #expect(!(parts.first ?? "").isEmpty)
        #expect(parts.first != parts.last)
        #expect(parts.last == (parts.first ?? "") + "-2")
    }

    @Test func theIdIsMemoisedOnTheDescriptor() {
        let value = evaluate("""
        (() => {
          const d = { xpath: "/body/div", contextPath: [] };
          const a = alohaIdFor(d, null);
          const b = alohaIdFor(d, null);
          return [a, b, String(takenAlohaIds.size)].join("|");
        })()
        """)
        let parts = (value ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 3)
        #expect(parts[0] == parts[1])
        #expect(parts[2] == "1")
    }

    /// The cross-walk stale-attribute tail needs a real DOM to reproduce, so this is the only
    /// runnable check the clear can have: it exists, and it runs before the walk.
    @Test func staleAlohaIdsAreClearedBeforeTheWalk() {
        let script = buildAgentDomTreeScript(highlight: false, focusInteractive: true)
        let clear = #"querySelectorAll("[aloha-id]")"#
        guard let clearAt = script.range(of: clear), let walkAt = script.range(of: "walkNode(document.body)") else {
            Issue.record("the stale-id clear or the walk entry point is gone")
            return
        }
        #expect(script.contains(#"stale.removeAttribute("aloha-id")"#))
        #expect(clearAt.lowerBound < walkAt.lowerBound)
    }

    // ── Document generation ────────────────────────────────────────────────────
    //
    // A JSContext has no `window`, which is the no-generation path; these install one so the
    // prefix itself is exercised. What is being pinned is the property the run needed and did
    // not have: the same position on two different documents must not produce the same id.

    private func evaluate(_ expression: String, window: String) -> String? {
        guard let context = JSContext() else {
            Issue.record("no JSContext")
            return nil
        }
        context.exceptionHandler = { _, exception in
            Issue.record("JS exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript("var window = \(window);")
        context.evaluateScript(derivationSource)
        return context.evaluateScript(expression)?.toString()
    }

    /// The collision this change exists to remove: `/forums` and `/submit/x` both hash the same
    /// xpath to the same string, so an id held over from the first page addressed an element on
    /// the second and nothing reported it.
    @Test func twoDocumentsDoNotShareAnIdForTheSamePosition() {
        let expression = #"alohaIdFor({ xpath: "/body/div[1]/a[2]", contextPath: [] }, null)"#
        let onForums = evaluate(expression, window: #"{ location: { href: "http://h/forums" } }"#)
        let onSubmit = evaluate(expression, window: #"{ location: { href: "http://h/submit/x" } }"#)
        #expect(onForums != nil && !(onForums ?? "").isEmpty)
        #expect(onSubmit != nil && !(onSubmit ?? "").isEmpty)
        #expect(onForums != onSubmit)
    }

    /// And the guarantee the walker documents, which the prefix must not cost: one document,
    /// many walks, one id. A re-walk is modelled the way the walker does it — `takenAlohaIds` is
    /// declared inside `buildDomTree` and so is fresh per walk, while `window` (and with it the
    /// memoised generation) persists. Clearing the set between the two calls is the difference
    /// between "the same node on a later walk", which must agree, and "two nodes with one
    /// identity in a single walk", which `uniqueAlohaId` must keep apart with a `-2`.
    @Test func oneDocumentKeepsOneIdAcrossWalks() {
        let value = evaluate("""
        (() => {
          const first = alohaIdFor({ xpath: "/body/div[1]/a[2]", contextPath: [] }, null);
          takenAlohaIds.clear();
          const second = alohaIdFor({ xpath: "/body/div[1]/a[2]", contextPath: [] }, null);
          return [first, second].join("|");
        })()
        """, window: #"{ location: { href: "http://h/forums" } }"#)
        let parts = (value ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 2)
        #expect(parts.first == parts.last)
        #expect(!(parts.first ?? "").hasSuffix("-2"))
    }

    /// The dedupe that clearing above deliberately sidesteps, kept honest: two nodes sharing one
    /// identity inside ONE walk still get different ids, prefix and all.
    @Test func twoNodesWithOneIdentityInAWalkStillDiffer() {
        let value = evaluate("""
        [alohaIdFor({ xpath: "/body/div[1]/a[2]", contextPath: [] }, null),
         alohaIdFor({ xpath: "/body/div[1]/a[2]", contextPath: [] }, null)].join("|")
        """, window: #"{ location: { href: "http://h/forums" } }"#)
        let parts = (value ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 2)
        #expect(parts.last == (parts.first ?? "") + "-2")
    }

    /// The prefix is what `staleIdDiagnosis` reads to say "that id belongs to another render"
    /// rather than "not found", so it has to be recoverable from the id: everything before the
    /// first dash, with the hash after it.
    @Test func theGenerationIsReadableFromTheFrontOfTheId() {
        let value = evaluate("""
        [alohaIdFor({ xpath: "/body/div", contextPath: [] }, null),
         documentGeneration(),
         hashString("|/body/div")].join("|")
        """, window: #"{ location: { href: "http://h/forums" } }"#)
        let parts = (value ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 3)
        #expect(!parts[1].isEmpty)
        #expect(parts[0] == parts[1] + "-" + parts[2])
        #expect(parts[0].split(separator: "-").first.map(String.init) == parts[1])
    }

    /// Without a window there is no document to scope to and the bare hash is kept — the path
    /// every other test in this suite runs on, asserted rather than assumed.
    @Test func noWindowMeansNoPrefix() {
        let value = evaluate("""
        [alohaIdFor({ xpath: "/body/div", contextPath: [] }, null), hashString("|/body/div")].join("|")
        """)
        let parts = (value ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 2)
        #expect(parts.first == parts.last)
    }
}

#endif
