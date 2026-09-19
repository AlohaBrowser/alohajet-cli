import Testing
import Foundation
import ToolABI
@testable import BrowserTools

/// The two bridge methods that resolve their own element (`scrollTo`, `type`) do not go through
/// the in-page `requireElement`, so they carry the same stale-id diagnosis themselves
/// (`alohaIdNotFoundMessage`). These pin the Swift half: the diagnosis is asked for only after a
/// miss, its answer replaces the bare message, and anything that is not that message falls back
/// to the bare one -- a diagnostic must never replace the error it describes with noise.
@Suite("AgentBrowserBridge stale-id message")
@MainActor
struct StaleIdBridgeMessageTests {

    private let diagnosis = "Element with aloha-id ghost not found. This page carries no aloha-id at all, so it "
        + "has not been read since it last changed. The ids you hold were minted for an earlier page. "
        + "The page is now http://h/submit/x. Re-read the page and use an id from that new snapshot; "
        + "retrying this id, or re-navigating to the same URL, cannot make it resolve."

    @Test func aMissOnScrollToIsDiagnosedNotJustReported() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResultQueue = [.object([("found", .bool(false))]), .string(diagnosis)]
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.scrollTo("ghost")
        #expect(result.isError)
        #expect(result.output == diagnosis)
        // The diagnosis is a second script, issued only after the miss.
        #expect(backend.capturedScripts.count == 2)
        #expect(backend.capturedScripts[1].contains("__alohaDocGeneration"))
        #expect(backend.capturedScripts[1].contains("\"ghost\""))
    }

    @Test func aHitOnScrollToAsksNoDiagnosis() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResult = .object([("found", .bool(true)), ("inViewport", .bool(true))])
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.scrollTo("live")
        #expect(!result.isError)
        #expect(backend.capturedScripts.count == 1)
    }

    /// An answer that is not the message -- the page threw, or answered with something else --
    /// keeps the bare sentence the callers match on.
    @Test func anythingButTheMessageFallsBackToTheBareSentence() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResultQueue = [.object([("found", .bool(false))]), .string("Example Domain")]
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.scrollTo("ghost")
        #expect(result.isError)
        #expect(result.output == "Element with aloha-id ghost not found")

        let silent = PageToolsRecordingBackend()
        silent.evaluateResultQueue = [.object([("found", .bool(false))]), nil]
        let again = await AgentBrowserBridge(backend: silent).scrollTo("ghost")
        #expect(again.output == "Element with aloha-id ghost not found")
    }
}
