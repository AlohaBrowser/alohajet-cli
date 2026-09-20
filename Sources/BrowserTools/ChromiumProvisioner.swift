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
    switch (platform, arch) {
    case ("darwin", "arm64"): return .macArm64
    case ("darwin", "x64"): return .macX64
    case ("linux", "x64"): return .linuxX64
    case ("win32", "x64"): return .windowsX64
    default: throw UnsupportedChromiumPlatformError(platform: platform, arch: arch)
    }
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
    /// URL and digest for one platform, in one value: a URL cannot be bumped and leave a
    /// stale digest behind, because there is nowhere for the two to disagree.
    public struct Build: Sendable, Equatable {
        public let url: String
        public let sha256: String

        public init(url: String, sha256: String) {
            self.url = url
            self.sha256 = sha256
        }
    }

    public let version: String
    public let builds: [ChromiumPlatformKey: Build]

    public init(version: String, builds: [ChromiumPlatformKey: Build]) {
        self.version = version
        self.builds = builds
    }

    // The digests were computed from the published archives themselves. Google serves no
    // SHA-256 for these: `x-goog-hash` carries a CRC32C and a base64 MD5, and neither is
    // an integrity story for a 145 MB executable this package then runs. Recompute and
    // replace all four whenever `version` moves.
    public static let pinned = ChromiumBuildTable(
        version: "153.0.8010.52",
        builds: [
            .macArm64: Build(
                url: "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/mac-arm64/chrome-mac-arm64.zip",
                sha256: "6f67faa4b34dd551b53abb6fee24edeae470ab695b0b100ddc4885ff0be6724a"),
            .macX64: Build(
                url: "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/mac-x64/chrome-mac-x64.zip",
                sha256: "01130a136cb492ff32a7253b2b8db9577bd3f7543574e2d7ce1a83ed1cbed3fd"),
            .linuxX64: Build(
                url: "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/linux64/chrome-linux64.zip",
                sha256: "e66f66d4802a46d4a022667e668aa950e277cadbfbed4b3777915b47413a0ef9"),
            .windowsX64: Build(
                url: "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/win64/chrome-win64.zip",
                sha256: "df4854428c509fcf2f790ac448bca3f994151bcff22008236fa7c4587294fbe1"),
        ]
    )

    public func build(for key: ChromiumPlatformKey) throws -> Build {
        guard let build = builds[key] else {
            throw ChromiumProvisionerError.noDownloadForPlatform(key.rawValue)
        }
        return build
    }

    public func url(for key: ChromiumPlatformKey) throws -> String {
        try build(for: key).url
    }
}

public enum ChromiumProvisionerError: Error, Equatable, Sendable, CustomStringConvertible {
    case noDownloadForPlatform(String)
    case fetchFailed(String)
    case archiveExtractionFailed(String)
    case executableNotFoundAfterExtract(String)
    case browserPathNotExecutable(String)
    case archiveDigestMismatch(platform: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case let .noDownloadForPlatform(key):
            "no Chrome-for-Testing download for platform \(key)"
        case let .fetchFailed(detail):
            "Chrome-for-Testing fetch failed: \(detail)"
        case let .archiveDigestMismatch(platform, expected, actual):
            "Chrome-for-Testing archive for \(platform) failed its SHA-256 check: "
                + "expected \(expected), got \(actual)"
        case let .archiveExtractionFailed(detail):
            "Chrome-for-Testing archive extraction failed: \(detail)"
        case let .executableNotFoundAfterExtract(path):
            "Chrome-for-Testing executable not found after extract at \(path)"
        case let .browserPathNotExecutable(path):
            "ALOHAJET_BROWSER names \(path), which is not an executable file"
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
            "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        case .macX64:
            "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        case .linuxX64:
            "chrome-linux64/chrome"
        case .windowsX64:
            "chrome-win64/chrome.exe"
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
        let build = try buildTable.build(for: platformKey)
        guard let url = URL(string: build.url) else {
            throw ChromiumProvisionerError.fetchFailed("invalid url \(build.url)")
        }
        let payload: Data
        do {
            payload = try await download(url)
        } catch let error as ChromiumProvisionerError {
            throw error
        } catch {
            throw ChromiumProvisionerError.fetchFailed("\(url.absoluteString): \(error)")
        }
        // Before the archive reaches the filesystem, and long before anything inside it is
        // run: TLS says the bytes came from Google's bucket, not that they are the bytes
        // this release was pinned to.
        let actual = sha256Hex(payload)
        guard actual == build.sha256 else {
            throw ChromiumProvisionerError.archiveDigestMismatch(
                platform: platformKey.rawValue, expected: build.sha256, actual: actual)
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
        let root = URL(fileURLWithPath: stagedRootDir())
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let parent = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let archive = parent.appendingPathComponent(".tmp-chromium-\(pid)-\(stamp).zip")
        try payload.write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        // Fresh staging dir so a partial prior extract never shadows this one.
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try extract(archive.path, root.path)
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
        // Absolute, not `env unzip`: this is the step that turns downloaded bytes into
        // the browser that gets launched, and the rest of that path (pinned URL, in-source
        // digest checked before the bytes touch disk) does not consult PATH either.
        let unzip = ["/usr/bin/unzip", "/bin/unzip"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let unzip else {
            throw ChromiumProvisionerError.archiveExtractionFailed("no unzip at /usr/bin/unzip or /bin/unzip")
        }
        let result = try runChromiumHelperProcess(
            executable: unzip,
            arguments: ["-q", "-o", archivePath, "-d", dir])
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

// SHA-256, in-package rather than from swift-crypto: `BrowserTools` is one of the four
// library products this package promises a consumer links with no dependencies of their
// own, and one digest is not worth spending that. CryptoKit would cover Apple only, and
// the Linux release build needs the same answer from the same code.
private nonisolated let sha256RoundConstants: [UInt32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

@inline(__always)
private nonisolated func rotr32(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x >> n) | (x << (32 - n))
}

nonisolated func sha256Hex(_ data: Data) -> String {
    var h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    var message = [UInt8](data)
    let bitCount = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
        message.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
    }

    var w = [UInt32](repeating: 0, count: 64)
    var offset = 0
    while offset < message.count {
        for i in 0..<16 {
            let j = offset + i * 4
            w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16
                | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d) = (h[0], h[1], h[2], h[3])
        var (e, f, g, hh) = (h[4], h[5], h[6], h[7])
        for i in 0..<64 {
            let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ sha256RoundConstants[i] &+ w[i]
            let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            (hh, g, f, e) = (g, f, e, d &+ t1)
            (d, c, b, a) = (c, b, a, t1 &+ t2)
        }
        for (i, value) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ value }
        offset += 64
    }
    return h.map { String(format: "%08x", $0) }.joined()
}
