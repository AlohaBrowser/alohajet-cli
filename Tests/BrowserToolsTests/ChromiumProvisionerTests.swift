import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BrowserTools

// Unit tests for `ChromiumProvisioner`. Every test injects a FAKE downloader and
// FAKE extractor/probe so NO real network or system browser is ever touched.

// MARK: - Test doubles

/// A downloader whose payload is scripted and whose invocations are counted, so
/// "did we hit the network?" can be asserted precisely.
private final class CountingDownloader {
    private var _calls: [URL] = []
    private let payload: Data

    init(payload: Data = Data("FAKE-ZIP".utf8)) {
        self.payload = payload
    }

    var callCount: Int { _calls.count }
    var lastURL: URL? { _calls.last }

    func make() -> ChromiumProvisioner.Downloader {
        return { [self] url in
            _calls.append(url)
            return payload
        }
    }
}

/// An extractor that records the (archive, dir) pairs it was asked to extract and
/// optionally "materializes" the executable by touching a file, so the staged
/// executable probe can pass without a real unzip.
private final class RecordingExtractor {
    private(set) var calls: [(archive: String, dir: String)] = []
    private let materialize: @MainActor (String) -> Void

    init(materialize: @escaping @MainActor (String) -> Void = { _ in }) {
        self.materialize = materialize
    }

    func make() -> ChromiumProvisioner.Extractor {
        return { [self] archive, dir in
            calls.append((archive, dir))
            materialize(dir)
        }
    }
}

/// A probe whose "this path is executable" answer is scripted by an explicit set.
private final class ScriptedProbe {
    private var present: Set<String> = []

    func add(_ path: String) { _ = present.insert(path) }

    func make() -> ChromiumProvisioner.ExecutableProbe {
        return { [self] path in
            present.contains(path)
        }
    }
}

/// The pinned table with every digest replaced by the fake payload's, so the
/// fetch → verify → extract → stage path runs end to end without a 145 MB download.
private func tableMatching(_ payload: Data) -> ChromiumBuildTable {
    ChromiumBuildTable(
        version: ChromiumBuildTable.pinned.version,
        builds: ChromiumBuildTable.pinned.builds.mapValues {
            .init(url: $0.url, sha256: sha256Hex(payload))
        })
}

private func tempCacheRoot() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("chromium-prov-tests-\(UUID().uuidString)")
        .path
}

// MARK: - Suite

// Grouped under a suite whose name contains "ChromiumProvisioner" so the
// acceptance filter `--filter ChromiumProvisioner` selects
// every case (Swift Testing's --filter matches the test's qualified name).
@Suite("ChromiumProvisioner")
struct ChromiumProvisionerTests {

// MARK: - (a) Per-OS/arch URL resolution

@Test func resolvesPlatformKeyForEachTarget() throws {
    #expect(try resolveChromiumPlatformKey("darwin", "arm64") == .macArm64)
    #expect(try resolveChromiumPlatformKey("darwin", "x64") == .macX64)
    #expect(try resolveChromiumPlatformKey("linux", "x64") == .linuxX64)
    #expect(try resolveChromiumPlatformKey("linux", "arm64") == .linuxArm64)
    #expect(try resolveChromiumPlatformKey("win32", "x64") == .windowsX64)
}

@Test func rejectsUnsupportedPlatform() {
    #expect(throws: UnsupportedChromiumPlatformError.self) {
        _ = try resolveChromiumPlatformKey("solaris", "sparc")
    }
    // Google publishes no Chrome for Testing for Windows on ARM.
    #expect(throws: UnsupportedChromiumPlatformError(platform: "win32", arch: "arm64")) {
        _ = try resolveChromiumPlatformKey("win32", "arm64")
    }
}

@Test func resolvesDownloadURLForMacArm64() throws {
    let p = try ChromiumProvisioner(platformKey: .macArm64)
    #expect(try p.downloadURL() == "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/mac-arm64/chrome-mac-arm64.zip")
}

@Test func resolvesDownloadURLForMacX64() throws {
    let p = try ChromiumProvisioner(platformKey: .macX64)
    #expect(try p.downloadURL() == "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/mac-x64/chrome-mac-x64.zip")
}

