// Ported from the shipping CLI's `ChromiumProvisioner` (373 loc) together with its
// unit tests, which run entirely on injected fakes. It sits ON TOP of this package's
// `ChromeLauncher`: `ChromeLauncher.defaultExecutablePath` is resolution step 3, and
// the path this returns is what `BrowserToolSession.launch(executablePath:)` takes.
//
import Foundation
import CDP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A public, cross-platform Chrome-for-Testing fetcher. It resolves a per-OS/arch
// download URL from an in-repo table (no external browser-fetcher shell-out, which
// would add an unpinned download-tooling dependency on the target machine),
// downloads the archive, extracts it, stages it into an Application-Support cache
// directory, and returns the path to the launchable browser executable.
//
// The URL-resolution and cache-path logic is PURE (no I/O), and the network +
// extraction + filesystem probes are injected as closures, so the whole type is
// unit-testable with a fake downloader and no real network.

// MARK: - Platform key

/// The set of platform/architecture combinations Chrome-for-Testing publishes a
/// download for (including `linux-x64`).
public enum ChromiumPlatformKey: String, CaseIterable, Sendable, Hashable, Codable {
    case macArm64 = "mac-arm64"
    case macX64 = "mac-x64"
    case linuxX64 = "linux64"
    case windowsX64 = "win64"

    /// Whether this key targets a Windows platform.
    public var isWindows: Bool { self == .windowsX64 }
}

/// Error raised when the running platform/arch pair is not one of the supported
/// Chrome-for-Testing targets.
public struct UnsupportedChromiumPlatformError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    public let platform: String
    public let arch: String
    public init(platform: String, arch: String) {
        self.platform = platform
        self.arch = arch
    }
    public var description: String { "unsupported Chrome-for-Testing platform: \(platform)/\(arch)" }
    public var errorDescription: String? { description }
}

/// Maps a `platform`/`arch` pair (using the identifiers `darwin`/`win32`/`linux`
/// and `arm64`/`x64`) to a Chromium platform key, throwing when the combination
/// is unsupported.
public nonisolated func resolveChromiumPlatformKey(_ platform: String, _ arch: String) throws -> ChromiumPlatformKey {
    if platform == "darwin" && arch == "arm64" { return .macArm64 }
    if platform == "darwin" && arch == "x64" { return .macX64 }
    if platform == "linux" && arch == "x64" { return .linuxX64 }
    if platform == "win32" && arch == "x64" { return .windowsX64 }
    throw UnsupportedChromiumPlatformError(platform: platform, arch: arch)
}

/// Resolves the current process's Chromium platform key from the running OS and
/// CPU architecture, normalized to the Node-style identifiers.
public nonisolated func currentChromiumPlatformKey() throws -> ChromiumPlatformKey {
    #if os(macOS)
    let platform = "darwin"
    #elseif os(Windows)
    let platform = "win32"
    #else
    let platform = "linux"
    #endif
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x64"
    #endif
    return try resolveChromiumPlatformKey(platform, arch)
}

// MARK: - In-repo URL / version table

/// One Chrome-for-Testing build: the pinned version plus the per-platform
/// download URLs. NO `npx`/CDN discovery — the URLs are baked in so the exact
/// target machine needs nothing but network access to the published archive.
public nonisolated struct ChromiumBuildTable: Sendable, Equatable {
    /// The pinned Chrome-for-Testing version string (e.g. `126.0.6478.126`).
    public let version: String
    /// Per-platform download URLs.
    public let downloads: [ChromiumPlatformKey: String]

    public init(version: String, downloads: [ChromiumPlatformKey: String]) {
        self.version = version
        self.downloads = downloads
    }

    /// The pinned, in-repo Chrome-for-Testing build. URLs follow the published
    /// `storage.googleapis.com/chrome-for-testing-public/<version>/<platform>/chrome-<platform>.zip`
    /// layout used by the Chrome-for-Testing distribution.
    public static let pinned = ChromiumBuildTable(
        version: "126.0.6478.126",
        downloads: [
            .macArm64: "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/mac-arm64/chrome-mac-arm64.zip",
            .macX64: "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/mac-x64/chrome-mac-x64.zip",
            .linuxX64: "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/linux64/chrome-linux64.zip",
            .windowsX64: "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/win64/chrome-win64.zip",
        ]
    )

    /// The download URL for a platform key, or throws if the table has no entry.
    public func url(for key: ChromiumPlatformKey) throws -> String {
        guard let url = downloads[key] else {
            throw ChromiumProvisionerError.noDownloadForPlatform(key.rawValue)
        }
        return url
    }
}

// MARK: - Errors

