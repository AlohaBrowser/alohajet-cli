import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// ANSWER RECEIPTS AND READ ADDRESSES, polished after the W5 client review (findings 3, 8, 9).
// The hint order is pinned in the page matcher's harness (`answer_receipt.js`, case 15).

@Suite("receipts polish: a value spelled as an address, state classes, hint order")
struct ReceiptPolishTests {

    /// A link's path spells "Charles Babbage" as `Charles_Babbage` (W5 client review, finding 3).
    @Test func aValueSpelledAsAnAddressIsInTheSelector() {
        let bears = GetTextExecutorTool.selector
        #expect(bears(#"a[href="/wiki/Charles_Babbage"]"#, "Charles Babbage"))
        #expect(bears(#"a[href="/r/tag/v3-8-5"]"#, "v3.8.5"))
        #expect(bears(#"a[href="/search?q=caf%C3%A9%20au%20lait"]"#, "Café au lait"))
        #expect(bears(#"a[title="A Light in the Attic"]"#, "A Light in the Attic"))
        // Folded, word for word: "art gallery" is not in "/start/gallery-view"; a short value is
        // never checked.
        #expect(!bears(#"a[href="/start/gallery-view"]"#, "Art Gallery"))
        #expect(!bears(#"a[href="/x/v1"]"#, "v1"))
        #expect(!bears("td.infobox-data", "10 December 1815"))
    }

    /// The slug case gives way to the list; the answer's own value counts as well as the element's
    /// text (books.toscrape: the link reads "A Light in the ...", its title holds the whole name).
    @Test func aSlugSelectorGivesWayToTheList() {
        var id = ElementIdentity(index: 1, attributes: [])
        id.list = .init(selector: "body>main>ul>li>a", index: 3, count: 20)
        let free = GetTextExecutorTool.answerFreeReadAddress(
            selector: #"a[href="/wiki/Charles_Babbage"]"#, text: "Charles Babbage", identity: id)
        #expect(free?.selector == "body>main>ul>li>a")
        #expect(free?.identity?.index == 3)
        let books = GetTextExecutorTool.answerFreeReadAddress(
            selector: #"a[title="A Light in the Attic"]"#, text: "A Light in the ...", identity: id,
            alsoValues: ["A Light in the Attic"])
        #expect(books?.selector == "body>main>ul>li>a")
        // The truncated text alone is caught too once folded ("a light in the" is in the title).
        #expect(GetTextExecutorTool.answerFreeReadAddress(
            selector: #"a[title="A Light in the Attic"]"#, text: "A Light in the ...", identity: id)?.selector
            == "body>main>ul>li>a")
        // A selector that spells another value of the answer gives way as well.
        #expect(GetTextExecutorTool.answerFreeReadAddress(
            selector: #"a[href="/catalogue/a-light-in-the-attic_1000/"]"#, text: "£51.77", identity: id,
            alsoValues: ["A Light in the Attic"])?.selector == "body>main>ul>li>a")
    }

    /// A state or promotion class never narrows a shared ladder selector (finding 9).
    @Test func aStateClassNeverNarrows() {
        for token in ["sale", "out-of-stock", "badge-new", "is-active", "selected", "isActive", "promo_banner"] {
            #expect(AnswerReceipt.isStateClass(token), "\(token)")
        }
        for token in ["nickname", "bday", "price", "author", "inventory_item_price", "product-title"] {
            #expect(!AnswerReceipt.isStateClass(token), "\(token)")
        }
        let classes: [JSValue] = [.string("sale"), .string("badge-new"), .string("title")]
        #expect(AnswerReceipt.narrowed("li.product", insideClasses: classes, text: "Widget") == ["li.product:has(.title)"])
        // A class spelling the answer's value is refused too.
        #expect(AnswerReceipt.narrowed("li.item", insideClasses: [.string("charles-babbage")], text: "x",
                                       values: ["Charles Babbage"]).isEmpty)
    }
}
