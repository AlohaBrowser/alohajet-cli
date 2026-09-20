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
        let delta = PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/a")
        #expect(delta.contains("did NOT navigate"))
        #expect(delta.contains("http://host/a"))
    }

    @Test func aChangedUrlIsNamed() {
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/b")
                    .contains("Navigated to http://host/b"))
    }

    /// The seam is optional and some backends return "". A confident "did not navigate" that really meant
    /// "could not tell" would be worse than the bare receipt it replaces.
    @Test func anUnreadableUrlSaysNothing() {
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "") == "")
        #expect(PageDelta.describe(urlBefore: "", urlAfter: "") == "")
    }

    @Test func withNoBeforeUrlItStatesTheCurrentPageOnly() {
        #expect(PageDelta.describe(urlBefore: "", urlAfter: "http://host/b") == " Now at http://host/b.")
    }

    /// One wording, three tools. Three tools saying the same thing three slightly different ways is how a
    /// model learns to distrust all three.
    @Test func everyActionToolUsesTheSharedHelper() throws {
        for file in ["PageClick", "PageType", "PageSelect"] {
            let source = try packageSource("Sources/BrowserTools/Tools/\(file).swift")
            #expect(source.contains("PageDelta.describe("), "\(file) still ships a stateless receipt")
            #expect(source.contains("bridge.currentPageURL()"), "\(file) never reads the url")
        }
    }
}
