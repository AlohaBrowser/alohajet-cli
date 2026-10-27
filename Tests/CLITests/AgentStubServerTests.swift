import Foundation
import Testing

@Suite("the agent stub server")
struct AgentStubServerTests {

    // Two suites bind the app's fixed port, 8765, one after the other. A stub that kept
    // its port after `stop()` failed whichever ran second with EADDRINUSE. The request
    // first, and the pause after it, put the serving thread back in `accept`, which is
    // where a bare `close` on Linux leaves the socket listening.
    @Test("a stopped stub frees its port for the next one")
    func stopFreesThePort() throws {
        let first = AgentStubServer()
        try first.start()
        let port = UInt16(first.port)
        _ = try? Data(contentsOf: try #require(URL(string: first.url + "/agent/lane")))
        #expect(first.paths == ["/agent/lane"])
        Thread.sleep(forTimeInterval: 0.2)
        first.stop()

        let second = AgentStubServer(port: port)
        try second.start()
        second.stop()
    }
}
