import Testing
@testable import BrowserTools

@Test @MainActor func toolListIsTheEightPageTools() {
    #expect(nativeAgentToolNames.count == 8)
    #expect(getNativeAgentTools().map(\.name) == nativeAgentToolNames)
}