public enum ChromiumProvisionerError: Error, Equatable, Sendable, CustomStringConvertible {
    case noDownloadForPlatform(String)
    case fetchFailed(String)
    case archiveExtractionFailed(String)
    case executableNotFoundAfterExtract(String)

    public var description: String {
        switch self {
        case let .noDownloadForPlatform(key):
            return "no Chrome-for-Testing download for platform \(key)"
        case let .fetchFailed(detail):
            return "Chrome-for-Testing fetch failed: \(detail)"
        case let .archiveExtractionFailed(detail):
            return "Chrome-for-Testing archive extraction failed: \(detail)"
        case let .executableNotFoundAfterExtract(path):
            return "Chrome-for-Testing executable not found after extract at \(path)"
        }
    }
}

// MARK: - ChromiumProvisioner

/// Downloads, extracts, and caches a Chrome-for-Testing build for the running
/// platform, and resolves the launchable browser executable path.
///
/// Resolution order on `resolveExecutablePath()`:
///   1. explicit `browserPath` (from CLI config) — short-circuits everything;
///   2. a previously-cached download under the Application-Support cache dir;
///   3. `ChromeLauncher.defaultExecutablePath` if a system Chrome is present;
///   4. trigger a download (fetch → extract → stage) and return the staged path.
///
/// All network/extraction/filesystem effects are injected so the URL-resolution
/// and cache-path logic stay pure and unit-testable without a real network.
@MainActor
public final class ChromiumProvisioner {
    /// Downloads a URL's bytes. Defaults to `URLSession.shared.data`; injected as
    /// a fake in tests. Main-isolated, releasing the actor at its internal `await`.
    public typealias Downloader = @MainActor @Sendable (URL) async throws -> Data
    /// Extracts an archive at a path into a directory. Defaults to the shared
    /// `unzip`/powershell extractor; injected as a fake in tests.
    public typealias Extractor = @MainActor @Sendable (_ archivePath: String, _ into: String) throws -> Void
    /// Reports whether an executable file exists at a path. Defaults to
    /// `FileManager.isExecutableFile`; injected in tests.
    public typealias ExecutableProbe = @MainActor @Sendable (String) -> Bool

    /// The explicit browser path from config; when set and present, it wins.
    public let browserPath: String?
    /// Root of the on-disk cache (an Application-Support subdirectory).
    public let cacheRoot: String
    /// The platform we are provisioning for.
    public let platformKey: ChromiumPlatformKey
    /// The in-repo URL/version table.
    public let buildTable: ChromiumBuildTable
    /// System-Chrome default executable path probe (resolution step 3).
    public let systemDefaultPath: String

    private let download: Downloader
    private let extract: Extractor
    private let executableExists: ExecutableProbe

    public init(
        browserPath: String? = nil,
        cacheRoot: String? = nil,
        platformKey: ChromiumPlatformKey? = nil,
        buildTable: ChromiumBuildTable = .pinned,
        systemDefaultPath: String = ChromeLauncher.defaultExecutablePath,
        download: @escaping Downloader = ChromiumProvisioner.defaultDownloader,
        extract: @escaping Extractor = ChromiumProvisioner.defaultExtractor,
        executableExists: @escaping ExecutableProbe = ChromiumProvisioner.defaultExecutableProbe
    ) throws {
        self.browserPath = browserPath
        self.cacheRoot = cacheRoot ?? ChromiumProvisioner.defaultCacheRoot()
        self.platformKey = try platformKey ?? currentChromiumPlatformKey()
        self.buildTable = buildTable
        self.systemDefaultPath = systemDefaultPath
        self.download = download
        self.extract = extract
        self.executableExists = executableExists
    }

    // MARK: Pure path / URL logic (no I/O)

