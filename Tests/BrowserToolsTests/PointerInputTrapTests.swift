import Testing
import Foundation
@testable import BrowserTools
import ToolABI

// The pointer verbs take their coordinates, step count and duration straight from the
// model, as plain JSON numbers, through `execute_code`. Every conversion on that path used
// to be a runtime trap rather than an error: `Int(1e300.rounded())`, `Int(steps)` and
// `UInt64(delayMs * 1_000_000)` all kill the process, and a killed process takes the turn,
// the browser and — when it happens in CI — every suite after it.
//
// Saturating alone would not have been enough: `Int.max` drag steps is a hang, not a crash.
// The bounds are in `drag` and `abortableDelay`; these tests are what keeps them there.

@Suite("pointer verbs do not trap on numbers an Int cannot hold")
@MainActor
struct PointerInputTrapTests {

    @Test("moveMouse survives coordinates no Int can hold",
          arguments: [1e300, -1e300, .infinity, .nan] as [Double])
    func moveMouseDoesNotTrapOnHugeCoordinates(_ x: Double) async throws {
        let bridge = AgentBrowserBridge(backend: PointerStubBackend())
        let result = await bridge.moveMouse(["x": .number(x), "y": .number(0)])
        // The contract is that the process SURVIVES and answers. Whether it moves or
        // declines is the implementation's business; trapping is not.
        #expect(!result.output.isEmpty, "moveMouse produced no answer")
    }

    @Test("drag survives a step count no Int can hold, and does not run forever",
          arguments: [1e300, -1e300, .infinity, .nan] as [Double])
    func dragDoesNotTrapOnHugeStepCount(_ steps: Double) async throws {
        let backend = PointerStubBackend()
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.drag([
            "fromX": .number(0), "fromY": .number(0),
            "toX": .number(10), "toY": .number(10),
            "steps": .number(steps)
        ])
        #expect(!result.output.isEmpty, "drag produced no answer")
        // The cap, observed rather than asserted on the constant: press + release + at
        // most 200 moves + the initial position.
        #expect(backend.mouseEvents <= 203, "drag dispatched \(backend.mouseEvents) events")
    }

    @Test("drag survives coordinates no Int can hold")
    func dragDoesNotTrapOnHugeCoordinates() async throws {
        let bridge = AgentBrowserBridge(backend: PointerStubBackend())
        let result = await bridge.drag([
            "fromX": .number(-1e300), "fromY": .number(0),
            "toX": .number(1e300), "toY": .number(0),
            "steps": .number(2)
        ])
        #expect(!result.output.isEmpty, "drag produced no answer")
    }

    @Test("a duration no Double can sleep does not hang the turn")
    func dragDoesNotTrapOnHugeDuration() async throws {
        let bridge = AgentBrowserBridge(backend: PointerStubBackend())
        let result = await bridge.drag([
            "fromX": .number(0), "fromY": .number(0),
            "toX": .number(10), "toY": .number(10),
            "steps": .number(2), "duration": .number(1e300)
        ])
        #expect(!result.output.isEmpty, "drag produced no answer")
    }

    /// The bounds must not have turned the pointer verbs into no-ops.
    @Test("an ordinary drag still dispatches mouse events")
    func ordinaryDragStillWorks() async throws {
        let backend = PointerStubBackend()
        let bridge = AgentBrowserBridge(backend: backend)
        let result = await bridge.drag([
            "fromX": .number(4), "fromY": .number(6),
            "toX": .number(40), "toY": .number(60),
            "steps": .number(3)
        ])
        #expect(result.isError != true, "an ordinary drag failed: \(result.output)")
        #expect(backend.mouseEvents > 0, "no mouse event was dispatched")
        #expect(result.output.contains("(4, 6)") && result.output.contains("(40, 60)"),
                "the receipt lost its coordinates: \(result.output)")
    }
}

@MainActor
private final class PointerStubBackend: AgentBridgeBackend {
    var mouseEvents = 0
    var isAborted: Bool { false }
    func consumeAgentDownloads() -> [CapturedDownload] { [] }
    func evaluateViaCdp(_ expression: String) async throws -> JSValue? { nil }
    @discardableResult
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue]) async throws -> JSValue {
        if domain == "Input", command == "dispatchMouseEvent" { mouseEvents += 1 }
        return .null
    }
    func captureViewport() async throws -> (base64: String, imageWidth: Int, imageHeight: Int)? { nil }
    func viewportDimensions() -> ViewportSize? { nil }
    func resolveSandboxSavePath(_ path: String) -> String? { nil }
    func writeScreenshot(base64: String, hostPath: String, isPng: Bool) async throws {}
}
