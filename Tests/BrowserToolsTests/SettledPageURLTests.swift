import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// Measured against a real Chrome 152: clicking example.com's "Learn more" landed the tab on
// iana.org and the receipt said `The page did NOT navigate — still at https://example.com/`,
// because `settledPageURL` polled the tabs model's cached url and no click ever writes it.
// This fake is that exact situation: the cache is frozen at the pre-click URL while the live
// document has moved. If the poll goes back to reading the cache, the first test fails.

private final class FakeBackend: AgentBridgeBackend, @unchecked Sendable {
    let cache: String
    let live: String
    var noted: [String] = []
    init(cache: String, live: String) { self.cache = cache; self.live = live }

    func consumeAgentDownloads() -> [CapturedDownload] { [] }
    var isAborted: Bool { false }
    func evaluateViaCdp(_ expression: String) async throws -> JSValue? {
        switch expression {
        case "location.href": return .string(live)
        case "document.readyState": return .string("complete")
        default: return nil
        }
    }
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue]) async throws -> JSValue { .null }
    func captureViewport() async throws -> (base64: String, imageWidth: Int, imageHeight: Int)? { nil }
    func viewportDimensions() -> ViewportSize? { nil }
    func resolveSandboxSavePath(_ path: String) -> String? { nil }
    func writeScreenshot(base64: String, hostPath: String, isPng: Bool) async throws {}
    func currentURL() -> String { cache }
    func noteCurrentURL(_ url: String) { noted.append(url) }
}

@Test func settledURLReportsTheDocumentTheTabIsActuallyOn() async {
    let backend = FakeBackend(cache: "https://example.com/", live: "https://www.iana.org/help/example-domains")
    let bridge = AgentBrowserBridge(backend: backend)
    let after = await bridge.settledPageURL(after: "https://example.com/")
    #expect(after == "https://www.iana.org/help/example-domains")
    #expect(PageDelta.describe(urlBefore: "https://example.com/", urlAfter: after)
        == " Navigated to https://www.iana.org/help/example-domains.")
    // and the stale cache is refreshed, so the next `manage_tabs list` stops printing the old URL
    #expect(backend.noted.contains("https://www.iana.org/help/example-domains"))
}

@Test func settledURLStillSaysNothingMovedWhenNothingMoved() async {
    let backend = FakeBackend(cache: "https://example.com/", live: "https://example.com/")
    let bridge = AgentBrowserBridge(backend: backend)
    let after = await bridge.settledPageURL(after: "https://example.com/", graceMs: 60)
    #expect(after == "https://example.com/")
    #expect(PageDelta.describe(urlBefore: "https://example.com/", urlAfter: after).contains("did NOT navigate"))
}
