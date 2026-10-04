import Foundation
import Testing
import ToolABI
@testable import BrowserTools

/// Tab reuse compared the URL the caller ASKED for against the URL the tab LANDED on, as strings.
/// The browser routinely turns one into the other, so the check was defeated by punctuation.
///
/// Measured on run 34013723545 over 260 `manage_tabs open` receipts: 36% landed on the identical
/// string, **40% differed by a trailing slash alone** (`http://host` -> `http://host/`), 12% by
/// path case, 12% by a redirect landing deeper. Reuse fired 125 times and missed at least the 105
/// slash cases.
///
/// The cost of a miss is not a stray tab. `page_click` takes an `aloha_id` and no tab, so it acts
/// on whichever tab is in use; with two tabs of the same page the model reads one and clicks into
/// the other. In that run 40% of `not found` ids were present in the observation the model was
/// reading, and 65 of 99 attempts had more than one tab carrying ids.
@Suite struct SameTabTargetTests {

    @Test("the 40% case: a trailing slash is not a different page")
    func trailingSlash() {
        #expect(sameTabTarget("http://127.0.0.1:17780", "http://127.0.0.1:17780/"))
        #expect(sameTabTarget("http://127.0.0.1:17780/", "http://127.0.0.1:17780"))
        #expect(sameTabTarget("http://h/f/books/", "http://h/f/books"))
    }

    @Test("the host is case-insensitive by spec")
    func hostCase() {
        #expect(sameTabTarget("HTTP://LocalHost:8080/f/books", "http://localhost:8080/f/books"))
    }

    @Test("identical strings still match, and that path is unchanged")
    func identical() {
        #expect(sameTabTarget("http://h/a?b=1#c", "http://h/a?b=1#c"))
    }

    // MARK: what must NOT be treated as the same tab

    @Test("path case is NOT ignored — paths are case-sensitive by spec")
    func pathCase() {
        // One stand redirects /submit/earthporn to /submit/EarthPorn, but a server where those
        // are two different pages is legal, and taking the wrong one into use is a silent wrong
        // answer.
        #expect(!sameTabTarget("http://h/submit/EarthPorn", "http://h/submit/earthporn"))
    }

    @Test("a redirect that lands deeper is a different page")
    func deeperRedirect() {
        #expect(!sameTabTarget("http://h/admin/admin/dashboard/", "http://h/admin"))
        #expect(!sameTabTarget("http://h/f/books/hot", "http://h/f/books"))
    }

    @Test("query and fragment are part of the identity")
    func queryAndFragment() {
        #expect(!sameTabTarget("http://h/a?b=1", "http://h/a?b=2"))
        #expect(!sameTabTarget("http://h/a?b=1", "http://h/a"))
        #expect(!sameTabTarget("http://h/a#one", "http://h/a#two"))
    }

    @Test("scheme, host and port all count")
    func origin() {
        #expect(!sameTabTarget("https://h/a", "http://h/a"))
        #expect(!sameTabTarget("http://h1/a", "http://h2/a"))
        #expect(!sameTabTarget("http://h:17780/a", "http://h:17781/a"))
    }

    @Test("unparseable input falls back to string equality, never to a wrong match")
    func garbage() {
        #expect(!sameTabTarget("not a url", "also not a url"))
        #expect(sameTabTarget("not a url", "not a url"))
        #expect(!sameTabTarget("", "http://h/a"))
        #expect(sameTabTarget("", ""))
    }

    @Test("the two real pairs this was built from")
    func measuredPairs() {
        #expect(sameTabTarget("http://127.0.0.1:17780/", "http://127.0.0.1:17780"))
        #expect(!sameTabTarget("http://127.0.0.1:17762/admin/admin/dashboard/",
                               "http://127.0.0.1:17762/admin"))
    }

    // MARK: the case folding could not reach

    /// PATH CASE was the 12% `sameTabTarget` deliberately leaves unmatched, and after the
    /// trailing-slash fix it became the DOMINANT cause of duplicate tabs: `/submit/earthporn`
    /// re-opened 12 and 9 times in one run because the server had moved the tab to
    /// `/submit/EarthPorn`. Folding case is not safe, so the tab remembers what it was ASKED to
    /// open and a later request matches that exactly instead.
    @Test("the requested URL matches itself exactly, whatever the server did after")
    func requestedUrlStillMatches() {
        #expect(sameTabTarget("http://h/submit/earthporn", "http://h/submit/earthporn"))
        #expect(!sameTabTarget("http://h/submit/EarthPorn", "http://h/submit/earthporn"))
    }

    @Test("a remembered ask does not make unrelated pages match")
    func rememberedAskIsNotAWildcard() {
        #expect(!sameTabTarget("http://h/submit/earthporn", "http://h/submit/funny"))
        #expect(!sameTabTarget("http://h/f/books", "http://h/f/books/hot"))
    }
}

