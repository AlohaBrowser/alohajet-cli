import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// THE THREE PROBES A CLICK RECEIPT IS BUILT FROM, at the Swift seam: each is one page-side
// evaluate whose answer is relayed verbatim, and each must be SILENT -- nil, never an empty
// sentence -- when the page answers nothing or the probe throws. A probe on the side of a working
// receipt must never be able to break one.
//
// The page-side branches (what counts as covered, which controls can be refused, what a consent
// layer is) are exercised against a fake DOM in `overlay_hider.js`, run with `node`, against the
// very bytes `overlayHiderSource` ships.

/// Answers one probe -- recognised by a marker in its script -- and records every script sent.
private final class ProbeBackend: AgentBridgeBackend, @unchecked Sendable {
    let marker: String
    let answer: JSValue?
    let error: Error?
    private(set) var scripts: [String] = []
    init(marker: String, answer: JSValue?, error: Error? = nil) {
        self.marker = marker; self.answer = answer; self.error = error
    }
    var isAborted: Bool { false }
    func consumeAgentDownloads() -> [CapturedDownload] { [] }
    func handOffCaptchaToHuman() async -> Bool { false }
    func evaluateViaCdp(_ expression: String) async throws -> JSValue? {
        scripts.append(expression)
        guard expression.contains(marker) else { return nil }
        if let error { throw error }
        return answer
    }
    @discardableResult
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue]) async throws -> JSValue { .null }
    @discardableResult
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue], on target: CDPSessionTarget) async throws -> JSValue { .null }
    func captureViewport() async throws -> (base64: String, imageWidth: Int, imageHeight: Int)? { nil }
    func viewportDimensions() -> ViewportSize? { nil }
    func resolveSandboxSavePath(_ path: String) -> String? { nil }
    func writeScreenshot(base64: String, hostPath: String, isPng: Bool) async throws {}
    func currentURL() -> String { "http://h/submit/technology" }
    func noteCurrentURL(_ url: String) {}
}
private struct ProbeError: Error {}

@Suite("click receipt probes")
@MainActor
struct ClickReceiptProbesTests {

    // MARK: obstruction note

    @Test func aCoveringElementIsNamed() async {
        let bridge = AgentBrowserBridge(backend: ProbeBackend(
            marker: "elementFromPoint",
            answer: .string(#" The click was delivered to <ul aloha-id="80bb-9f01">, which is NOT that element"#)))
        let note = await bridge.clickObstructionNote(alohaId: "80bb-666e8684")
        #expect(note?.contains("NOT that element") == true)
        #expect(note?.contains("80bb-9f01") == true)
    }

    @Test func aRefusedSubmitIsExplained() async {
        let bridge = AgentBrowserBridge(backend: ProbeBackend(
            marker: "elementFromPoint",
            answer: .string(" The form REFUSED to submit because submission[forum] is not valid.")))
        let note = await bridge.clickObstructionNote(alohaId: "80bb-666e8684")
        #expect(note?.contains("REFUSED") == true)
        #expect(note?.contains("submission[forum]") == true)
    }

    @Test func aCleanClickAddsNothingAndAFailedProbeIsSilent() async {
        let clean = AgentBrowserBridge(backend: ProbeBackend(marker: "elementFromPoint", answer: .string("")))
        #expect(await clean.clickObstructionNote(alohaId: "80bb-666e8684") == nil)
        let failed = AgentBrowserBridge(backend: ProbeBackend(marker: "elementFromPoint", answer: nil, error: ProbeError()))
        #expect(await failed.clickObstructionNote(alohaId: "80bb-666e8684") == nil)
    }

    // MARK: control state

    @Test func controlStateIsParsedFromTheProbe() async {
        let json = #"{"present":true,"name":"Subscribe","pressed":"false","checked":null,"expanded":null,"selected":null,"disabled":null,"value":null}"#
        let bridge = AgentBrowserBridge(backend: ProbeBackend(marker: "aria-pressed", answer: .string(json)))
        let state = await bridge.controlState(alohaId: "80bb-1")
        #expect(state?.present == true)
        #expect(state?.name == "Subscribe")
        #expect(state?.pressed == "false")
        #expect(state?.checked == nil)
    }

    @Test func anUnreadableControlStateIsNil() async {
        let bridge = AgentBrowserBridge(backend: ProbeBackend(marker: "aria-pressed", answer: nil, error: ProbeError()))
        #expect(await bridge.controlState(alohaId: "80bb-1") == nil)
    }

    // MARK: overlay hider (policy: no new cookies)

    @Test func aHiddenLayerIsReportedVerbatim() async {
        let sentence = " Hid a covering overlay <div aloha-id=\"6fdf-4e9c230c\"> without answering it, so this "
            + "click could reach its target. Nothing was accepted or rejected; the layer may reappear on the next page."
        let backend = ProbeBackend(marker: "return hideCoveringOverlay(el, document, window)", answer: .string(sentence))
        let bridge = AgentBrowserBridge(backend: backend)
        #expect(await bridge.hideCoveringOverlay(alohaId: "6fdf-1098b37d") == sentence)
        #expect(backend.scripts.count == 1)
        #expect(backend.scripts.first?.contains("[aloha-id=\"6fdf-1098b37d\"]") == true)
    }

    @Test func aConsentControlIsRefusedVerbatim() async {
        let sentence = "NOT CLICKED. \"Accept All Cookies\" is a control of a cookie/consent prompt, and this agent "
            + "answers none of them (policy: no new cookies). The prompt <div> was hidden instead; nothing was "
            + "accepted or rejected. The page beneath is usable -- continue with the task."
        let backend = ProbeBackend(marker: "return hideConsentLayerContaining(el, document, window)", answer: .string(sentence))
        let bridge = AgentBrowserBridge(backend: backend)
        #expect(await bridge.hideConsentLayerContaining(alohaId: "6fdf-5c8cf9f8") == sentence)
    }

    @Test func nothingHiddenAndFailedProbesAreSilent() async {
        let none = AgentBrowserBridge(backend: ProbeBackend(marker: "hideCoveringOverlay(el", answer: .string("")))
        #expect(await none.hideCoveringOverlay(alohaId: "x") == nil)
        #expect(await none.hideConsentLayerContaining(alohaId: "x") == nil)
        let failed = AgentBrowserBridge(backend: ProbeBackend(marker: "hideCoveringOverlay(el", answer: nil, error: ProbeError()))
        #expect(await failed.hideCoveringOverlay(alohaId: "x") == nil)
    }

    @Test func theIdIsEscapedIntoTheSelector() async {
        let backend = ProbeBackend(marker: "never", answer: nil)
        _ = await AgentBrowserBridge(backend: backend).hideCoveringOverlay(alohaId: "ab\"cd")
        #expect(backend.scripts.first?.contains("[aloha-id=\"ab\\\"cd\"]") == true)
    }

    /// The shipped source carries the markers the Node harness extracts by and is evaluated as
    /// statements; an earlier wrapper put the call on the END comment's line and the whole probe
    /// was a SyntaxError the page answered in 2 ms. Pinned here where the Swift target can see it.
    @Test func theSourceKeepsItsHarnessContract() {
        let src = AgentBrowserBridge.overlayHiderSource
        #expect(src.contains("// BEGIN overlay-hider js"))
        #expect(src.contains("// END overlay-hider js"))
        #expect(src.contains("function hideCoveringOverlay(el, document, window)"))
        #expect(src.contains("function hideConsentLayerContaining(el, document, window)"))
        // Not accepting on the user's behalf: the source never clicks anything.
        #expect(!src.contains(".click("))
    }
}
