#if os(Linux)
import Testing
import Glibc

func freeLoopbackPort() throws -> Int {
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    try #require(bound)
    return Int(UInt16(bigEndian: address.sin_port))
}
#endif
