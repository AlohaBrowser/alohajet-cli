import Testing
import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
@testable import BrowserTools

/// `findAssociatedLabelText`, sliced verbatim out of the shipped walker.
///
/// A form control has no text of its own, so `interactiveLabel` found nothing for it and the
/// serializer rendered a bare `input()` while the control's `<label>` went out as its own line --
/// leaving the model to pair the two by position. Measured on WebArena run 33868469638: across 371
/// Magento admin observations, 564 unnamed `input()` against 1,159 named, and 1,956 labels
/// standing on their own line -- one guess per label, every read.
///
/// Postmill's submit form is what the guessing costs. Its labels FOLLOW their controls, so on tasks
/// 647/649 the model typed the title into `#submission_url` and the body into `#submission_title`,
/// left the required title empty, and every submit was refused: 337 refusal notes naming
/// `submission[title]`, nothing ever posted.
@Suite struct AssociatedLabelNameTests {

    private var source: String {
        let script = buildAgentDomTreeScript(highlight: false, focusInteractive: true)
        return sliceJSFunction(named: "findAssociatedLabelText", from: script)
    }

    /// `element.labels` is asserted rather than a hand-rolled `label[for=...]` query because it IS
    /// the association the HTML spec defines -- explicit `for` and a wrapping `<label>`, one
    /// property, no id escaping.
    private func resolve(_ element: String) -> String? {
        guard let context = JSContext() else {
            Issue.record("no JSContext")
            return nil
        }
        context.exceptionHandler = { _, exception in
            Issue.record("JS exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript("const findAssociatedLabelText = \(source);")
        let value = context.evaluateScript("findAssociatedLabelText(\(element))")
        guard let value, !value.isNull, !value.isUndefined else { return nil }
        return value.toString()
    }

    /// The Postmill shape: the label sits AFTER its control in the document, and the association
    /// still holds -- which is the whole point, since document order is what misled the model.
    @Test func aLabelAfterItsControlStillNamesIt() {
        #expect(resolve(#"{ labels: [{ textContent: "  Title  " }] }"#) == "Title")
    }

    /// Magento's admin emits empty labels too (`[] {aloha-id=... label}` appears in its snapshots),
    /// so a blank one must not claim the name and hide a real one behind it.
    @Test func aBlankLabelIsSkippedForARealOne() {
        #expect(resolve(#"{ labels: [{ textContent: "   " }, { textContent: "Enable Product" }] }"#)
                == "Enable Product")
    }

    @Test func aWhitespaceHeavyLabelIsNormalised() {
        #expect(resolve(#"{ labels: [{ textContent: "Post\n  as   a user" }] }"#) == "Post as a user")
    }

    /// `aria-labelledby` is the third branch and joins its tokens in order, as the spec says.
    @Test func ariaLabelledByJoinsItsTokens() {
        let element = """
        { getAttribute: (n) => n === "aria-labelledby" ? "a b" : null,
          ownerDocument: { getElementById: (i) => ({ a: { textContent: "Ship" },
                                                     b: { textContent: "to" } }[i] || null) } }
        """
        #expect(resolve(element) == "Ship to")
    }

    /// A real label outranks a reference, because it is the association the author declared on the
    /// control itself.
    @Test func aRealLabelBeatsAriaLabelledBy() {
        let element = """
        { labels: [{ textContent: "Explicit" }],
          getAttribute: (n) => n === "aria-labelledby" ? "a" : null,
          ownerDocument: { getElementById: () => ({ textContent: "Referenced" }) } }
        """
        #expect(resolve(element) == "Explicit")
    }

    /// No association means nil, NOT an empty string: the caller falls through to the descendant
    /// `aria-label` guess that was there before, so nothing that used to get a name loses one.
    @Test func nothingAssociatedYieldsNil() {
        #expect(resolve(#"{ labels: [], getAttribute: () => null }"#) == nil)
        #expect(resolve(#"{ getAttribute: () => null }"#) == nil)
    }

    /// This runs inside the page walk on every interactive node, so a DOM that throws must cost a
    /// name and nothing else.
    @Test func aThrowingDomCostsANameNotTheWalk() {
        let element = """
        (() => { const e = { getAttribute: () => null };
                 Object.defineProperty(e, "labels", { get() { throw new Error("boom"); } });
                 return e; })()
        """
        #expect(resolve(element) == nil)
    }
}
#endif
