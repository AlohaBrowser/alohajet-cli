import Testing
import Foundation
@testable import CDP
import ToolABI

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Coverage for the public target-list read seam `CDPClient.listTargets()`
/// (extracted from `BrowserDemo.verifyTargets`'s `GET /json` reader).
///
/// The read is exercised two ways without a real browser:
///  - `parseTargets(from:)` — the pure parser — against stubbed `/json` bytes,
///    proving parsed targets come back and an empty list yields `[]` (not throw);
///  - `listTargets(host:port:)` — the full HTTP path — against a real
///    loopback HTTP server that serves a canned `/json` response.
@Suite struct CDPListTargetsTests {

    // MARK: Pure parser

    @Test func parsesAllTargetsFromJSON() throws {
        let json = """
        [
          {"id":"A1","type":"page","title":"Example","url":"https://example.com/"},
          {"id":"B2","type":"background_page","title":"Ext","url":"chrome-extension://x/bg.html"}
        ]
        """
        let targets = CDPClient.parseTargets(from: Data(json.utf8))

        #expect(targets.count == 2)
        #expect(targets[0] == CDPTarget(id: "A1", type: "page", title: "Example", url: "https://example.com/"))
        #expect(targets[1] == CDPTarget(id: "B2", type: "background_page", title: "Ext", url: "chrome-extension://x/bg.html"))
    }

    @Test func emptyListYieldsEmptyArrayNotThrow() throws {
        let targets = CDPClient.parseTargets(from: Data("[]".utf8))
        #expect(targets.isEmpty)
    }

    @Test func entryMissingIdIsSkippedAndAbsentFieldsDefaultToEmpty() throws {
        // First entry has no `id` (skipped); second omits type/title/url.
        let json = """
        [
          {"type":"page","url":"https://no-id.example/"},
          {"id":"OnlyId"}
        ]
        """
        let targets = CDPClient.parseTargets(from: Data(json.utf8))

        #expect(targets.count == 1)
        #expect(targets[0] == CDPTarget(id: "OnlyId", type: "", title: "", url: ""))
    }

    @Test func nonArrayPayloadYieldsEmptyArray() throws {
        // A `/json` body that isn't an array of objects is treated as "no
        // targets" (matching the legacy reader's tolerance), not an error.
        #expect(CDPClient.parseTargets(from: Data("{\"unexpected\":true}".utf8)).isEmpty)
        #expect(CDPClient.parseTargets(from: Data("not json".utf8)).isEmpty)
    }

    // MARK: Full HTTP path against a loopback endpoint

    @Test func listTargetsReadsAndParsesStubbedJSONEndpoint() async throws {
        let body = """
        [
          {"id":"T-1","type":"page","title":"Home","url":"https://home.test/"}
        ]
        """
        let endpoint = try LoopbackJSONEndpoint(body: Data(body.utf8))
        defer { endpoint.shutDown() }

        let targets = try await CDPClient.listTargets(
            host: "127.0.0.1",
            port: endpoint.port
        )

        #expect(targets == [CDPTarget(id: "T-1", type: "page", title: "Home", url: "https://home.test/")])
    }

    /// Chrome writes its `/json*` headers with NO space after the colon
    /// (`Content-Length:414`), which corelibs' URLSession rejects with "Failed writing
    /// header" — making CDP discovery impossible on Linux. `listTargets` reads over a
    /// socket for this reason; the test stops a switch back to URLSession passing.
    @Test func readsHeadersWrittenWithoutASpaceAfterTheColon() async throws {
        let body = Data("""
        [{"id":"T-1","type":"page","title":"Home","url":"https://home.test/"}]
        """.utf8)
        let endpoint = try LoopbackJSONEndpoint(
            body: body,
            headerLinesOverride: [
                "HTTP/1.1 200 OK",
                // Exactly Chrome's spelling, including the missing spaces.
                "Content-Security-Policy:frame-ancestors 'none'",
                "Content-Length:\(body.count)",
                "Content-Type:application/json; charset=UTF-8",
            ]
        )
        defer { endpoint.shutDown() }

        let targets = try await CDPClient.listTargets(host: "127.0.0.1", port: endpoint.port)
        #expect(targets == [CDPTarget(id: "T-1", type: "page", title: "Home", url: "https://home.test/")])
    }

