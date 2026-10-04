import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - `[list=<selector> N/M]` on the action receipt
//
// Agent round 17 (2026-09-23): unique selectors on every receipt meant no `[index=N/M]` and
// nothing for `nth` to count. The identity probe now reports the repeating list the element
// sits in; the page side is exercised by `list_position.js`.

@Suite("Receipt list position")
@MainActor
struct ReceiptListPositionTests {

    @Test func theProbeReplyParsesIntoAListPosition() throws {
        let json = #"{"index":-1,"attrs":[["href","/item?id=1"]],"list":{"selector":"body>main>section>article>div>span>a:nth-of-type(5)","index":1,"count":30}}"#
        let identity = try #require(ReceiptIdentityProbe.parse(json))
        #expect(identity.list == .init(selector: "body>main>section>article>div>span>a:nth-of-type(5)", index: 1, count: 30))
    }

    @Test func aMalformedListIsDropped() throws {
        for list in [#"{"selector":"a","index":0,"count":3}"#, #"{"selector":"a","index":4,"count":3}"#,
                     #"{"selector":"a","index":1,"count":1}"#, #"{"selector":"a b","index":1,"count":3}"#,
                     #"{"selector":"a[x]","index":1,"count":3}"#, #"{"selector":"","index":1,"count":3}"#] {
            let identity = try #require(ReceiptIdentityProbe.parse(#"{"index":-1,"attrs":[],"list":"# + list + "}"))
            #expect(identity.list == nil, Comment(rawValue: list))
        }
    }

    @Test func theReceiptCarriesTheListAfterTheAttrs() {
        let identity = ElementIdentity(index: 1, attributes: [.init(name: "href", value: "/v2ray/v2ray-core")],
                                       list: .init(selector: "body>div>main>div>div>h3>a", index: 1, count: 10))
        let note = PageToolReceipt.selectorNote(selector: "a[href=\"/v2ray/v2ray-core\"]", matches: 1, text: "v2ray/v2ray-core", identity: identity)
        #expect(note.hasSuffix(" [list=body>div>main>div>div>h3>a 1/10]"))
        #expect(note.contains("[matches=1]"))
        #expect(!note.contains("[index="))   // unchanged: index only for an ambiguous selector
    }

    @Test func noListNoBracket() {
        let note = PageToolReceipt.selectorNote(selector: "#q", matches: 1, identity: ElementIdentity(index: 1, attributes: []))
        #expect(!note.contains("[list="))
    }

    /// A read whose selector holds the value read is addressed by its list instead
    /// (github-ss-r82: `a[href="…/releases/tag/v3.8.5"]` for the read "v3.8.5").
    @Test func aSelectorHoldingTheReadTextGivesWayToTheList() {
        let releaseList = ElementIdentity.ListPosition(selector: "body>main>section>div>span:nth-of-type(1)>a", index: 2, count: 10)
        var id = ElementIdentity(index: 1, attributes: [])
        id.list = releaseList
        let free = GetTextExecutorTool.answerFreeReadAddress(
            selector: "a[href=\"/MHSanaei/3x-ui/releases/tag/v3.8.5\"]", text: "v3.8.5", identity: id)
        #expect(free?.selector == releaseList.selector)
        #expect(free?.matches == 10)
        #expect(free?.identity?.index == 2)
        let note = PageToolReceipt.selectorNote(selector: free!.selector, matches: free!.matches, text: "v3.8.5", identity: free!.identity, tool: "get_text")
        #expect(note.hasPrefix(" [selector=\(releaseList.selector)] [tool=get_text] [matches=10] [index=2/10]"))
        #expect(!note.contains("[selector=a[href"))
        // Case does not matter: "Latest" is in `…/releases/latest`.
        #expect(GetTextExecutorTool.answerFreeReadAddress(
            selector: "a[href=\"/MHSanaei/3x-ui/releases/latest\"]", text: "Latest", identity: id)?.selector == releaseList.selector)
        // A selector free of the text, a short text, no text, or no list: left alone.
        #expect(GetTextExecutorTool.answerFreeReadAddress(selector: "a.ActionListContent", text: "v3.8.5", identity: id) == nil)
        #expect(GetTextExecutorTool.answerFreeReadAddress(selector: "a[href=\"/x/v1\"]", text: "v1", identity: id) == nil)
        #expect(GetTextExecutorTool.answerFreeReadAddress(selector: "a[href=\"/x/v3.8.5\"]", text: nil, identity: id) == nil)
        #expect(GetTextExecutorTool.answerFreeReadAddress(selector: "a[href=\"/x/v3.8.5\"]", text: "v3.8.5", identity: ElementIdentity(index: 1, attributes: [])) == nil)
    }
}