@Test func resolvesDownloadURLForLinuxX64() throws {
    let p = try ChromiumProvisioner(platformKey: .linuxX64)
    #expect(try p.downloadURL() == "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/linux64/chrome-linux64.zip")
}

@Test func resolvesDownloadURLForLinuxArm64() throws {
    let p = try ChromiumProvisioner(platformKey: .linuxArm64)
    #expect(try p.downloadURL() == "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/linux-arm64/chrome-linux-arm64.zip")
}

@Test func resolvesDownloadURLForWindowsX64() throws {
    let p = try ChromiumProvisioner(platformKey: .windowsX64)
    #expect(try p.downloadURL() == "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/win64/chrome-win64.zip")
}

// MARK: - Where the download goes, and through what

/// The download keeps nothing on disk but the staged archive: `.shared`, in the bare `alohajet`
/// executable, keeps its cache and HTTP storage in `~/Library/Caches/alohajet` and
/// `HTTPStorages/alohajet`, one pair for every app's copy of the CLI.
@Test func theDownloadSessionPersistsNothing() {
    let configuration = ChromiumProvisioner.downloadSession.configuration
    #expect((configuration.urlCache?.diskCapacity ?? 0) == 0)
    #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    #expect(configuration.urlCredentialStorage !== URLCredentialStorage.shared)
}

/// The CLI of an app with an identity of its own stages under that app's directory
/// (`AlohaJet-e2e`); the default, a shipped app's, is unchanged.
@Test func theCacheRootIsTheAppsOwnDirectory() {
    #expect(ChromiumProvisioner.defaultCacheRoot().hasSuffix("/AlohaJet/chrome-for-testing"))
    #expect(ChromiumProvisioner.defaultCacheRoot(appDirectory: "AlohaJet-e2e")
        .hasSuffix("/AlohaJet-e2e/chrome-for-testing"))
}

// MARK: - (d) Extract / staged-path computation

@Test func computesStagedExecutablePathPerPlatform() throws {
    let root = "/cache"

    let mac = try ChromiumProvisioner(cacheRoot: root, platformKey: .macArm64)
    #expect(mac.stagedRootDir() == "/cache/153.0.8010.52/mac-arm64")
    #expect(mac.stagedExecutablePath()
        == "/cache/153.0.8010.52/mac-arm64/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")

    let linux = try ChromiumProvisioner(cacheRoot: root, platformKey: .linuxX64)
    #expect(linux.stagedExecutablePath() == "/cache/153.0.8010.52/linux64/chrome-linux64/chrome")

    let linuxArm = try ChromiumProvisioner(cacheRoot: root, platformKey: .linuxArm64)
    #expect(linuxArm.stagedExecutablePath() == "/cache/153.0.8010.52/linux-arm64/chrome-linux-arm64/chrome")

    let win = try ChromiumProvisioner(cacheRoot: root, platformKey: .windowsX64)
    #expect(win.stagedExecutablePath() == "/cache/153.0.8010.52/win64/chrome-win64/chrome.exe")
}

// MARK: - (b) Explicit browserPath short-circuits download

@Test func explicitBrowserPathShortCircuitsDownload() async throws {
    let downloader = CountingDownloader()
    let extractor = RecordingExtractor()
    let probe = ScriptedProbe()
    let explicit = "/opt/my-chrome/chrome"
    probe.add(explicit)

    let p = try ChromiumProvisioner(
        browserPath: explicit,
        cacheRoot: "/cache",
        platformKey: .macArm64,
        systemDefaultPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        download: downloader.make(),
        extract: extractor.make(),
        executableExists: probe.make())

    let resolved = try await p.resolveExecutablePath()
    #expect(resolved == explicit)
    #expect(downloader.callCount == 0)
    #expect(extractor.calls.isEmpty)
}

