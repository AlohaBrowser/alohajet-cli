#if canImport(Darwin)
import Foundation
import Testing
@testable import AgentDriver

// The live transport keeps nothing on disk. `URLSession.shared`, in the bare `alohajet`
// executable, keeps its cache and HTTP storage under the process name (`~/Library/Caches/alohajet`,
// `HTTPStorages/alohajet`), one pair for every app's copy of the CLI: the desktop's jet-e2e build
// polled `/agent/result` through it into the user's AlohaJet's cache.
@Test func theLiveTransportSessionPersistsNothing() {
    let configuration = RemoteAutomationDriver.session.configuration
    #expect((configuration.urlCache?.diskCapacity ?? 0) == 0)
    #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    #expect(configuration.urlCredentialStorage !== URLCredentialStorage.shared)
}
#endif
