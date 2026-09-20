// Sits ON TOP of this package's `ChromeLauncher`: `ChromeLauncher.defaultExecutablePath` is
// resolution step 3, and the path this returns is what
// `BrowserToolSession.launch(executablePath:)` takes.
//
import Foundation
import CDP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A cross-platform Chrome-for-Testing fetcher. The download URL comes from an in-repo
// table rather than an external browser-fetcher shell-out, which would add an unpinned
// download-tooling dependency on the target machine. The network, extraction and filesystem
// probes are injected as closures, so the URL-resolution and cache-path logic stays pure
// and unit-testable with no real network.

/// The platform/architecture combinations Chrome-for-Testing publishes a download for.
public enum ChromiumPlatformKey: String, CaseIterable, Sendable, Hashable, Codable {
    case macArm64 = "mac-arm64"
    case macX64 = "mac-x64"
    case linuxX64 = "linux64"
    case windowsX64 = "win64"

    public var isWindows: Bool { self == .windowsX64 }
}

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

/// `platform`/`arch` use the Node-style identifiers `darwin`/`win32`/`linux` and
/// `arm64`/`x64`.
public nonisolated func resolveChromiumPlatformKey(_ platform: String, _ arch: String) throws -> ChromiumPlatformKey {
    if platform == "darwin" && arch == "arm64" { return .macArm64 }
    if platform == "darwin" && arch == "x64" { return .macX64 }
    if platform == "linux" && arch == "x64" { return .linuxX64 }
    if platform == "win32" && arch == "x64" { return .windowsX64 }
    throw UnsupportedChromiumPlatformError(platform: platform, arch: arch)
}

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

/// NO `npx`/CDN discovery — the URLs are baked in so the target machine needs nothing but
/// network access to the published archive.
public nonisolated struct ChromiumBuildTable: Sendable, Equatable {
    public let version: String
    public let downloads: [ChromiumPlatformKey: String]

    public init(version: String, downloads: [ChromiumPlatformKey: String]) {
        self.version = version
        self.downloads = downloads
    }

    public static let pinned = ChromiumBuildTable(
        version: "126.0.6478.126",
        downloads: [
            .macArm64: "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/mac-arm64/chrome-mac-arm64.zip",
            .macX64: "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/mac-x64/chrome-mac-x64.zip",
            .linuxX64: "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/linux64/chrome-linux64.zip",
            .windowsX64: "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/win64/chrome-win64.zip",
        ]
    )

    public func url(for key: ChromiumPlatformKey) throws -> String {
        guard let url = downloads[key] else {
            throw ChromiumProvisionerError.noDownloadForPlatform(key.rawValue)
        }
        return url
    }
}

public enum ChromiumProvisionerError: Error, Equatable, Sendable, CustomStringConvertible {
    case noDownloadForPlatform(String)
    case fetchFailed(String)
    case archiveExtractionFailed(String)
    case executableNotFoundAfterExtract(String)
    case browserPathNotExecutable(String)

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
        case let .browserPathNotExecutable(path):
            return "ALOHAJET_BROWSER names \(path), which is not an executable file"
        }
    }
}

/// Downloads, extracts, and caches a Chrome-for-Testing build for the running platform.
///
/// Resolution order on `resolveExecutablePath()`:
///   1. explicit `browserPath` (from CLI config) — short-circuits everything, and one
///      that is not an executable file is refused by `init` rather than fallen through;
///   2. a previously-cached download under the Application-Support cache dir;
///   3. `ChromeLauncher.defaultExecutablePath` if a system Chrome is present;
///   4. trigger a download (fetch → extract → stage) and return the staged path.
@MainActor
public final class ChromiumProvisioner {
    /// Main-isolated, but it releases the actor at its internal `await`.
    public typealias Downloader = @MainActor @Sendable (URL) async throws -> Data
    public typealias Extractor = @MainActor @Sendable (_ archivePath: String, _ into: String) throws -> Void
    public typealias ExecutableProbe = @MainActor @Sendable (String) -> Bool

    public let browserPath: String?
    public let cacheRoot: String
    public let platformKey: ChromiumPlatformKey
    public let buildTable: ChromiumBuildTable
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
        // In `init`, which runs before the "downloading Chrome for Testing" announcement
        // and before any lane is opened: naming a browser is a deliberate act, and
        // quietly running a different one makes every observation of the run — the user
        // agent, the profile, the extensions — a lie about which browser produced it.
        if let browserPath, !browserPath.isEmpty, !executableExists(browserPath) {
            throw ChromiumProvisionerError.browserPathNotExecutable(browserPath)
        }
    }

    // MARK: Pure path / URL logic (no I/O)

    public static func defaultCacheRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AlohaJet").appendingPathComponent("chrome-for-testing").path
    }

    public func downloadURL() throws -> String {
        try buildTable.url(for: platformKey)
    }

    /// Keyed by version + platform so distinct builds never collide.
    public func stagedRootDir() -> String {
        URL(fileURLWithPath: cacheRoot)
            .appendingPathComponent(buildTable.version)
            .appendingPathComponent(platformKey.rawValue)
            .path
    }

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

    public func stagedExecutablePath() -> String {
        URL(fileURLWithPath: stagedRootDir())
            .appendingPathComponent(executableRelativePath())
            .path
    }

    // MARK: Resolution (effectful, but every effect is injected)

    /// Resolves a launchable browser executable path, downloading on demand.
    public func resolveExecutablePath() async throws -> String {
        if let browserPath, executableExists(browserPath) {
            return browserPath
        }
        let staged = stagedExecutablePath()
        if executableExists(staged) {
            return staged
        }
        if executableExists(systemDefaultPath) {
            return systemDefaultPath
        }
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

    /// Chrome-for-Testing ships `.zip` for all OSes.
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

    public static let defaultDownloader: Downloader = { @MainActor url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode < 200 || http.statusCode >= 300 {
            throw ChromiumProvisionerError.fetchFailed("fetch \(url.absoluteString) -> HTTP \(http.statusCode)")
        }
        return data
    }

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

    public static let defaultExecutableProbe: ExecutableProbe = { path in
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Private to this file so the provisioner's effects stay injectable and the helper never
/// leaks.
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