// Naming a browser is a deliberate act and the browser's identity is load-bearing — a
// different profile, different extensions, a different user agent. Running another one
// instead makes every observation of the run a lie about which browser produced it.
@Test func explicitButMissingBrowserPathIsAnError() async throws {
    let downloader = CountingDownloader()
    let probe = ScriptedProbe()
    let system = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    // Explicit path NOT present; system path is.
    probe.add(system)

    #expect(throws: ChromiumProvisionerError.browserPathNotExecutable("/does/not/exist/chrome")) {
        _ = try ChromiumProvisioner(
            browserPath: "/does/not/exist/chrome",
            cacheRoot: "/cache",
            platformKey: .macArm64,
            systemDefaultPath: system,
            download: downloader.make(),
            extract: RecordingExtractor().make(),
            executableExists: probe.make())
    }
    #expect(downloader.callCount == 0)
    #expect(ChromiumProvisionerError.browserPathNotExecutable("/does/not/exist/chrome")
        .description.contains("ALOHAJET_BROWSER"))
}

/// An empty value is not a choice of browser, so it stays the same as naming none.
@Test func anEmptyBrowserPathIsNotAnError() async throws {
    let probe = ScriptedProbe()
    let system = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    probe.add(system)

    let p = try ChromiumProvisioner(
        browserPath: "",
        cacheRoot: "/cache",
        platformKey: .macArm64,
        systemDefaultPath: system,
        download: CountingDownloader().make(),
        extract: RecordingExtractor().make(),
        executableExists: probe.make())

    #expect(try await p.resolveExecutablePath() == system)
}

// MARK: - (c) Cached binary short-circuits download

@Test func cachedBinaryShortCircuitsDownload() async throws {
    let downloader = CountingDownloader()
    let extractor = RecordingExtractor()
    let probe = ScriptedProbe()

    let p = try ChromiumProvisioner(
        cacheRoot: "/cache",
        platformKey: .linuxX64,
        systemDefaultPath: "/usr/bin/google-chrome",
        download: downloader.make(),
        extract: extractor.make(),
        executableExists: probe.make())

    // Mark the staged binary as already present.
    probe.add(try #require(p.stagedExecutablePath()))

    let resolved = try await p.resolveExecutablePath()
    #expect(resolved == p.stagedExecutablePath())
    #expect(downloader.callCount == 0)
    #expect(extractor.calls.isEmpty)
}

@Test func cacheTakesPrecedenceOverSystemChrome() async throws {
    let downloader = CountingDownloader()
    let probe = ScriptedProbe()
    let system = "/usr/bin/google-chrome"

    let p = try ChromiumProvisioner(
        cacheRoot: "/cache",
        platformKey: .linuxX64,
        systemDefaultPath: system,
        download: downloader.make(),
        extract: RecordingExtractor().make(),
        executableExists: probe.make())

    // Both the cached staged binary AND the system Chrome are present; the cache
    // (step 2) must win over the system default (step 3).
    probe.add(try #require(p.stagedExecutablePath()))
    probe.add(system)

    let resolved = try await p.resolveExecutablePath()
    #expect(resolved == p.stagedExecutablePath())
    #expect(downloader.callCount == 0)
}

// MARK: - Download path (fetch → extract → stage), still no real network

@Test func triggersDownloadAndExtractWhenNothingCached() async throws {
    let cacheRoot = tempCacheRoot()
    defer { try? FileManager.default.removeItem(atPath: cacheRoot) }

    let downloader = CountingDownloader()
    let probe = ScriptedProbe()
    // The extractor "materializes" the staged executable so the post-extract
    // probe succeeds, exactly as a real unzip would lay down the binary.
    var expectedExecutable = ""
    let extractor = RecordingExtractor { _ in probe.add(expectedExecutable) }

    let p = try ChromiumProvisioner(
        cacheRoot: cacheRoot,
        platformKey: .linuxX64,
        buildTable: tableMatching(Data("FAKE-ZIP".utf8)),
        systemDefaultPath: "/nope/google-chrome",
        download: downloader.make(),
        extract: extractor.make(),
        executableExists: probe.make())
    expectedExecutable = try #require(p.stagedExecutablePath())

    let resolved = try await p.resolveExecutablePath()
    #expect(resolved == p.stagedExecutablePath())
    #expect(downloader.callCount == 1)
    #expect(downloader.lastURL?.absoluteString
        == "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/linux64/chrome-linux64.zip")
    #expect(extractor.calls.count == 1)
    // The archive must have been staged under (a child of) the cache root and
    // extracted into the staged root dir.
    #expect(extractor.calls.first?.dir == p.stagedRootDir())
    #expect(extractor.calls.first?.archive.hasSuffix(".zip") == true)
}

@Test func missingExecutableAfterExtractThrows() async throws {
    let cacheRoot = tempCacheRoot()
    defer { try? FileManager.default.removeItem(atPath: cacheRoot) }

    let downloader = CountingDownloader()
    let probe = ScriptedProbe()
    // Extractor does NOT materialize anything; the staged executable stays absent.
    let extractor = RecordingExtractor()

    let p = try ChromiumProvisioner(
        cacheRoot: cacheRoot,
        platformKey: .macX64,
        buildTable: tableMatching(Data("FAKE-ZIP".utf8)),
        systemDefaultPath: "/nope",
        download: downloader.make(),
        extract: extractor.make(),
        executableExists: probe.make())

    await #expect(throws: ChromiumProvisionerError.self) {
        _ = try await p.resolveExecutablePath()
    }
}

