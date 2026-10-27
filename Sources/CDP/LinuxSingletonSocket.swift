#if os(Linux)
import Foundation
import Glibc

// Chromium on Linux binds its process-singleton socket at
// `$TMPDIR/<product>.XXXXXX/SingletonSocket`, and a path that overflows `sun_path` is a
// FATAL "Socket path too long" (exit 6) before the debug port is served. So an inherited
// TMPDIR past ~60 bytes — a CI runner's, a sandbox's that nests a few levels deep — failed
// every launch as "exited without serving the CDP endpoint". The browser is given a short
// private TMPDIR instead; this process's own temp, and the profile in it, stay where they are.
extension ChromeLauncher {
    /// Sized for `org.chromium.Chromium`, an unbranded build's product name and the longest
    /// the template takes; Google Chrome's `com.google.Chrome` leaves it 4 bytes of slack.
    static let longestSingletonTemporaryDirectory =
        MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        - "/org.chromium.Chromium.XXXXXX/SingletonSocket".utf8.count

    static func singletonSocketOverflows(temporaryDirectory path: String) -> Bool {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.utf8.count > longestSingletonTemporaryDirectory
    }

    /// The environment to launch the browser with, or `nil` to let it inherit this one.
    static func browserEnvironment(
        inheriting environment: [String: String],
        fallback: String = "/tmp/alohajet-\(getuid())"
    ) throws -> [String: String]? {
        guard let inherited = environment["TMPDIR"],
              singletonSocketOverflows(temporaryDirectory: inherited)
        else { return nil }
        var environment = environment
        environment["TMPDIR"] = try privateDirectory(at: fallback)
        return environment
    }

    /// `path` as a directory only this user can enter, created 0700 when it is missing.
    /// `/tmp` is shared, and whoever controls the directory controls the browser's
    /// singleton socket, so one that is not exactly that is refused rather than used.
    static func privateDirectory(at path: String) throws -> String {
        if mkdir(path, 0o700) != 0 {
            let error = errno
            guard error == EEXIST else {
                throw CDPError.discoveryFailed(
                    "could not create \(path) for the browser's temp: \(String(cString: strerror(error)))")
            }
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else {
            throw CDPError.discoveryFailed("""
                TMPDIR is too long for the browser's singleton socket, and \(path) is not a \
                directory only this user can enter, so it cannot stand in; set a TMPDIR of at \
                most \(longestSingletonTemporaryDirectory) bytes
                """)
        }
        return path
    }
}
#endif
