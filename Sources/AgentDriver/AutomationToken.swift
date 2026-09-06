import Foundation

// MARK: - Automation bearer token
//
// Every route on an agent endpoint drives the user's browser, so every route is
// bearer-token gated and both ends of the wire need the same secret. This package
// is the CLIENT half and READS ONLY: the host that serves `/agent/task` is the one
// that mints the credential, writes it 0600, and verifies the mode after the write
// (an atomic write lands a fresh inode whose permissions come from the umask).
// Nothing here provisions, because a public tool must not mint another process's
// credential — nor write into another product's home.
//
// Read per request rather than cached, so a rotation is picked up without
// restarting. Absent ⇒ no `Authorization` header ⇒ the endpoint answers 401 and
// the driver reports that verbatim — never a silent unauthenticated attempt.

public nonisolated enum AutomationToken {

    /// `ALOHAJET_AGENT_TOKEN`, so an endpoint that keeps its credential anywhere
    /// else is still reachable.
    public static let environmentVariable = "ALOHAJET_AGENT_TOKEN"

    /// `~/Library/Application Support/Aloha/automation-token` — where the Aloha
    /// browser's automation server provisions the shared secret.
    public static var defaultURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return
            base
            .appendingPathComponent("Aloha", isDirectory: true)
            .appendingPathComponent("automation-token")
    }

    /// The token, or `nil` when there is none. The environment wins over the file.
    /// Surrounding whitespace is trimmed (a hand-edited file carries a trailing
    /// newline) and an empty value reads as `nil`, so an empty — i.e. useless —
    /// secret is never sent as if it were one.
    public static func read(
        at url: URL = defaultURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = trimmed(environment[environmentVariable]) { return value }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return trimmed(String(decoding: data, as: UTF8.self))
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
