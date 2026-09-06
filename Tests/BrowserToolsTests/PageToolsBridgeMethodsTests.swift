import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - AgentBrowserBridge.selectOptionById / getTextById / waitForSelector
//
// Driver-level tests for the three NEW `AgentBrowserBridge` methods the
// page_select / get_text / page_wait_for tools drive. Mirrors
// `AlohaBridgeTests.swift`'s own `AgentBrowserBridgeTests` suite: exercised
// directly against a stub `AgentBridgeBackend`, the same level every
// pre-existing bridge method (pressKeys/typeText/scrollTo/...) is tested at —
// no CDP/MockCDP involvement needed here since these three verbs never
// dispatch host-side `Input.*` commands (see the "select / getText / waitFor"
// MARK in AlohaBridge.swift).

@Suite("AgentBrowserBridge select / getText / waitFor")
@MainActor
struct PageToolsBridgeMethodsTests {

    // MARK: selectOptionById

    @Test func selectByTextBuildsLabelCallAndReportsSelection() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResult = .object([
            ("success", .bool(true)),
            ("selected", .object([("value", .string("fr")), ("label", .string("France"))]))
        ])
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.selectOptionById("country", text: "France", index: nil)

        #expect(result.isError == false)
        #expect(result.output.contains("France"))
        // Runtime install first, then the fixed select() call built from the
        // typed alohaId/text — never free-form model-authored code.
        let calls = backend.scriptsAfterRuntimeInstall
        #expect(calls.count == 1)
        #expect(calls[0].contains("window.__aloha.select("))
        #expect(calls[0].contains("\"country\""))
        #expect(calls[0].contains("\"label\":\"France\""))
        #expect(!calls[0].contains("\"index\""))
    }

    @Test func selectByIndexBuildsIndexCall() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResult = .object([
            ("success", .bool(true)),
            ("selected", .object([("value", .string("2")), ("label", .string("Third"))]))
        ])
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.selectOptionById("size", text: nil, index: 2)

        #expect(result.isError == false)
        let calls = backend.scriptsAfterRuntimeInstall
        #expect(calls[0].contains("\"index\":2"))
        #expect(!calls[0].contains("\"label\""))
    }

    @Test func selectSurfacesInPageFailure() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResult = .object([("success", .bool(false))])
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.selectOptionById("missing", text: "Nope", index: nil)
        #expect(result.isError)
        #expect(result.output.contains("Select failed"))
    }

    @Test func selectSurfacesThrownJSException() async {
        // requireElement() throwing "not found" surfaces as evaluateViaCdp
        // throwing (the exceptionDetails path) — mirrors a real not-found aloha_id.
        let backend = PageToolsRecordingBackend()
        backend.evaluateError = SimpleBrowserError("Element with aloha-id ghost not found")
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.selectOptionById("ghost", text: "x", index: nil)
        #expect(result.isError)
        #expect(result.output.contains("not found"))
    }

    // MARK: getTextById

    @Test func getTextReturnsPlainStringResult() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResult = .string("Hello world")
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.getTextById("headline")

        #expect(result.isError == false)
        #expect(result.output == "Hello world")
        let calls = backend.scriptsAfterRuntimeInstall
        #expect(calls.count == 1)
        #expect(calls[0].contains("window.__aloha.getText(\"headline\")"))
    }

    @Test func getTextNotFoundSurfacesError() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateError = SimpleBrowserError("Element with aloha-id ghost not found")
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.getTextById("ghost")
        #expect(result.isError)
        #expect(result.output.contains("get_text failed"))
    }

    // MARK: waitForSelector

    @Test func waitForSelectorSuccessReportsAppeared() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResult = .object([("success", .bool(true))])
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.waitForSelector(".ready", timeoutMs: 5_000)

        #expect(result.isError == false)
        #expect(result.output.contains(".ready"))
        let calls = backend.scriptsAfterRuntimeInstall
        #expect(calls[0].contains("window.__aloha.waitFor(\".ready\", 5000)"))
    }

    @Test func waitForSelectorClampsTimeoutAboveCap() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResult = .object([("success", .bool(true))])
        let bridge = AgentBrowserBridge(backend: backend)
        _ = await bridge.waitForSelector(".x", timeoutMs: 999_999)

        let calls = backend.scriptsAfterRuntimeInstall
        // Clamped to AgentBrowserBridge.maxWaitForTimeoutMs (30s), not the raw
        // caller-requested value.
        #expect(calls[0].contains("window.__aloha.waitFor(\".x\", 30000)"))
        #expect(AgentBrowserBridge.maxWaitForTimeoutMs == 30_000)
    }

    /// The negative/edge case: a `waitFor` timeout is a genuine JS Promise
    /// rejection (MutationObserver-based, not a blind sleep) — surfaced here as
    /// a thrown error via `evaluateViaCdp`'s exceptionDetails path, exactly what
    /// `window.__aloha.waitFor`'s own `reject(new Error('waitFor timeout: ...'))`
    /// produces on real expiry.
    @Test func waitForSelectorTimeoutExpirySurfacesAsError() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateError = SimpleBrowserError("waitFor timeout: \".missing\" not found within 10000ms")
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.waitForSelector(".missing", timeoutMs: 10_000)
        #expect(result.isError)
        #expect(result.output.contains("timeout"))
    }
}