// MARK: - The reuse decision, through the tool

@MainActor private func openFixture() -> (PageToolsStubTabsModel, PageToolsStubSession, ToolExecutionContext) {
    let model = PageToolsStubTabsModel([])
    let session = PageToolsStubSession()
    let services = NativeToolServices(
        tabsService: PageToolsStubTabsService(PageToolsStubTabsWindow(model)), session: session)
    return (model, session, makePageToolContext(services: services))
}

@MainActor private func openTab(_ url: String, _ context: ToolExecutionContext) async throws -> RawToolResult {
    try await ManageTabsExecutorTool().execute(.object(["action": .string("open"), "url": .string(url)]), context)
}

/// What `manage_tabs open` does with the comparison and the remembered ask: one tab per page,
/// and a receipt that says where the tab actually is.
@Suite("manage_tabs open reuse") @MainActor struct ManageTabsOpenReuseTests {

    @Test("a second open of the same page, spelled with a trailing slash, reuses the tab")
    func trailingSlashReuses() async throws {
        let (model, _, context) = openFixture()
        _ = try await openTab("http://127.0.0.1:17780", context)
        let again = try await openTab("http://127.0.0.1:17780/", context)

        #expect(model.orderedTabs.count == 1)
        #expect(again.output.contains("Reused existing tab (same agent, same URL)"))
    }

    /// The measured path-case case: the server moved the tab, the ask still finds it.
    @Test("a tab the server moved is still found by what it was asked to open")
    func movedTabIsFoundByTheAsk() async throws {
        let (model, _, context) = openFixture()
        _ = try await openTab("http://h/submit/earthporn", context)
        let opened = try #require(model.orderedTabs.last as? PageToolsStubTabHandle)
        let asked = try #require(opened.requestedOpenURL)
        #expect(sameTabTarget(asked, "http://h/submit/earthporn"))

        // The server rewrote the path after the open.
        opened.url = "http://h/submit/EarthPorn"
        let again = try await openTab("http://h/submit/earthporn", context)

        #expect(model.orderedTabs.count == 1)
        #expect(again.output.contains("Tab ID: \(opened.id)"))
    }

    /// THE AUDIT'S ASK: a reuse through the remembered ask must not report "same URL" — the tab
    /// is on a different page, and the model has to be told which.
    @Test("a reuse of a moved tab says where the tab is now, not \"same URL\"")
    func movedTabReceiptNamesTheCurrentPage() async throws {
        let (model, _, context) = openFixture()
        _ = try await openTab("http://h/submit/earthporn", context)
        let opened = try #require(model.orderedTabs.last as? PageToolsStubTabHandle)
        opened.url = "http://h/submit/EarthPorn"

        let again = try await openTab("http://h/submit/earthporn", context)

        #expect(!again.output.contains("same URL"))
        #expect(again.output.contains("has since moved to http://h/submit/EarthPorn"))
        // And the result's own url is where the tab IS, for whoever reads the metadata.
        #expect(again.metadata?["url"] == .string("http://h/submit/EarthPorn"))
    }

    @Test("a remembered ask is not a wildcard: a deeper page still opens a new tab")
    func aDifferentPageOpensANewTab() async throws {
        let (model, _, context) = openFixture()
        _ = try await openTab("http://h/f/books", context)
        _ = try await openTab("http://h/f/books/hot", context)
        #expect(model.orderedTabs.count == 2)
    }

    @Test("the reused tab is taken into use, as a fresh open would be")
    func reuseTakesTheTabIntoUse() async throws {
        let (model, session, context) = openFixture()
        _ = try await openTab("http://h/f/books", context)
        let first = try #require(model.orderedTabs.first).id
        session.active = nil

        _ = try await openTab("http://h/f/books/", context)

        #expect(session.active == first)
    }
}