@Test func buildTableHasURLAndDigestForEveryPlatform() throws {
    for key in ChromiumPlatformKey.allCases {
        let build = try ChromiumBuildTable.pinned.build(for: key)
        #expect(build.url.hasPrefix("https://"))
        #expect(build.sha256.count == 64)
        #expect(build.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

// MARK: - Where Chrome-for-Testing publishes no build (Windows on ARM)

/// A table with no build for the platform is the provisioner's view of Windows on ARM: nothing
/// to cache, nothing to download.
private let noChromeForTesting = ChromiumBuildTable(version: ChromiumBuildTable.pinned.version, builds: [:])

@Test func anInstalledChromiumIsLookedUpInTheConventionalOrder() throws {
    var present: Set<String> = ["/env/chrome", "/usr/local/bin/chromium-browser", "/opt/bin/chromium-browser", "/usr/bin/google-chrome"]
    let path = "/usr/local/bin:relative:/usr/bin::/opt/bin"
    func lookup(_ environment: [String: String]) throws -> String? {
        try installedChromiumPath(environment: environment, isExecutable: { present.contains($0) })
    }
    // CHROME_PATH before anything on PATH.
    #expect(try lookup(["CHROME_PATH": "/env/chrome", "PATH": path]) == "/env/chrome")
    // Then by name, each across all of PATH: chromium-browser before google-chrome, and the
    // first PATH entry that has it.
    #expect(try lookup(["PATH": path]) == "/usr/local/bin/chromium-browser")
    // chromium on the LAST entry still beats chromium-browser on the first.
    present.insert("/opt/bin/chromium")
    #expect(try lookup(["PATH": path]) == "/opt/bin/chromium")
    // An empty CHROME_PATH is an unset one.
    #expect(try lookup(["CHROME_PATH": "", "PATH": path]) == "/opt/bin/chromium")
    // A relative PATH entry is never searched.
    present = ["relative/chromium"]
    #expect(try lookup(["PATH": path]) == nil)
    #expect(try lookup([:]) == nil)
}

/// The `ALOHAJET_BROWSER` rule: a named browser that is not there is an error, never a
/// fall-through to the chromium on PATH.
@Test func aChromePathThatIsNotExecutableIsAnError() {
    #expect(throws: ChromiumProvisionerError.chromePathNotExecutable("/typo/chrome")) {
        _ = try installedChromiumPath(
            environment: ["CHROME_PATH": "/typo/chrome", "PATH": "/usr/bin"],
            isExecutable: { $0 == "/usr/bin/chromium" })
    }
    #expect(ChromiumProvisionerError.chromePathNotExecutable("/typo/chrome").description
        == "CHROME_PATH names /typo/chrome, which is not an executable file")
}

@Test func withoutChromeForTestingTheInstalledChromiumRunsAndNothingIsDownloaded() async throws {
    let downloader = CountingDownloader()
    let probe = ScriptedProbe()
    probe.add("/usr/bin/chromium")
    func provisioner(browserPath: String? = nil) throws -> ChromiumProvisioner {
        try ChromiumProvisioner(
            browserPath: browserPath,
            cacheRoot: "/cache",
            platformKey: .linuxX64,
            buildTable: noChromeForTesting,
            systemDefaultPath: "/nope",
            environment: ["PATH": "/usr/local/bin:/usr/bin"],
            download: downloader.make(),
            extract: RecordingExtractor().make(),
            executableExists: probe.make())
    }
    #expect(try await provisioner().resolveExecutablePath() == "/usr/bin/chromium")
    // ALOHAJET_BROWSER still comes first.
    probe.add("/opt/mine/chrome")
    #expect(try await provisioner(browserPath: "/opt/mine/chrome").resolveExecutablePath() == "/opt/mine/chrome")
    #expect(downloader.callCount == 0)
}