    @Test func listTargetsYieldsEmptyOnEmptyEndpointList() async throws {
        let endpoint = try LoopbackJSONEndpoint(body: Data("[]".utf8))
        defer { endpoint.shutDown() }

        let targets = try await CDPClient.listTargets(
            host: "127.0.0.1",
            port: endpoint.port
        )

        #expect(targets.isEmpty)
    }
}

// MARK: - Loopback HTTP endpoint

/// Glibc imports `SOCK_STREAM` as a C enum; Darwin declares it as `Int32`.
#if canImport(Darwin)
private let sockStreamValue = SOCK_STREAM
#elseif canImport(Glibc)
private let sockStreamValue = Int32(SOCK_STREAM.rawValue)
#endif

/// A loopback HTTP server on a kernel-assigned port that answers every request with
/// the same `200 application/json` body.
///
/// Replaces a `URLProtocol` stub, which is not portable: corelibs' libcurl-backed
/// `URLSession` never consults `protocolClasses`, so the subclass is silently bypassed.
/// The port is kernel-assigned so repeated runs cannot collide.
private struct LoopbackJSONEndpoint {
    /// The bound port to point `listTargets` at.
    let port: Int
    private let listenFD: Int32
    /// Signalled by the serving thread as it exits, so `shutDown()` can be sure the
    /// thread is gone before the descriptor is released.
    private let threadDidExit = DispatchSemaphore(value: 0)

    init(body: Data, headerLinesOverride: [String]? = nil) throws {
        let fd = socket(AF_INET, sockStreamValue, 0)
        guard fd >= 0 else { throw EndpointError.socketFailed }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // kernel picks a free port
        addr.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian  // 127.0.0.1
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            _ = close(fd)
            throw EndpointError.bindFailed
        }

        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }

        self.listenFD = fd
        self.port = Int(UInt16(bigEndian: boundAddr.sin_port))

        // Built by joining rather than as a multi-line literal: Swift drops the
        // newline before the closing delimiter, which would leave the header block
        // terminated by a bare CR and make the response unparseable.
        let headerLines: [String] = headerLinesOverride ?? [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        var responseBytes = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        responseBytes.append(body)
        // Bound as a `let` so the serving closure captures an immutable value.
        let response = responseBytes

        // Serve on a detached thread. `accept` blocks; `shutDown()` calls `shutdown`
        // on the listener, which wakes it with an error and ends the loop.
        //
        // The THREAD owns closing `fd` and signals `threadDidExit` on the way out —
        // single ownership, so the descriptor number cannot be recycled under a thread
        // that is between iterations rather than parked in `accept`.
        let exitSignal = threadDidExit
        Thread.detachNewThread {
            defer {
                _ = close(fd)
                exitSignal.signal()
            }
            while true {
                let connection = accept(fd, nil, nil)
                if connection < 0 { return }
                // Read the request line and headers so the client is not answered
                // before it has finished writing (which would surface as a reset).
                var scratch = [UInt8](repeating: 0, count: 4096)
                _ = read(connection, &scratch, scratch.count)
                response.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let written = write(connection, raw.baseAddress! + sent, raw.count - sent)
                        if written <= 0 { break }
                        sent += written
                    }
                }
                _ = close(connection)
            }
        }
    }

    /// Ends the serving thread and waits for it to release the listener.
    ///
    /// `shutdown`, not `close`: closing a descriptor another thread is blocked in
    /// `accept` on is not guaranteed to wake it. The wait is bounded so a wedged thread
    /// fails its own test rather than hanging the suite.
    func shutDown() {
        _ = shutdown(listenFD, Int32(SHUT_RDWR))
        _ = threadDidExit.wait(timeout: .now() + .seconds(5))
    }

    enum EndpointError: Error {
        case socketFailed
        case bindFailed
    }
}
