#if os(Linux)
import Testing
import Foundation
import Glibc
@testable import CDP

// Pins the descriptor ownership of the Linux WebSocket channel's teardown.
//
// `close()` wakes the reader thread with an error on its own shutdown, so both paths ran
// teardown; when both read the same `fd`, the descriptor was closed twice and the second
// close landed on whatever socket had since been given the recycled number.
//
// The test recreates that: close the channel, immediately claim a descriptor, then give
// the reader thread time to run. A surviving sentinel means only one path owns the fd.

/// A loopback server that completes the WebSocket handshake and then stays silent, so the
/// channel's reader thread is parked in `recv` exactly as it is against a real browser.
private final class HandshakeOnlyWebSocketServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private(set) var port: Int = 0
    private var accepted: Int32 = -1

    func start() throws {
        listenFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard listenFD >= 0 else { throw ServerError.socketFailed(errno) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else { throw ServerError.bindFailed(errno) }

        var bound_addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound_addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &length)
            }
        }
        port = Int(UInt16(bigEndian: bound_addr.sin_port))

        let listening = listenFD
        Thread.detachNewThread { [weak self] in
            let client = accept(listening, nil, nil)
            guard client >= 0 else { return }
            self?.accepted = client
            // Read the upgrade request, then answer 101 — all the channel checks for.
            var seen = [UInt8]()
            var byte: UInt8 = 0
            while seen.suffix(4) != [0x0d, 0x0a, 0x0d, 0x0a] {
                if recv(client, &byte, 1, 0) != 1 { return }
                seen.append(byte)
            }
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            _ = Array(response.utf8).withUnsafeBytes { send(client, $0.baseAddress!, $0.count, 0) }
            // Then stay silent: the channel's reader parks in recv until teardown.
        }
    }

    func stop() {
        if accepted >= 0 { _ = Glibc.close(accepted); accepted = -1 }
        if listenFD >= 0 { _ = Glibc.close(listenFD); listenFD = -1 }
    }

    enum ServerError: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
    }
}

@Suite("LinuxWebSocketChannel close ownership", .serialized)
struct LinuxWebSocketChannelCloseTests {

    @Test("closing the channel does not close a descriptor handed out afterwards")
    func closeReleasesTheDescriptorExactlyOnce() async throws {
        // A few rounds: the sentinel claims the descriptor the channel just released, so a
        // second close is caught on the first round — the repetition only guards against a
        // scheduling fluke masking it.
        for round in 1...5 {
            let server = HandshakeOnlyWebSocketServer()
            try server.start()
            defer { server.stop() }

            let channel = LinuxWebSocketChannel(
                url: URL(string: "ws://127.0.0.1:\(server.port)/devtools/page/test")!)
            await channel.open()
            // `open()` is best-effort; prove the channel really connected before drawing
            // any conclusion from the teardown.
            try await channel.send("{\"id\":1,\"method\":\"Target.getTargets\"}")

            await channel.close()

            // The kernel hands back the lowest free descriptor — normally the one the
            // channel just closed.
            let sentinel = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            try #require(sentinel >= 0, "could not open a sentinel socket (errno \(errno))")
            defer { _ = Glibc.close(sentinel) }

            // Let the reader thread wake on the shutdown and run its failure path.
            try await Task.sleep(for: .milliseconds(250))

            #expect(fcntl(sentinel, F_GETFD) != -1,
                    "round \(round): the sentinel descriptor was closed by the channel's reader — close() and fail() both owned it")
        }
    }
}
#endif
