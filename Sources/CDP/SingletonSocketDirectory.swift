#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Chrome binds its process-singleton socket in a `<product>.XXXXXX` directory under its TMPDIR
// and links `<profile>/SingletonSocket` to it, and it removes that directory on an orderly exit
// only. A browser stopped by SIGTERM or SIGKILL left one behind for every launch.
extension ChromeLauncher {

    private static let singletonDirectoryEntries: Set<String> = ["SingletonSocket", "SingletonCookie"]

    /// Remove the directory `profile`'s `SingletonSocket` link points into, when `profile`'s
    /// `SingletonLock` names `pid`. Call it once that browser is gone.
    ///
    /// The lock is what proves the link is that browser's: a caller's own profile can be one
    /// some other Chrome holds, and its link then names that Chrome's live socket. The directory
    /// must then be the one Chrome makes, a real directory of this user's named like
    /// `com.google.Chrome.XXXXXX`, holding nothing but the socket and its cookie. Those two are
    /// unlinked and the directory `rmdir`ed, which cannot take anything else with it.
    static func removeSingletonSocketDirectory(ofProfile profile: URL, lockedBy pid: Int32) {
        let manager = FileManager.default
        guard let lock = try? manager.destinationOfSymbolicLink(
                atPath: profile.appendingPathComponent("SingletonLock").path),
              lock.hasSuffix("-\(pid)"),
              let socket = try? manager.destinationOfSymbolicLink(
                atPath: profile.appendingPathComponent("SingletonSocket").path),
              socket.hasPrefix("/"), (socket as NSString).lastPathComponent == "SingletonSocket"
        else { return }
        let directory = (socket as NSString).deletingLastPathComponent
        var info = stat()
        guard isSingletonDirectoryName((directory as NSString).lastPathComponent),
              lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              let entries = try? manager.contentsOfDirectory(atPath: directory),
              Set(entries).isSubset(of: singletonDirectoryEntries)
        else { return }
        for entry in entries { _ = unlink((directory as NSString).appendingPathComponent(entry)) }
        _ = rmdir(directory)
    }

    /// A reverse-DNS product name and mkdtemp's six characters, optionally behind a dot.
    private static func isSingletonDirectoryName(_ name: String) -> Bool {
        let parts = (name.hasPrefix(".") ? name.dropFirst() : Substring(name))
            .split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.last?.count == 6
            && parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            }
    }
}
#endif
