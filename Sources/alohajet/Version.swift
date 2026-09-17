// MARK: - The one place this package states its version
//
// Two things need it and used to disagree: the MCP server's `serverInfo`, which told
// every client 0.1.0 long after 0.2.0 shipped, and `--version`, which did not exist at
// all — it fell through to the help text and exited 0, so a script asking what it was
// running got a success and a paragraph of prose.
//
// The release tarball takes its version from the tag instead (`GITHUB_REF_NAME`), so
// these two CAN drift. They are not allowed to silently: release.yml asserts the tag
// matches this constant and fails the build when it does not. Bump this in the commit
// you tag, not after it.
public let alohajetVersion = "0.4.0"
