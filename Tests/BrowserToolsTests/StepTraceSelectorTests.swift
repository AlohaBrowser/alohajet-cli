import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - Node builders

/// Builds a ``DomNode`` carrying only what the selector derivation reads: the tag
/// name plus the raw attribute bag (as the DOM walker collects it via
/// `getAttributeNames`).
private func selectorNode(
    id: String = "a1",
    tag: String,
    _ attributes: [String: String] = [:]
) -> DomNode {
    DomNode(id: id, element: DomElement(tagName: tag, attributes: attributes))
}

// MARK: - Pure derivation

/// The pure selector derivation: from a serialized DOM node to a STABLE CSS
/// selector something outside the page can replay, or `nil` when nothing on the node
/// justifies one. The `aloha-id` is never a legitimate answer: it is stable across
/// walks, but it is a hash, and nothing off the page can resolve or recompute it.
@Suite struct StepTraceSelectorTests {

    @Test func idWinsOverEveryOtherSignal() {
        let node = selectorNode(tag: "input", [
            "id": "search-input",
            "data-testid": "search-box",
            "name": "q",
            "type": "text",
            "class": "form-control",
            "aloha-id": "7",
        ])
        #expect(stableCSSSelector(for: node) == "#search-input")
    }

    @Test func idAcceptsHyphenUnderscoreAndLeadingUnderscore() {
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["id": "main_content-2"])) == "#main_content-2")
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["id": "_root"])) == "#_root")
    }

    /// An `id` that is not a valid CSS identifier (leading digit, a colon as React
    /// `useId` emits, embedded whitespace, a quote) must NOT be emitted raw — the
    /// derivation falls through to the next signal instead of shipping a selector
    /// that would break the CSS parser.
    @Test func invalidIdFallsThroughInsteadOfEmittingBrokenSelector() {
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["id": "123-oops", "data-testid": "cart"]))
                == "[data-testid=\"cart\"]")
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["id": ":r3:", "data-testid": "cart"]))
                == "[data-testid=\"cart\"]")
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["id": "two words", "data-testid": "cart"]))
                == "[data-testid=\"cart\"]")
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["id": "a\"]:hover", "data-testid": "cart"]))
                == "[data-testid=\"cart\"]")
    }

    @Test func testIdAttributesComeNextInPriorityOrder() {
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["data-testid": "submit-order", "name": "submit"]))
                == "[data-testid=\"submit-order\"]")
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["data-test": "submit-order", "name": "submit"]))
                == "[data-test=\"submit-order\"]")
        // data-testid beats data-test when both are present.
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["data-test": "b", "data-testid": "a"]))
                == "[data-testid=\"a\"]")
    }

    @Test func nameAttributeIsUsedBeforeTheInputTypeFallback() {
        #expect(stableCSSSelector(for: selectorNode(tag: "input", ["name": "email", "type": "email"]))
                == "[name=\"email\"]")
    }

    @Test func inputTypeIsScopedToTheTag() {
        #expect(stableCSSSelector(for: selectorNode(tag: "input", ["type": "checkbox"]))
                == "input[type=\"checkbox\"]")
        // Tag names are normalized to lowercase (the walker reports them uppercase
        // on some pages).
        #expect(stableCSSSelector(for: selectorNode(tag: "INPUT", ["type": "submit"]))
                == "input[type=\"submit\"]")
        // `type` on a non-input tag is not a page-stable handle on its own.
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["type": "checkbox"])) == nil)
    }

    @Test func stableClassesAreTheLastResortAndCarryTheTag() {
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["class": "btn btn-primary"]))
                == "button.btn.btn-primary")
        // Only the leading stable classes are kept, so the selector stays short.
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["class": "nav-link active current-page extra"]))
                == "a.nav-link.active")
    }

    /// Hashed / obfuscated build-time classes (CSS-in-JS, CSS modules) change on
    /// every build, so they must NEVER be emitted — even though they look like
    /// perfectly good class tokens.
    @Test func hashedClassesAreRefusedAndNeverProduceASelector() {
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["class": "css-1x2y3z"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["class": "sc-AbCdEf"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["class": "css-1x2y3z sc-AbCdEf jsx-2841027"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["class": "Button_root__2xY3z"])) == nil)
        // A stable token alongside hashed ones survives; the hashed ones are dropped.
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["class": "css-1x2y3z submit-button"]))
                == "button.submit-button")
    }

    /// Anti-over-tightening: a node with nothing stable on it must return `nil`
    /// rather than a brittle guess (a bare tag selector, or the `aloha-id` the tools
    /// address elements by, which no off-page consumer can resolve).
    @Test func nodeWithoutAnyStableAttributeReturnsNil() {
        #expect(stableCSSSelector(for: selectorNode(tag: "div")) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["aloha-id": "42", "aria-label": "Close"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "span", ["class": "   "])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "", ["class": "btn"])) == nil)
    }

    /// Whatever comes back must be parser-safe: no quotes, no backslashes, no
    /// whitespace, no control characters — the trace is read by machines.
    @Test func attributeValuesThatWouldBreakTheParserAreRefused() {
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["data-testid": "say \"hi\""])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["data-testid": "back\\slash"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["name": "two words"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["name": "line\nbreak"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "input", ["type": "te xt"])) == nil)

        // Sweep: no emitted selector ever contains a quote-ish or whitespace char.
        let nodes = [
            selectorNode(tag: "input", ["id": "search-input"]),
            selectorNode(tag: "button", ["data-testid": "submit-order"]),
            selectorNode(tag: "input", ["name": "email"]),
            selectorNode(tag: "input", ["type": "checkbox"]),
            selectorNode(tag: "button", ["class": "btn btn-primary"]),
        ]
        for node in nodes {
            guard let selector = stableCSSSelector(for: node) else { continue }
            #expect(!selector.contains("'"))
            #expect(!selector.contains(" "))
            #expect(!selector.contains("\\"))
            // The only quotes allowed are the attribute-value delimiters, in pairs.
            #expect(selector.filter { $0 == "\"" }.count % 2 == 0)
        }
    }
}

// PORT NOTE: the `StepTraceSelectorWiringTests` suite that followed here drives
// `AgentStepTracer`, which is not part of this cut (only `StepTraceSelector` and the
// two trace value types travelled). It is out of this package's scope.