    /// The default Application-Support cache root for staged Chrome-for-Testing
    /// builds, using a stable per-app subdirectory.
    public static func defaultCacheRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AlohaJet").appendingPathComponent("chrome-for-testing").path
    }

    /// The download URL for the configured platform. Pure.
    public func downloadURL() throws -> String {
        try buildTable.url(for: platformKey)
    }

    /// The directory the archive for this version/platform is staged into. Pure;
    /// keyed by version + platform so distinct builds never collide.
    public func stagedRootDir() -> String {
        URL(fileURLWithPath: cacheRoot)
            .appendingPathComponent(buildTable.version)
            .appendingPathComponent(platformKey.rawValue)
            .path
    }

    /// The relative path, inside the extracted archive, to the launchable
    /// executable for this platform. Pure. Follows the Chrome-for-Testing archive
    /// layout (`chrome-<platform>/<binary>`).
    public func executableRelativePath() -> String {
        switch platformKey {
        case .macArm64:
            return "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        case .macX64:
            return "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        case .linuxX64:
            return "chrome-linux64/chrome"
        case .windowsX64:
            return "chrome-win64/chrome.exe"
        }
    }

    /// The absolute path to the staged executable for this version/platform. Pure
    /// — composes `stagedRootDir()` with `executableRelativePath()`.
    public func stagedExecutablePath() -> String {
        URL(fileURLWithPath: stagedRootDir())
            .appendingPathComponent(executableRelativePath())
            .path
    }

    // MARK: Resolution (effectful, but every effect is injected)

    /// Resolves a launchable browser executable path, downloading on demand.
    ///
    /// Order: explicit `browserPath` → cached staged download →
    /// `ChromeLauncher.defaultExecutablePath` (system Chrome) → fresh download.
    public func resolveExecutablePath() async throws -> String {
        // 1. Explicit config path wins when it points at a real executable.
        if let browserPath, executableExists(browserPath) {
            return browserPath
        }
        // 2. A previously-staged download for this exact version/platform.
        let staged = stagedExecutablePath()
        if executableExists(staged) {
            return staged
        }
        // 3. A system Chrome install (e.g. macOS `/Applications/...`).
        if executableExists(systemDefaultPath) {
            return systemDefaultPath
        }
        // 4. Fetch + extract + stage, then return the staged path.
        return try await provision()
    }

    /// Forces a download/extract/stage and returns the staged executable path.
    @discardableResult
    public func provision() async throws -> String {
        guard let url = URL(string: try downloadURL()) else {
            throw ChromiumProvisionerError.fetchFailed("invalid url \(try downloadURL())")
        }
        let payload: Data
        do {
            payload = try await download(url)
        } catch let error as ChromiumProvisionerError {
            throw error
        } catch {
            throw ChromiumProvisionerError.fetchFailed("\(url.absoluteString): \(error)")
        }
        try stageArchive(payload)
        let staged = stagedExecutablePath()
        guard executableExists(staged) else {
            throw ChromiumProvisionerError.executableNotFoundAfterExtract(staged)
        }
        return staged
    }

    /// Writes the archive to a temp file, extracts it into the staged root, and
    /// cleans the temp file up. Chrome-for-Testing ships `.zip` for all OSes.
    func stageArchive(_ payload: Data) throws {
        let root = stagedRootDir()
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let parent = URL(fileURLWithPath: root).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let archivePath = URL(fileURLWithPath: parent)
            .appendingPathComponent(".tmp-chromium-\(pid)-\(stamp).zip").path
        try payload.write(to: URL(fileURLWithPath: archivePath))
        defer { try? FileManager.default.removeItem(atPath: archivePath) }
        // Fresh staging dir so a partial prior extract never shadows this one.
        try? FileManager.default.removeItem(atPath: root)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try extract(archivePath, root)
    }

    // MARK: Default effect implementations

    /// Default downloader: `URLSession.shared.data`, surfacing non-2xx as a
    /// fetch error.
    public static let defaultDownloader: Downloader = { @MainActor url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode < 200 || http.statusCode >= 300 {
            throw ChromiumProvisionerError.fetchFailed("fetch \(url.absoluteString) -> HTTP \(http.statusCode)")
        }
        return data
    }

    /// Default extractor: powershell `Expand-Archive` on Windows, `unzip -q -o`
    /// elsewhere.
    public static let defaultExtractor: Extractor = { archivePath, dir in
        #if os(Windows)
        let result = try runChromiumHelperProcess(
            executable: "powershell",
            arguments: ["-NoProfile", "-Command", "Expand-Archive -LiteralPath '\(archivePath)' -DestinationPath '\(dir)' -Force"])
        #else
        let result = try runChromiumHelperProcess(
            executable: "/usr/bin/env",
            arguments: ["unzip", "-q", "-o", archivePath, "-d", dir])
        #endif
        if result != 0 {
            throw ChromiumProvisionerError.archiveExtractionFailed("zip extraction failed (\(result))")
        }
    }

    /// Default executable probe: `FileManager.isExecutableFile`.
    public static let defaultExecutableProbe: ExecutableProbe = { path in
        FileManager.default.isExecutableFile(atPath: path)
    }
}

// MARK: - Process helper

/// Runs a child process to completion and returns its exit code. Used only by
/// the default archive extractor. Kept private to this file so the provisioner's
/// effects stay injectable and the helper never leaks.
@discardableResult
private nonisolated func runChromiumHelperProcess(executable: String, arguments: [String]) throws -> Int32 {
    #if os(macOS) || os(Linux) || os(Windows)
    let process = Process()
    if executable.hasPrefix("/") {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    }
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus
    #else
    throw ChromiumProvisionerError.archiveExtractionFailed("child processes are unavailable on this platform")
    #endif
}
