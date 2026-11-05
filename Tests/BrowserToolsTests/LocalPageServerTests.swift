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

    /// A form posted to the fixture is answered with the page, not a reset connection.
    @Test func answersAPostAfterReadingItsWholeBody() async throws {
        let server = LocalPageServer(html: "<html><body>SERVED-OK</body></html>")
        try server.start()
        defer { server.stop() }
        var request = URLRequest(url: try #require(URL(string: server.url)))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(repeating: UInt8(ascii: "a"), count: 512 * 1024)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("SERVED-OK"))
    }
}
