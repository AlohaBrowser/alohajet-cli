import Testing
@testable import BrowserTools

@Test @MainActor func toolListIsTheNinePageTools() {
    #expect(nativeAgentToolNames.count == 9)
    #expect(getNativeAgentTools().map(\.name) == nativeAgentToolNames)
}
