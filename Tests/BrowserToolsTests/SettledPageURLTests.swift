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
        == " Navigated to https://www.iana.org/help/example-domains")
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

// A form posted to its own address loads a new document at the URL it was on, so the URL alone
// says "did NOT navigate" about a page that was replaced. The document generation the DOM walk
// mints per window tells the two apart: a new document has a different one, or none until it is
// walked. This backend answers the generation expression from a script, and can fail its first
// href reads the way a document that is being replaced does.

private final class DocumentBackend: AgentBridgeBackend, @unchecked Sendable {
    let href: String
    var destroyedReads: Int
    var generations: [String?]
    var generationReads = 0
    init(href: String, generations: [String?], destroyedReads: Int = 0) {
        self.href = href
        self.generations = generations
        self.destroyedReads = destroyedReads
    }

    func consumeAgentDownloads() -> [CapturedDownload] { [] }
    var isAborted: Bool { false }
    func evaluateViaCdp(_ expression: String) async throws -> JSValue? {
        switch expression {
        case "location.href":
            if destroyedReads > 0 {
                destroyedReads -= 1
                throw SimpleBrowserError("Execution context was destroyed.")
            }
            return .string(href)
        case "document.readyState": return .string("complete")
        case AgentBrowserBridge.documentGenerationExpression:
            generationReads += 1
            let answer = generations.count > 1 ? generations.removeFirst() : generations.first ?? nil
            guard let answer else { throw SimpleBrowserError("Execution context was destroyed.") }
            return .string(answer)
        default: return nil
        }
    }
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue]) async throws -> JSValue { .null }
    func captureViewport() async throws -> (base64: String, imageWidth: Int, imageHeight: Int)? { nil }
    func viewportDimensions() -> ViewportSize? { nil }
    func resolveSandboxSavePath(_ path: String) -> String? { nil }
    func writeScreenshot(base64: String, hostPath: String, isPng: Bool) async throws {}
    func currentURL() -> String { href }
    func noteCurrentURL(_ url: String) {}
}

@Suite("a same-URL page load")
struct SameURLDocumentTests {

    @Test("a new generation, or none yet, at the same href is a new document", arguments: ["g2", ""])
    func aReplacedDocumentAtTheSameUrlIsANewDocument(_ after: String) async {
        let bridge = AgentBrowserBridge(backend: DocumentBackend(href: "http://host/form", generations: [after]))
        let settled = await bridge.settledPage(after: "http://host/form", generationBefore: "g1")
        #expect(settled == SettledPage(url: "http://host/form", newDocument: true))
        #expect(PageDelta.describe(urlBefore: "http://host/form", urlAfter: settled.url, newDocument: settled.newDocument)
            == " A new page loaded at the same URL http://host/form")
    }

    /// The single-page app control: same window, same href, so the same generation.
    @Test func theSameGenerationIsTheSameDocument() async {
        let bridge = AgentBrowserBridge(backend: DocumentBackend(href: "http://host/app", generations: ["g1"]))
        let settled = await bridge.settledPage(after: "http://host/app", generationBefore: "g1", graceMs: 60)
        #expect(settled == SettledPage(url: "http://host/app", newDocument: false))
        #expect(PageDelta.describe(urlBefore: "http://host/app", urlAfter: settled.url, newDocument: settled.newDocument)
            .contains("did NOT navigate"))
    }

    /// A page that was never walked has no generation to compare, and a guess would be worse
    /// than the receipt it replaces; it is not even asked.
    @Test func noGenerationBeforeIsNoClaim() async {
        let backend = DocumentBackend(href: "http://host/form", generations: ["g2"])
        let settled = await AgentBrowserBridge(backend: backend)
            .settledPage(after: "http://host/form", generationBefore: "", graceMs: 60)
        #expect(settled == SettledPage(url: "http://host/form", newDocument: false))
        #expect(backend.generationReads == 0)
    }

    /// A generation read that fails says nothing about the document; only an answer counts.
    @Test func aFailedGenerationReadIsNoClaim() async {
        let bridge = AgentBrowserBridge(backend: DocumentBackend(href: "http://host/form", generations: [nil]))
        let settled = await bridge.settledPage(after: "http://host/form", generationBefore: "g1", graceMs: 60)
        #expect(settled == SettledPage(url: "http://host/form", newDocument: false))
    }

    /// The href read lands while the old document is being torn down; once the new one is in,
    /// its href is the same and its generation is not.
    @Test func aDocumentReplacedWhileItsHrefWasUnreadableIsANewDocument() async {
        let backend = DocumentBackend(href: "http://host/form", generations: [""], destroyedReads: 1)
        let settled = await AgentBrowserBridge(backend: backend)
            .settledPage(after: "http://host/form", generationBefore: "g1")
        #expect(settled == SettledPage(url: "http://host/form", newDocument: true))
    }

    @Test func theGenerationIsReadFromThePageAndEmptyWhenItCannotBe() async {
        #expect(await AgentBrowserBridge(backend: DocumentBackend(href: "http://h/", generations: ["20a6"]))
            .documentGeneration() == "20a6")
        #expect(await AgentBrowserBridge(backend: DocumentBackend(href: "http://h/", generations: [nil]))
            .documentGeneration() == "")
    }

    @Test func theUrlOnlySettleIsUnchanged() async {
        let bridge = AgentBrowserBridge(backend: DocumentBackend(href: "http://host/form", generations: ["g2"]))
        #expect(await bridge.settledPageURL(after: "http://host/form", graceMs: 60) == "http://host/form")
    }
}
