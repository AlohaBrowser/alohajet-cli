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
        let names = ["alohaIdFor", "authoredIdentity", "looksGenerated", "scopeKey", "uniqueAlohaId", "hashString"]
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
}

#endif
