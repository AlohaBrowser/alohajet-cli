import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - Node builders

/// Builds a ``DomNode`` carrying only what the selector derivation reads: the tag
/// name plus the raw attribute bag (as the DOM walker collects it via
/// `getAttributeNames`), and the walker's position when a case needs the last rung.
private func selectorNode(
    id: String = "a1",
    tag: String,
    _ attributes: [String: String] = [:],
    xpath: String? = nil
) -> DomNode {
    DomNode(id: id, element: DomElement(tagName: tag, attributes: attributes, xpath: xpath))
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
        // Primer's four-character CSS-modules hash (github-ss r5: this class matched 19 links).
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["class": "prc-ActionList-ActionListContent-KBb8-"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["class": "prc-Button-ButtonBase-c50BI"])) == nil)
        // One-case tokens with digits are authored and stay.
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["class": "col-md-6 icon-16px"])) == "div.col-md-6.icon-16px")
        #expect(stableCSSSelector(for: selectorNode(tag: "h2", ["class": "h2-heading mt-4"])) == "h2.h2-heading.mt-4")
        // A stable token alongside hashed ones survives; the hashed ones are dropped.
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["class": "css-1x2y3z submit-button"]))
                == "button.submit-button")
    }

    /// A link IS where it goes: a relative destination without query or fragment is a handle,
    /// after the form-field name and before classes and position (github-ss r5, 2026-09-22: the
    /// top result had a 25-segment position path and `href="/v2ray/v2ray-core"`).
    @Test func aLinksRelativeHrefIsAHandle() {
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["href": "/v2ray/v2ray-core", "class": "prc-Link-Link-85e08"],
                                                    xpath: "/body/div/main/div/h3/a")) == "a[href=\"/v2ray/v2ray-core\"]")
        #expect(stableCSSSelector(for: selectorNode(tag: "A", ["href": "/"])) == "a[href=\"/\"]")
        // Not identity: a host, a query string, a fragment, an unsafe value; or not a link at all.
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["href": "https://github.com/search?q=x&type=repositories"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["href": "//cdn.example.com/x"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["href": "/search?q=x"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["href": "/docs#install"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["href": "/a b"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["href": "/x"])) == nil)
        // The authored rungs above it still win.
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["href": "/x", "data-testid": "home"])) == "[data-testid=\"home\"]")
        // And it beats stable classes.
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["href": "/x", "class": "nav-link"])) == "a[href=\"/x\"]")
    }

    /// An interactive ARIA role is a weak but durable handle when a component library left nothing
    /// else authored on the node (GitHub's "Most stars": generated id, hashed classes, this role).
    @Test func anInteractiveRoleIsAHandleBeforeClassesAndPosition() {
        #expect(stableCSSSelector(for: selectorNode(tag: "li", ["id": "_r_1d_", "role": "menuitemradio", "class": "prc-ActionList-ActionListItem-o0jSu"],
                                                    xpath: "/body/div/ul/li[3]")) == "li[role=\"menuitemradio\"]")
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["role": "Tab"])) == "div[role=\"tab\"]")
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["role": "tab", "class": "nav-link"])) == "div[role=\"tab\"]")
        // Structure is not a handle.
        #expect(stableCSSSelector(for: selectorNode(tag: "nav", ["role": "navigation"])) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", ["role": "presentation"], xpath: "/body/div")) == "body>div")
        // A link's href still wins over its role.
        #expect(stableCSSSelector(for: selectorNode(tag: "a", ["href": "/x", "role": "tab"])) == "a[href=\"/x\"]")
    }

    /// The element's position, from the walker's xpath, when nothing on the node itself is a
    /// handle. Segment for segment: the walker indexes only among same-tag siblings, so a bare
    /// segment stays bare and an indexed one is `nth-of-type`.
    @Test func thePositionIsTheLastResortAndMapsTheWalkersXPathExactly() {
        #expect(stableCSSSelector(for: selectorNode(tag: "input", xpath: "/body/div[3]/form/input[2]"))
                == "body>div:nth-of-type(3)>form>input:nth-of-type(2)")
        #expect(stableCSSSelector(for: selectorNode(tag: "a", xpath: "/body/a")) == "body>a")
        // The walker reports tags lowercase; a path is normalised the same way as a tag.
        #expect(stableCSSSelector(for: selectorNode(tag: "A", xpath: "/BODY/DIV[2]/A")) == "body>div:nth-of-type(2)>a")
        // NO WHITESPACE anywhere in it: the trace's selector field must stay tokenizable.
        #expect(stableCSSSelector(for: selectorNode(tag: "a", xpath: "/body/div/a[2]"))?.contains(" ") == false)
    }

    @Test func everyAuthoredSignalBeatsThePosition() {
        #expect(stableCSSSelector(for: selectorNode(tag: "input", ["id": "q"], xpath: "/body/form/input")) == "#q")
        #expect(stableCSSSelector(for: selectorNode(tag: "input", ["name": "q"], xpath: "/body/form/input")) == "[name=\"q\"]")
        #expect(stableCSSSelector(for: selectorNode(tag: "button", ["class": "btn"], xpath: "/body/button")) == "button.btn")
    }

    /// A path that cannot be pasted into `querySelector` is refused whole, never trimmed: a text
    /// node's segment, a non-identifier tag, a bad index, a relative path, an absurd depth.
    @Test func anUnusablePathIsRefusedWholeNotTrimmed() {
        #expect(stableCSSSelector(for: selectorNode(tag: "text", xpath: "/body/p/text()")) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "text", xpath: "/body/p/text()[2]")) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", xpath: "body/div")) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", xpath: "/body/div[0]")) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", xpath: "/body/div[x]")) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", xpath: "/body/svg:g/div")) == nil)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", xpath: "")) == nil)
        let deep = "/body" + String(repeating: "/div", count: StepTraceSelector.maxPathSegments)
        #expect(stableCSSSelector(for: selectorNode(tag: "div", xpath: deep)) == nil)
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
            selectorNode(tag: "a", ["href": "/v2ray/v2ray-core"]),
            selectorNode(tag: "li", ["role": "menuitemradio"]),
            selectorNode(tag: "input", xpath: "/body/div[3]/form/input[2]"),
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
