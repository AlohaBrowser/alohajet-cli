import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// `UploadStaging` is the upload path's ONE host seam: paths in, the two attachable forms
// out. `LocalFileUploadStaging` is the implementation this package ships — the CLI drives a
// browser on this machine, so the paths it is handed are paths that browser can open — and
// the cases below are its whole contract: what comes back, and what is refused before a
// byte reaches the page.

@Suite("upload staging (local filesystem)")
@MainActor
struct LocalFileUploadStagingTests {

    /// A directory no test shares. Not cleaned up: it lives under the temp directory, the
    /// files are a few bytes, and a `defer` that outlives an `async` body is a trap.
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func write(_ bytes: Int, named name: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url.path
    }

    // MARK: What comes back

    /// BOTH forms, from one read. `cdpPaths` is what `DOM.setFileInputFiles` attaches and
    /// `files` is what the in-page `DataTransfer` fallback needs; a staging that answered
    /// only one of them would leave half the pages in the world unuploadable.
    @Test func stagesTheCdpPathsAndTheInlineBytesTogether() async throws {
        let directory = try scratchDirectory()
        let path = try write(3, named: "note.txt", in: directory)

        let staged = try await LocalFileUploadStaging().stage([path], maxTotalBytes: maxUploadTotalBytes, signal: nil)

        #expect(staged.cdpPaths == [path])
        #expect(staged.files.count == 1)
        #expect(staged.files[0].name == "note.txt")
        #expect(staged.files[0].mime == "text/plain")
        #expect(Data(base64Encoded: staged.files[0].base64) == Data(repeating: 0x41, count: 3))
    }

    /// The paths come back UNCHANGED — no copy, no staging directory. That is the whole
    /// reason this implementation is three dozen lines: the browser is on this filesystem.
    @Test func pathsAreNotRewritten() async throws {
        let directory = try scratchDirectory()
        let first = try write(1, named: "a.png", in: directory)
        let second = try write(1, named: "b.png", in: directory)

        let staged = try await LocalFileUploadStaging().stage([first, second], maxTotalBytes: maxUploadTotalBytes, signal: nil)

        #expect(staged.cdpPaths == [first, second])
        #expect(staged.files.map(\.name) == ["a.png", "b.png"])
    }

    /// `File.type` decides whether an `accept="image/*"` field takes the file at all, so a
    /// name the table does not know falls back to the generic type rather than to nothing.
    @Test("mime comes from the extension", arguments: [
        ("photo.PNG", "image/png"), ("scan.jpeg", "image/jpeg"), ("report.pdf", "application/pdf"),
        ("rows.csv", "text/csv"), ("archive.tar.gz", "application/octet-stream"), ("noextension", "application/octet-stream"),
    ])
    func mimeFromExtension(_ name: String, _ expected: String) async throws {
        let directory = try scratchDirectory()
        let path = try write(1, named: name, in: directory)

        let staged = try await LocalFileUploadStaging().stage([path], maxTotalBytes: maxUploadTotalBytes, signal: nil)

        #expect(staged.files[0].mime == expected)
    }

    @Test func noPathsStagesNothing() async throws {
        let staged = try await LocalFileUploadStaging().stage([], maxTotalBytes: maxUploadTotalBytes, signal: nil)
        #expect(staged == StagedUpload(cdpPaths: [], files: []))
    }

    // MARK: The byte cap

    @Test func theCapIs50MB() {
        #expect(maxUploadTotalBytes == 50 * 1024 * 1024)
    }

    /// The cap is a TOTAL, not a per-file limit: two files each comfortably under it are
    /// still refused together, because the base64 of both is what the page has to parse.
    @Test func theCapSumsAcrossFiles() async throws {
        let directory = try scratchDirectory()
        let first = try write(600, named: "a.bin", in: directory)
        let second = try write(600, named: "b.bin", in: directory)

        do {
            _ = try await LocalFileUploadStaging().stage([first, second], maxTotalBytes: 1_000, signal: nil)
            Issue.record("1200 bytes staged under a 1000-byte cap")
        } catch let error as UploadStagingError {
            #expect(error.message.contains("limit"))
        }
    }

    /// THE SYMLINK CASE, which is why the size is read from the RESOLVED path: a symlink's
    /// own size is the length of the link text, so an unresolved measurement puts a
    /// gigabyte behind a 20-byte directory entry and waves it through the cap.
    @Test func aSymlinkIsMeasuredAtItsTarget() async throws {
        let directory = try scratchDirectory()
        let target = try write(4096, named: "big.bin", in: directory)
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)

