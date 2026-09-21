import Foundation
#if canImport(FoundationNetworking)
// `URLSession` lives in a separate module off Apple.
import FoundationNetworking
#endif
import Testing
@testable import BrowserTools

@Suite("local page server") struct LocalPageServerSelfTest {
    @Test func servesThePageOverLoopback() async throws {
        let server = LocalPageServer(html: "<html><body>SERVED-OK</body></html>")
        try server.start()
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: #require(URL(string: server.url)))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("SERVED-OK"))
    }
}
