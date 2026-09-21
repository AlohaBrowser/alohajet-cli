import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

// MARK: - Upload staging

/// The ceiling on one upload's total bytes, summed across every file in the call.
///
/// It bounds MEMORY, not disk: every staged file is also base64-encoded and spliced into a
/// JavaScript source string for the in-page `DataTransfer` fallback, which is ~1.33x the
/// file's own size and has to be handed to the page and parsed in one piece. A cap on the
/// read alone would let a file the browser cannot swallow through.
public let maxUploadTotalBytes = 50 * 1024 * 1024

/// One file, staged both ways at once.
public nonisolated struct StagedUploadFile: Equatable, Sendable {
    /// The basename the page sees as `File.name`.
    public var name: String
    /// What the page sees as `File.type`.
    public var mime: String
    /// The file's bytes, base64-encoded, for the in-page `DataTransfer` fallback.
    public var base64: String

    public init(name: String, mime: String, base64: String) {
        self.name = name
        self.mime = mime
        self.base64 = base64
    }
}

/// The two forms an upload is attached in.
public nonisolated struct StagedUpload: Equatable, Sendable {
    /// Paths for `DOM.setFileInputFiles`, which the BROWSER process opens itself.
    public var cdpPaths: [String]
    /// The same files' bytes, for the page-side fallback.
    public var files: [StagedUploadFile]

    public init(cdpPaths: [String], files: [StagedUploadFile]) {
        self.cdpPaths = cdpPaths
        self.files = files
    }
}

/// A staging failure with a message meant for whoever asked for the upload.
public nonisolated struct UploadStagingError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Turns caller-named file paths into something CDP can attach.
///
/// The one thing the upload path needs from a host — and it needs BOTH halves of the
/// answer, because neither reaches every page. `cdpPaths` is what `DOM.setFileInputFiles`
/// takes, and the browser process is what opens those paths, so they only work when the
/// browser can see that filesystem. `files` carries the bytes inline for the page-side
/// `DataTransfer` fallback, which is all that is left when the CDP node cannot be resolved
/// (a dropzone with no `<input>`) or the browser cannot read the path.
///
/// An implementation must refuse an upload whose bytes total more than `maxTotalBytes`;
/// see ``maxUploadTotalBytes`` for why the ceiling is not the caller's business.
public protocol UploadStaging: Sendable {
    func stage(_ paths: [String], maxTotalBytes: Int, signal: AbortSignal?) async throws -> StagedUpload
}

/// Reads the files where they already are: no copy, no staging directory.
///
/// `cdpPaths` is the caller's own path list, unchanged, because `DOM.setFileInputFiles`
/// can attach it as-is whenever the browser runs on this filesystem — the CLI's case, and
/// the only one this package ships a browser for. A host whose browser sees a different
/// filesystem (a sandbox, a container, a remote target) implements ``UploadStaging``
/// itself and copies the bytes to where that browser can reach them.
public struct LocalFileUploadStaging: UploadStaging {
    public init() {}

    public func stage(_ paths: [String], maxTotalBytes: Int, signal: AbortSignal?) async throws -> StagedUpload {
        try throwIfUploadAborted(signal)
        if paths.isEmpty { return StagedUpload(cdpPaths: [], files: []) }

        // SIZED FIRST, from the directory entries, so an oversized upload is refused without
        // reading a byte of it. Checking the cap against bytes already in memory is the one
        // thing the cap exists to prevent, and it is also the only way to name the real total
        // in the refusal rather than "the first N files were already too much".
        var totalBytes = 0
        for path in paths {
            try throwIfUploadAborted(signal)
            // One `stat`, which answers all three questions — exists, is a file, how big —
            // and FOLLOWS the symlink. Following matters: the size of a symlink itself is
            // the length of the link text, so an upload pointed at one would otherwise be
            // measured at ~20 bytes whatever it points to. `attributesOfItem` would also
            // mean reading the size back out of an `Any` as `NSNumber`, which bridges on
            // Darwin and does not off it. A stat that fails is a REFUSAL and never a zero:
            // silently contributing nothing is the one thing the cap exists to prevent.
            var info = stat()
            guard stat(path, &info) == 0 else {
                throw UploadStagingError("File upload cannot find \"\(path)\".")
            }
            guard info.st_mode & S_IFMT != S_IFDIR else {
                throw UploadStagingError("File upload expected a file but got a directory: \"\(path)\".")
            }
            totalBytes += Int(info.st_size)
        }
        if totalBytes > maxTotalBytes {
            throw UploadStagingError(
                "Upload files total \(String(format: "%.1f", Double(totalBytes) / 1024 / 1024))MB, "
                + "over the \(maxTotalBytes / 1024 / 1024)MB limit.")
        }

        var files: [StagedUploadFile] = []
        for path in paths {
            try throwIfUploadAborted(signal)
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw UploadStagingError("File upload could not read \"\(path)\": \(error.localizedDescription)")
            }
            let name = (path as NSString).lastPathComponent
            files.append(StagedUploadFile(
                name: name, mime: uploadMimeType(name), base64: data.base64EncodedString()))
        }
        return StagedUpload(cdpPaths: paths, files: files)
    }
}

private func throwIfUploadAborted(_ signal: AbortSignal?) throws {
    if signal?.aborted == true { throw AbortSignalError("Operation aborted") }
}

/// The `File.type` the page is given, from the name's extension.
///
/// A table and not `UTType`, which is Apple-only. It exists at all because upload fields
/// gate on `file.type`: an `accept="image/*"` picker handed `application/octet-stream`
/// rejects the file in the page, before anything is sent, and the tool reports a success
/// the site never saw. The entries are the types an upload field actually asks for.
func uploadMimeType(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "svg": return "image/svg+xml"
    case "heic": return "image/heic"
    case "bmp": return "image/bmp"
    case "pdf": return "application/pdf"
    case "txt", "log": return "text/plain"
    case "md": return "text/markdown"
    case "csv": return "text/csv"
    case "json": return "application/json"
    case "xml": return "application/xml"
    case "html", "htm": return "text/html"
    case "zip": return "application/zip"
    case "mp4": return "video/mp4"
    case "webm": return "video/webm"
    case "mp3": return "audio/mpeg"
    case "wav": return "audio/wav"
    case "doc": return "application/msword"
    case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "xls": return "application/vnd.ms-excel"
    case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    default: return "application/octet-stream"
    }
}