        do {
            _ = try await LocalFileUploadStaging().stage([link.path], maxTotalBytes: 1_024, signal: nil)
            Issue.record("a 4096-byte file staged through a symlink under a 1024-byte cap")
        } catch let error as UploadStagingError {
            #expect(error.message.contains("limit"))
        }
    }

    // MARK: Refusals

    @Test func aMissingFileIsNamed() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-absent-\(UUID().uuidString).png").path
        do {
            _ = try await LocalFileUploadStaging().stage([missing], maxTotalBytes: maxUploadTotalBytes, signal: nil)
            Issue.record("a path that does not exist staged anyway")
        } catch let error as UploadStagingError {
            #expect(error.message.contains(missing))
            #expect(error.message.contains("cannot find"))
        }
    }

    /// Negative/edge case: a directory exists and is readable, so only an explicit check
    /// stops it — and `DOM.setFileInputFiles` handed one fails far from here.
    @Test func aDirectoryIsRefused() async throws {
        let directory = try scratchDirectory()
        do {
            _ = try await LocalFileUploadStaging().stage([directory.path], maxTotalBytes: maxUploadTotalBytes, signal: nil)
            Issue.record("a directory staged as a file")
        } catch let error as UploadStagingError {
            #expect(error.message.contains("directory"))
        }
    }

    /// An already-aborted turn reads nothing. The error is the package's own
    /// ``AbortSignalError`` so the driver's `isAbortError` rethrows it instead of turning
    /// a cancellation into a failed upload.
    @Test func anAbortedSignalReadsNothing() async throws {
        let directory = try scratchDirectory()
        let path = try write(8, named: "a.bin", in: directory)
        let signal = AbortSignal()
        signal.abort("stopped")

        await #expect(throws: AbortSignalError.self) {
            _ = try await LocalFileUploadStaging().stage([path], maxTotalBytes: maxUploadTotalBytes, signal: signal)
        }
    }
}

// MARK: - page_upload

@Suite("page_upload argument reading (pure)")
struct PageUploadPathsTests {
    @Test func readsTheStringArrayInOrder() {
        #expect(PageUploadExecutorTool.paths(.object([
            "paths": .array([.string("/a.png"), .string("/b.png")])
        ])) == ["/a.png", "/b.png"])
    }

    /// Negative/edge case: an empty string is not a path, and a number is not one either.
    /// Both are dropped here rather than sent on to fail at the read with a worse message.
    @Test func dropsEmptyAndNonStringEntries() {
        #expect(PageUploadExecutorTool.paths(.object([
            "paths": .array([.string(""), .number(7), .string("/a.png"), .null])
        ])) == ["/a.png"])
    }

    @Test func missingOrWrongShapeReadsAsNoPaths() {
        #expect(PageUploadExecutorTool.paths(.object(["aloha_id": .string("x")])) == [])
        #expect(PageUploadExecutorTool.paths(.object(["paths": .string("/a.png")])) == [])
        #expect(PageUploadExecutorTool.paths(nil) == [])
    }
}

@Suite("page_upload executor")
@MainActor
struct PageUploadExecutorToolTests {
    @Test func requiresAlohaId() async throws {
        let result = try await PageUploadExecutorTool().execute(
            .object(["paths": .array([.string("/a.png")])]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("aloha_id"))
    }

    /// Both refusals land BEFORE any tab resolution (no tabs service is wired here at
    /// all), so a malformed call never costs a wake.
    @Test func requiresAtLeastOnePath() async throws {
        let result = try await PageUploadExecutorTool().execute(
            .object(["aloha_id": .string("f1"), "paths": .array([])]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("paths"))
    }

    @Test func noActiveTabFailsClearly() async throws {
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([]))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await PageUploadExecutorTool().execute(
            .object(["aloha_id": .string("f1"), "paths": .array([.string("/a.png")])]),
            makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("no active browser tab"))
    }

    @Test func nonInteractiveTabIsRejected() async throws {
        let stubTab = PageToolsStubTabHandle(id: "t1", url: "https://a.example")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "t1"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await PageUploadExecutorTool().execute(
            .object(["aloha_id": .string("f1"), "paths": .array([.string("/a.png")])]),
            makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("not an interactive website tab"))
    }

    /// The ninth tool has to be advertised or it does not exist: the roster, the schema
    /// table and the read-only hints are three separate hand-written lists.
    @Test func isAdvertisedAsTheNinthTool() {
        #expect(nativeAgentToolNames.count == 9)
        #expect(nativeAgentToolNames.contains("page_upload"))
        #expect(getNativeAgentTools().contains { $0.name == "page_upload" })
        #expect(getNativeAgentToolSchema("page_upload")?.inputSchema?.array("required")?.compactMap(\.stringValue)
            == ["aloha_id", "paths"])
        #expect(nativeAgentToolReadOnlyHints["page_upload"] == false)
    }
}