@Test func withoutChromeForTestingOrAChromiumTheErrorSaysHowToNameOne() async throws {
    let downloader = CountingDownloader()
    let p = try ChromiumProvisioner(
        cacheRoot: "/cache",
        platformKey: .linuxX64,
        buildTable: noChromeForTesting,
        systemDefaultPath: "/nope",
        environment: ["PATH": "/usr/bin"],
        download: downloader.make(),
        extract: RecordingExtractor().make(),
        executableExists: ScriptedProbe().make())

    await #expect(throws: ChromiumProvisionerError.noChromiumForPlatform("linux64")) {
        _ = try await p.resolveExecutablePath()
    }
    #expect(downloader.callCount == 0)
    // What is unsupported, what was looked for, and the two ways to point it at a browser.
    #expect(ChromiumProvisionerError.noChromiumForPlatform("win32/arm64").description == """
        Chrome for Testing has no build for win32/arm64, so no browser can be downloaded here, \
        and no Chromium is installed: CHROME_PATH is unset and none of chromium, \
        chromium-browser, google-chrome is on PATH. Install Chromium, or set \
        ALOHAJET_BROWSER to the path of a Chromium or Chrome executable
        """)
}

/// Where Chrome for Testing publishes a build nothing changes: CHROME_PATH and PATH are not
/// consulted — a CHROME_PATH that names nothing would throw if they were.
@Test func whereChromeForTestingHasABuildTheInstalledLookupIsNotConsulted() async throws {
    let probe = ScriptedProbe()
    probe.add("/usr/bin/chromium")
    let p = try ChromiumProvisioner(
        cacheRoot: "/cache",
        platformKey: .linuxX64,
        systemDefaultPath: "/nope",
        environment: ["CHROME_PATH": "/typo/chrome", "PATH": "/usr/bin"],
        download: CountingDownloader().make(),
        extract: RecordingExtractor().make(),
        executableExists: probe.make())
    probe.add(try #require(p.stagedExecutablePath()))
    #expect(try await p.resolveExecutablePath() == p.stagedExecutablePath())
}

// MARK: - Archive integrity

@Test func sha256MatchesKnownVectors() {
    #expect(sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    // 1 000 000 × 'a' — the NIST long message, the one that exercises multi-block padding.
    #expect(sha256Hex(Data(repeating: UInt8(ascii: "a"), count: 1_000_000))
        == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}

/// A payload that does not hash to the pinned digest never reaches the filesystem: the
/// extractor is never called, so nothing is left unpacked to be run later.
@Test func wrongDigestIsRejectedBeforeAnythingIsStaged() async throws {
    let cacheRoot = tempCacheRoot()
    defer { try? FileManager.default.removeItem(atPath: cacheRoot) }

    let payload = Data("NOT-THE-PINNED-ARCHIVE".utf8)
    let expected = String(repeating: "0", count: 64)
    let extractor = RecordingExtractor()
    let table = ChromiumBuildTable(
        version: "153.0.8010.52",
        builds: [.linuxX64: .init(url: "https://example.invalid/chrome-linux64.zip", sha256: expected)])

    let p = try ChromiumProvisioner(
        cacheRoot: cacheRoot,
        platformKey: .linuxX64,
        buildTable: table,
        systemDefaultPath: "/nope",
        download: CountingDownloader(payload: payload).make(),
        extract: extractor.make(),
        executableExists: ScriptedProbe().make())

    await #expect(throws: ChromiumProvisionerError.archiveDigestMismatch(
        platform: "linux64", expected: expected, actual: sha256Hex(payload))) {
        _ = try await p.provision()
    }
    #expect(extractor.calls.isEmpty)
    #expect(FileManager.default.fileExists(atPath: cacheRoot) == false)
}

}
