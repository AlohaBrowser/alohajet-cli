import Foundation

// MARK: - What a refusal is allowed to tell the model to do instead

/// A refusal that only says "no" costs the model a round; one that names the alternative
/// ends the loop. But the alternative is the HOST's tool, and this package cannot know it —
/// it ships `page_upload`, while the agent that embeds it advertises `upload_file` and a
/// pair of sandboxed file readers this package has never heard of. Naming the wrong one is
/// worse than naming none: the model spends its round on "Unknown tool".
///
/// So the names are the host's to set, once, at composition. The defaults are this
/// package's own verbs, which is correct for the CLI and for MCP.
public enum HostToolNames {
    /// The verb that attaches files to a file `<input>`. Named by the refusal a click on
    /// such an input returns.
    public static var fileInputUpload = "page_upload"

    /// The verb that reads a local file, if the host has one. `nil` means "say nothing" —
    /// this package has no local file reader, and inventing one in a refusal is a lie.
    public static var localFileRead: String?
}
