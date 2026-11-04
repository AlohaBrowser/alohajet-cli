#if canImport(Darwin)
import Foundation
import Testing
@testable import CDP

// A client's default WebSocket session keeps nothing on disk: `.shared`, in the bare `alohajet`
// executable, keeps its HTTP storage in `~/Library/HTTPStorages/alohajet`, one for every app's copy
// of the CLI (the desktop's jet-e2e build's `--browser aloha` lane wrote the user's AlohaJet's).
@Test func theDefaultWebSocketSessionPersistsNothing() {
    let configuration = CDPClient.defaultSession.configuration
    #expect((configuration.urlCache?.diskCapacity ?? 0) == 0)
    #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    #expect(configuration.urlCredentialStorage !== URLCredentialStorage.shared)
}
#endif
