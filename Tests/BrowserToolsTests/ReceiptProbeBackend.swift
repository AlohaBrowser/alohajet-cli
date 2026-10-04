import Foundation
import ToolABI
@testable import BrowserTools

/// A scripted `AgentBridgeBackend` for the receipt probes: answers `evaluateViaCdp` from a list,
/// in call order (the last answer repeats once the list is spent), or throws; records every
/// script it was asked. Shared by the receipt test files, the way `PageToolsRecordingBackend`
/// serves the driver-level tests.
@MainActor
final class ReceiptProbeBackend: AgentBridgeBackend {
    private var answers: [JSValue?]
    let error: Error?
    private(set) var scripts: [String] = []

    init(_ answers: [JSValue?] = [], error: Error? = nil) {
        self.answers = answers
        self.error = error
    }

    /// How many scripts the bridge sent.
    var asked: Int { scripts.count }

    var isAborted: Bool { false }
    func consumeAgentDownloads() -> [CapturedDownload] { [] }
    func evaluateViaCdp(_ expression: String) async throws -> JSValue? {
        scripts.append(expression)
        if let error { throw error }
        if answers.count > 1 { return answers.removeFirst() }
        return answers.first ?? nil
    }
    @discardableResult
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue]) async throws -> JSValue { .null }
    func captureViewport() async throws -> (base64: String, imageWidth: Int, imageHeight: Int)? { nil }
    func viewportDimensions() -> ViewportSize? { nil }
    func resolveSandboxSavePath(_ path: String) -> String? { nil }
    func writeScreenshot(base64: String, hostPath: String, isPng: Bool) async throws {}
}

struct ReceiptProbeFailure: Error {}
