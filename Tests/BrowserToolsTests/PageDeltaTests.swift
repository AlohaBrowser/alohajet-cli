import Testing
@testable import BrowserTools

/// Three tools now say the same thing the same way. These pin the wording once.
///
/// MEASURED on the WebArena read-tier corpus: 143 rows end their final tool call on a bare
/// `Clicked element "X" (single).` (80 failed), 23 on `Typed into element "X".` (21 failed), 7 on
/// `Selected X on element Y.` (6 failed). Such a receipt is equally true of an action that navigated, one
/// that opened a menu, and one that hit nothing — so the model proceeds as if it worked.
@Suite("page delta")
struct PageDeltaTests {

    @Test func anUnchangedUrlIsSaidOutLoud() {
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/a") == """
             The page did NOT navigate — if you expected a new page, the action did not do what \
            you assumed: read the page before acting again. The URL is still http://host/a
            """)
    }

    @Test func aChangedUrlIsNamed() {
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/b")
                == " Navigated to http://host/b")
    }

    /// A form posted to its own address loads a new document at the URL it was on. That is
    /// not "did NOT navigate", and the sentence does not start with "Navigated to" either: a
    /// program that captures `Navigated to (\S+)` would take "a" for the URL.
    @Test func aNewDocumentAtTheSameUrlIsSaidToBeANewPage() {
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/a", newDocument: true)
                == " A new page loaded at the same URL http://host/a")
    }

    @Test func aChangedUrlWinsOverANewDocument() {
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/b", newDocument: true)
                == " Navigated to http://host/b")
    }

    @Test func theSameDocumentAtTheSameUrlStillDidNotNavigate() {
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/a", newDocument: false)
                == PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/a"))
        #expect(PageDelta.describe(urlBefore: "", urlAfter: "http://host/b", newDocument: true) == " Now at http://host/b")
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "", newDocument: true) == "")
    }

    /// A URL is never followed by punctuation: a program that copies the receipt's URL verbatim
    /// navigated to `…/search/home.` (agent run jacket-bag-luna-ge43) and got "Access Denied".
    @Test func aUrlEndsItsSentenceWithoutAMark() throws {
        let url = "http://host/search/home"
        for receipt in [PageDelta.describe(urlBefore: "", urlAfter: url),
                        PageDelta.describe(urlBefore: "http://host/", urlAfter: url),
                        PageDelta.describe(urlBefore: url, urlAfter: url),
                        PageDelta.describe(urlBefore: url, urlAfter: url, newDocument: true)] {
            let range = try #require(receipt.range(of: url))
            let after = receipt[range.upperBound...]
            #expect(after.isEmpty || after.first == " ", "\(receipt)")
        }
    }

    /// The seam is optional and some backends return "". A confident "did not navigate" that really meant
    /// "could not tell" would be worse than the bare receipt it replaces.
    @Test func anUnreadableUrlSaysNothing() {
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "") == "")
        #expect(PageDelta.describe(urlBefore: "", urlAfter: "") == "")
    }

    @Test func withNoBeforeUrlItStatesTheCurrentPageOnly() {
        #expect(PageDelta.describe(urlBefore: "", urlAfter: "http://host/b") == " Now at http://host/b")
    }

    /// One wording, four tools. Tools saying the same thing slightly different ways is how a
    /// model learns to distrust all of them. Each reads the document generation next to the url,
    /// so a same-URL page load is told apart from a page that did not move.
    @Test("every action tool uses the shared helper",
          arguments: ["PageClick", "PageType", "PageSelect", "PagePressKeys"])
    func everyActionToolUsesTheSharedHelper(_ file: String) throws {
        let source = try packageSource("Sources/BrowserTools/Tools/\(file).swift")
        #expect(source.contains("PageDelta.describe("), "\(file) still ships a stateless receipt")
        #expect(source.contains("bridge.currentPageURL()"), "\(file) never reads the url")
        #expect(source.contains("bridge.documentGeneration()"), "\(file) never reads the document generation")
        #expect(!source.contains("settledPageURL("), "\(file) settles on the url alone")
    }
}
