import Testing
import Foundation
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
    #expect(try resolveChromiumPlatformKey("win32", "x64") == .windowsX64)
}

@Test func rejectsUnsupportedPlatform() {
    #expect(throws: UnsupportedChromiumPlatformError.self) {
        _ = try resolveChromiumPlatformKey("solaris", "sparc")
    }
}

@Test func resolvesDownloadURLForMacArm64() throws {
    let p = try ChromiumProvisioner(platformKey: .macArm64)
    #expect(try p.downloadURL() == "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/mac-arm64/chrome-mac-arm64.zip")
}

@Test func resolvesDownloadURLForMacX64() throws {
    let p = try ChromiumProvisioner(platformKey: .macX64)
    #expect(try p.downloadURL() == "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/mac-x64/chrome-mac-x64.zip")
}

@Test func resolvesDownloadURLForLinuxX64() throws {
    let p = try ChromiumProvisioner(platformKey: .linuxX64)
    #expect(try p.downloadURL() == "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/linux64/chrome-linux64.zip")
}

@Test func resolvesDownloadURLForWindowsX64() throws {
    let p = try ChromiumProvisioner(platformKey: .windowsX64)
    #expect(try p.downloadURL() == "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/win64/chrome-win64.zip")
}

// MARK: - (d) Extract / staged-path computation

@Test func computesStagedExecutablePathPerPlatform() throws {
    let root = "/cache"

    let mac = try ChromiumProvisioner(cacheRoot: root, platformKey: .macArm64)
    #expect(mac.stagedRootDir() == "/cache/126.0.6478.126/mac-arm64")
    #expect(mac.stagedExecutablePath()
        == "/cache/126.0.6478.126/mac-arm64/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")

    let linux = try ChromiumProvisioner(cacheRoot: root, platformKey: .linuxX64)
    #expect(linux.stagedExecutablePath() == "/cache/126.0.6478.126/linux64/chrome-linux64/chrome")

    let win = try ChromiumProvisioner(cacheRoot: root, platformKey: .windowsX64)
    #expect(win.stagedExecutablePath() == "/cache/126.0.6478.126/win64/chrome-win64/chrome.exe")
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
    probe.add(p.stagedExecutablePath())

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
    probe.add(p.stagedExecutablePath())
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
        systemDefaultPath: "/nope/google-chrome",
        download: downloader.make(),
        extract: extractor.make(),
        executableExists: probe.make())
    expectedExecutable = p.stagedExecutablePath()

    let resolved = try await p.resolveExecutablePath()
    #expect(resolved == p.stagedExecutablePath())
    #expect(downloader.callCount == 1)
    #expect(downloader.lastURL?.absoluteString
        == "https://storage.googleapis.com/chrome-for-testing-public/126.0.6478.126/linux64/chrome-linux64.zip")
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
        systemDefaultPath: "/nope",
        download: downloader.make(),
        extract: extractor.make(),
        executableExists: probe.make())

    await #expect(throws: ChromiumProvisionerError.self) {
        _ = try await p.resolveExecutablePath()
    }
}

@Test func buildTableHasURLForEveryPlatform() throws {
    for key in ChromiumPlatformKey.allCases {
        #expect((try? ChromiumBuildTable.pinned.url(for: key)) != nil)
    }
}

}
