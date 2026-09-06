import Foundation

// MARK: - The temporary directory, honouring $TMPDIR

/// Where this process may write throwaway state: `$TMPDIR` when the environment sets
/// one, else the platform default.
///
/// `NSTemporaryDirectory()` and `FileManager.temporaryDirectory` do NOT read `$TMPDIR`
/// on Darwin — they return `confstr(_CS_DARWIN_USER_TEMP_DIR)`, the per-user
/// `/var/folders/…/T` the kernel hands out, and there is no environment variable that
/// moves it. Everything this package leaves in temp is process-lifetime state that a
/// caller must be able to redirect: the shared browser recorded at
/// `<tmp>/alohajet-<uid>/browser.json`, the throwaway `alohajet-cdp-<uuid>` profiles, and
/// the profile reaper that DELETES them. `Tests/CLITests` sets `TMPDIR` to a fresh
/// sandbox per invocation for exactly that reason, and until this existed the isolation
/// was fictional: the suite reached the developer's real shared browser and cleared it.
///
/// One reader, so the CLI, the launcher and the reaper cannot disagree about which
/// directory they are looking at — a reaper pointed at a different temp than the launcher
/// deletes nothing, or the wrong thing.
public nonisolated var temporaryDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["TMPDIR"], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.temporaryDirectory
}
