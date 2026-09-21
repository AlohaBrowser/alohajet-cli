import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// A loopback HTTP server for the end-to-end test, in ~70 lines of POSIX sockets.
//
// The page under test cannot be a `file://` URL — the tools reject that scheme on
// purpose, and rightly — so an end-to-end run needs an origin. This writes a
// python3 script to a temp file and runs it; this package has no python dependency and
// should not acquire one to serve four hundred bytes of HTML.
//
// KNOWN CEILING: one connection at a time, one response body, no keep-alive, no MIME table.
// It answers every request with the same page, which is all a fixture needs. Give it a
// route table when a test needs two pages.
nonisolated final class LocalPageServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private let body: Data
    private(set) var port: Int = 0

    var url: String { "http://127.0.0.1:\(port)/" }

    init(html: String) {
        self.body = Data(html.utf8)
    }

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM_VALUE, 0)
        guard listenFD >= 0 else { throw Failure.socket(errno) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                      // let the kernel pick a free port
        address.sin_addr.s_addr = INADDR_LOOPBACK_BE
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else {
            close(listenFD)
            throw Failure.bind(errno)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenFD, $0, &length) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))

        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "alohajet.test.http"
        thread.start()
        self.thread = thread
    }

    func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { close(fd) }
    }

    private func serve() {
        var header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
        header += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = Data(header.utf8) + body
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }              // the listener was closed: we are done
            var scratch = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &scratch, scratch.count, 0)   // request line: read and discard
            response.withUnsafeBytes { buffer in
                var sent = 0
                while sent < buffer.count {
                    let wrote = send(client, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                    if wrote <= 0 { break }
                    sent += wrote
                }
            }
            close(client)
        }
    }

    enum Failure: Error { case socket(Int32), bind(Int32) }
}

#if canImport(Glibc)
private nonisolated let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
#else
private nonisolated let SOCK_STREAM_VALUE = SOCK_STREAM
#endif
/// 127.0.0.1 in network byte order.
private nonisolated let INADDR_LOOPBACK_BE: in_addr_t = (127 << 24 | 1).bigEndian
