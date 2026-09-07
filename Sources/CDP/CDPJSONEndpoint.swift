import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Reading Chrome's /json* endpoints
//
// Read with a small socket client rather than `URLSession`, because Chrome emits header
// lines with no space after the colon (`Content-Length:414`) and corelibs' URLSession
// rejects that form with `Failed writing header` — so no CDP endpoint could be
// discovered on Linux at all. Pinned by
// `CDPListTargetsTests.readsHeadersWrittenWithoutASpaceAfterTheColon`.
//
// Deliberately used on every platform, not behind a conditional: these endpoints are a
// localhost debug interface answering a tiny GET, and one path exercised everywhere
// beats two where each is only ever tested on one platform.

public enum CDPJSONEndpointError: Error, CustomStringConvertible, Sendable {
    case invalidHost(String)
    case invalidPort(Int)
    case socketCreationFailed(errno: Int32)
    case connectionFailed(host: String, port: Int, errno: Int32)
    case timedOut(seconds: Double)
    case readFailed(errno: Int32)
    case malformedResponse(String)
    case httpStatus(Int)

    public var description: String {
        switch self {
        case .invalidHost(let host):
            return "not an IPv4 literal: \(host)"
        case .invalidPort(let port):
            return "not a TCP port: \(port) (expected 1-65535)"
        case .socketCreationFailed(let code):
            return "socket() failed (errno \(code))"
        case .connectionFailed(let host, let port, let code):
            return "could not connect to \(host):\(port) (errno \(code))"
        case .timedOut(let seconds):
            return "timed out after \(seconds)s"
        case .readFailed(let code):
            return "read failed (errno \(code))"
        case .malformedResponse(let detail):
            return "malformed HTTP response: \(detail)"
        case .httpStatus(let code):
            return "HTTP \(code)"
        }
    }
}

/// Glibc imports `SOCK_STREAM` as a C enum; Darwin declares it as `Int32`.
#if canImport(Darwin)
private let cdpSockStream = SOCK_STREAM
#else
private let cdpSockStream = Int32(SOCK_STREAM.rawValue)
#endif

/// Runs the blocking socket work on its own thread so the cooperative pool is never
/// occupied by a syscall wait.
func cdpJSONEndpointGet(
    host: String,
    port: Int,
    path: String,
    timeoutSeconds: Double = 5
) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            do {
                let body = try cdpJSONEndpointGetBlocking(
                    host: host, port: port, path: path, timeoutSeconds: timeoutSeconds)
                continuation.resume(returning: body)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Reads until `Content-Length` bytes of body have arrived, falling back to EOF only
/// when the response carries no length: Chrome ignores the `Connection: close` this
/// request asks for, so waiting for EOF would block until the timeout.
private func cdpJSONEndpointGetBlocking(
    host: String,
    port: Int,
    path: String,
    timeoutSeconds: Double
) throws -> Data {
    // `UInt16(port)` TRAPS on anything wider — `alohajet --cdp 99999 tabs` died with
    // "Not enough bits to represent the passed value" and exit 133 instead of the
    // documented exit 3. A port arrives from argv, from a handshake file and from a
    // library caller; none of them may kill the process.
    guard let networkPort = UInt16(exactly: port), networkPort > 0 else {
        throw CDPJSONEndpointError.invalidPort(port)
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = networkPort.bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
        throw CDPJSONEndpointError.invalidHost(host)
    }

    let fd = socket(AF_INET, cdpSockStream, 0)
    guard fd >= 0 else { throw CDPJSONEndpointError.socketCreationFailed(errno: errno) }
    defer { _ = close(fd) }

    // Bound waits on both directions: a browser that accepts and then stalls must not
    // hold this thread open indefinitely.
    let wholeSeconds = Int(timeoutSeconds)
    var timeout = timeval(
        tv_sec: wholeSeconds,
        tv_usec: Self_suseconds((timeoutSeconds - Double(wholeSeconds)) * 1_000_000))
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        throw CDPJSONEndpointError.connectionFailed(host: host, port: port, errno: errno)
    }

    let request = [
        "GET \(path) HTTP/1.1",
        "Host: \(host):\(port)",
        "Accept: application/json",
        "Connection: close",
        "", "",
    ].joined(separator: "\r\n")
    let requestBytes = Data(request.utf8)
    try requestBytes.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let written = send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
            if written <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CDPJSONEndpointError.timedOut(seconds: timeoutSeconds)
                }
                throw CDPJSONEndpointError.readFailed(errno: errno)
            }
            sent += written
        }
    }

    var response = Data()
    var scratch = [UInt8](repeating: 0, count: 16 * 1024)
    let headerTerminator = Data("\r\n\r\n".utf8)
    while true {
        // Stop as soon as the announced body length has arrived; see the note above.
        if let terminator = response.range(of: headerTerminator) {
            let header = response[response.startIndex..<terminator.lowerBound]
            if let expected = cdpJSONEndpointContentLength(inHeaderBytes: header) {
                let received = response.distance(from: terminator.upperBound, to: response.endIndex)
                if received >= expected { break }
            }
        }
        let count = recv(fd, &scratch, scratch.count, 0)
        if count > 0 {
            response.append(contentsOf: scratch[0..<count])
            continue
        }
        if count == 0 { break }  // EOF — the only stop condition without a length.
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            throw CDPJSONEndpointError.timedOut(seconds: timeoutSeconds)
        }
        throw CDPJSONEndpointError.readFailed(errno: errno)
    }

    return try cdpJSONEndpointBody(of: response)
}


/// The `Content-Length` a header block announces, if any. Case-insensitive, and
/// tolerates the missing space after the colon that Chrome writes.
func cdpJSONEndpointContentLength<Bytes: DataProtocol>(inHeaderBytes bytes: Bytes) -> Int? {
    guard let text = String(data: Data(bytes), encoding: .utf8) else { return nil }
    for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        guard name.lowercased() == "content-length" else { continue }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return Int(value)
    }
    return nil
}

func cdpJSONEndpointBody(of response: Data) throws -> Data {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerEnd = response.range(of: separator) else {
        throw CDPJSONEndpointError.malformedResponse("no CRLF CRLF header terminator")
    }
    let headerBytes = response[response.startIndex..<headerEnd.lowerBound]
    guard let headerText = String(data: headerBytes, encoding: .utf8),
          let statusLine = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).first
    else {
        throw CDPJSONEndpointError.malformedResponse("unreadable header block")
    }
    let statusFields = statusLine.split(separator: " ", omittingEmptySubsequences: true)
    guard statusFields.count >= 2, let status = Int(statusFields[1]) else {
        throw CDPJSONEndpointError.malformedResponse("unparseable status line: \(statusLine)")
    }
    guard (200..<300).contains(status) else {
        throw CDPJSONEndpointError.httpStatus(status)
    }
    return Data(response[headerEnd.upperBound...])
}

/// `timeval.tv_usec` is `__darwin_suseconds_t` on Apple and `Int` on Glibc.
#if canImport(Darwin)
private func Self_suseconds(_ value: Double) -> __darwin_suseconds_t {
    __darwin_suseconds_t(value)
}
#else
private func Self_suseconds(_ value: Double) -> Int {
    Int(value)
}
#endif
