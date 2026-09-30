import Foundation
import ToolABI

/// Which page a tab is showing: its live address and its main frame's document id.
///
/// Two readings that differ mean the tab moved to another page between them — a new document, or
/// a single-page app's route change inside the same one. Each value is `nil` when it could not be
/// read, and `nil` means unknown, never "unchanged". That is why this type is not `Equatable`: a
/// synthesized `==` would call two unknown readings the same page.
public nonisolated struct PageIdentity: Sendable {
    /// The page's `location.href` without its fragment: an anchor jump scrolls within the page it
    /// is on. `nil` when the read did not land, which includes a navigation swapping the document
    /// out from under it.
    public let address: String?
    /// The main frame's `loaderId`. It is minted per document load, so a reload at the same address
    /// changes it, while a route change and an anchor jump keep it. `nil` when the frame tree names
    /// none.
    public let documentId: String?

    public init(address: String?, documentId: String?) {
        self.address = address
        self.documentId = documentId
    }
}

extension CDPTabHandle {
    /// Reads which page this tab is showing, as it stands. Nothing here waits for a navigation to
    /// settle: a page still committing reads as it is mid-way, and a later reading sees where it
    /// landed.
    public func pageIdentity() async -> PageIdentity {
        // Inside the document, as the page tools' receipts read it: nothing writes the cached `url`
        // on a click or on the page's own route change, and the frame tree's address is the Aloha
        // browser's stored tab record, which can lag the live page. Read here, not through the
        // receipts' `liveURL()`, which also stores what it read as the cached `url`. On a new tab
        // still showing its blank placeholder, that store erases the address the tab's load wait
        // expects — the overwrite `refreshTabMetadata` refuses — and the wait then passes the
        // empty placeholder as the page.
        let href = (try? await browserTab.getLayer().executeJavaScript("location.href"))?.stringValue
        let tree = try? await SessionScopedCDPTransport(session: session)
            .send(method: "Page.getFrameTree", params: [:])
        let loaderId = tree?["frameTree"]?["frame"]?["loaderId"]?.stringValue
        // An empty value would make every page read as the same one.
        return PageIdentity(
            address: href?.isEmpty == false ? href.map(droppingFragment) : nil,
            documentId: loaderId?.isEmpty == false ? loaderId : nil)
    }
}

/// `href` cut at its first `#`. The fragment always starts there: URL parsing ends the path and
/// the query at the first `#`, and a `#` set into either later is stored as `%23`.
private nonisolated func droppingFragment(_ href: String) -> String {
    href.firstIndex(of: "#").map { String(href[..<$0]) } ?? href
}
