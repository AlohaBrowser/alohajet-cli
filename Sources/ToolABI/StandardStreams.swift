import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

// MARK: - Writing to stdout and stderr, portably
//
// Three plausible ways to put a line on a standard stream, and on Linux two of them
// are wrong:
//
//   `fputs(text, stdout)`      — Glibc declares `stdin`/`stdout`/`stderr` as `var`s of
//                                OPTIONAL pointer type where Darwin declares
//                                non-optional `let`s. Under Swift 6 that is both a
//                                "shared mutable state" concurrency error and a type
//                                error, and the package does not compile at all.
//   `FileHandle.standardOutput.write(_:)`
//                              — compiles everywhere and TRAPS on Linux:
//                                corelibs-Foundation's implementation is a `try!`
//                                (Foundation/FileHandle.swift:699) that turns a
//                                perfectly ordinary `EINTR` into
//                                `Fatal error: 'try!' expression unexpectedly raised
//                                an error … "Interrupted system call"`. Observed, not
//                                theorised: it killed the test process on the first
//                                Linux run of this package's own CLI suite.
//
// So: `write(2)` on the fd, with the EINTR retry loop the C call has always required.
// Unbuffered, which is what the MCP framing needs anyway — a response sitting in a
// buffer that never flushes is a hung host.

/// Writes `text` to stdout, retrying on `EINTR` and short writes.
public nonisolated func writeToStandardOutput(_ text: String) {
    writeAll(STDOUT_FILENO, text)
}

/// Writes `text` to stderr, retrying on `EINTR` and short writes.
public nonisolated func writeToStandardError(_ text: String) {
    writeAll(STDERR_FILENO, text)
}

private nonisolated func writeAll(_ descriptor: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        while offset < buffer.count {
            let written = write(descriptor, base + offset, buffer.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            // EINTR is a signal arriving mid-write, not a failure. Anything else —
            // EPIPE from `alohajet read | head`, a closed descriptor — is not
            // recoverable and is not worth crashing over: the message is a diagnostic.
            if written < 0 && errno == EINTR { continue }
            return
        }
    }
}
