import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

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
//
// WHERE IT MAY GO. This credential grants `/agent/task`, `/agent/config` — which
// rewrites the user's LLM provider key — and `/quit`. So the AMBIENT one, the file
// the browser provisioned and that the user never typed, is sent to a LOOPBACK
// endpoint and nowhere else: `--endpoint https://someone-elses-host` gets no
// Authorization header from the file, because nobody consented to hand that host the
// browser. A non-loopback endpoint must be given the token explicitly, via
// `ALOHAJET_AGENT_TOKEN` — an env var is a deliberate act, a file on disk is not.
// (Plaintext http to a non-loopback host is refused a step earlier still, at
// argument-parse time, so the prompt itself never leaves the machine in the clear.)

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

    /// The token to send to `endpoint`, or `nil` when there is none to send there.
    /// The environment wins over the file, and is the ONLY source a non-loopback
    /// endpoint is served from. Surrounding whitespace is trimmed (a hand-edited file
    /// carries a trailing newline) and an empty value reads as `nil`, so an empty —
    /// i.e. useless — secret is never sent as if it were one.
    public static func read(
        for endpoint: URL,
        at url: URL = defaultURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = trimmed(environment[environmentVariable]) { return value }
        guard isLoopback(endpoint) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return trimmed(String(decoding: data, as: UTF8.self))
    }

    /// Whether `url` names this machine over the loopback interface.
    ///
    /// The numeric forms are PARSED, not prefix-matched: `127.0.0.1.evil.example` has
    /// the prefix and is a remote name that resolves wherever its owner points it, and
    /// `127.1` lacks the dotted-quad shape and IS loopback. `inet_pton` is the arbiter
    /// of both, and it also rejects a host that merely looks numeric.
    ///
    /// KNOWN CEILING: `localhost` is trusted by name, not resolved — rewriting it needs
    /// root, and a root attacker owns the token file anyway. Resolve it if that ever
    /// stops being true.
    public static func isLoopback(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" { return true }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }

        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127      // 127.0.0.0/8, all of it
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: v6) { bytes in
                bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1   // ::1
            }
        }
        return false
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
