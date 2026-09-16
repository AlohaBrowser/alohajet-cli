import Foundation
import ToolABI

/// The executable `page_upload` tool: attaches files from this machine's filesystem to a
/// file `<input>` on the active tab, by the element's `aloha_id`. It is the sanctioned
/// alternative to clicking a `[uploadable]` input — `page_click` refuses that outright,
/// because the native picker it opens is invisible to the agent and cannot be driven.
///
/// Unlike the other page tools this one does NOT go through `AgentBrowserBridge`. Attaching
/// files is `DOM.setFileInputFiles`, a host-side CDP command with no in-page equivalent, so
/// the tool reaches `AgentDOMService` directly off the tab handle. Success is that driver's
/// post-dispatch read-back of the input's real `FileList`, never a bare dispatch.
///
/// The bytes come from ``LocalFileUploadStaging``: this package launches or attaches to a
/// browser on this same machine, so the paths the caller names are paths the browser can
/// open. A host whose browser sees a different filesystem composes its own ``UploadStaging``
/// into the service instead — this tool is the local case, and nothing here knows about
/// any other.
@MainActor public final class PageUploadExecutorTool: ExecutorTool {
    public let name = "page_upload"

    public init() {}

    public func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult {
        guard let alohaId = PageToolInput.string(input, "aloha_id"), !alohaId.isEmpty else {
            return RawToolResult(
                output: "page_upload requires an \"aloha_id\" naming the [uploadable] file input to attach to.",
                isError: true)
        }
        let paths = Self.paths(input)
        guard !paths.isEmpty else {
            return RawToolResult(
                output: "page_upload requires a non-empty \"paths\" array of file paths to attach.",
                isError: true)
        }

        switch await resolveActivePageTab(name, context) {
        case let .failure(errorResult):
            return errorResult
        case let .success(resolved):
            guard let driver = resolved.cdpTab.interactiveDriver else {
                return RawToolResult(output: "page_upload failed: the active tab is not an interactive website tab.", isError: true)
            }
            let result = try await driver.uploadFilesById(alohaId, paths, context.signal, LocalFileUploadStaging())
            guard result.success else {
                return resolved.tab.naming(RawToolResult(output: result.error ?? "page_upload failed.", isError: true))
            }
            // The BASENAMES, not the paths given: this is a receipt of what the page now
            // holds, and `File.name` is the only part of a path the page ever sees.
            let attached = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return resolved.tab.naming(RawToolResult(
                output: "Attached \(paths.count == 1 ? "1 file" : "\(paths.count) files") to element \"\(alohaId)\": \(attached).",
                isError: nil))
        }
    }

    /// A plain string array, not the `[{path}]` object list a richer upload surface uses:
    /// this tool takes file paths and nothing else, so there is no second field to carry.
    /// Empty entries are dropped here rather than sent on to fail at the read.
    static func paths(_ input: WorkflowValue?) -> [String] {
        guard let items = PageToolInput.array(input, "paths") else { return [] }
        return items.compactMap { item in
            guard case let .string(path) = item, !path.isEmpty else { return nil }
            return path
        }
    }
}
