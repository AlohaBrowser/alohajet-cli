import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// The network log was ON by default, written 0644, and it serialized request and
// response headers verbatim — on any logged-in page that is `Cookie:` and
// `Authorization:` in a world-readable file nobody asked for. Eighty-two such files
// existed on the machine this was found on. These pin the three halves of the fix:
// off unless asked, 0600 when asked, credentials masked either way.

@Suite("network log privacy")
struct NetworkLogPrivacyTests {
    @Test("no network log directory unless the environment asks for one")
    func offByDefault() {
        unsetenv("ALOHAJET_NETWORK_LOG")
        #expect(environmentNetworkLogDirectory(sessionId: "s") == nil)

        setenv("ALOHAJET_NETWORK_LOG", "off", 1)
        #expect(environmentNetworkLogDirectory(sessionId: "s") == nil)

        setenv("ALOHAJET_NETWORK_LOG", "/tmp/aj-log-test", 1)
        #expect(environmentNetworkLogDirectory(sessionId: "s") == "/tmp/aj-log-test")

        setenv("ALOHAJET_NETWORK_LOG", "1", 1)
        #expect(environmentNetworkLogDirectory(sessionId: "s")?.hasSuffix("alohajet/s/network") == true)

        unsetenv("ALOHAJET_NETWORK_LOG")
    }

    @Test("credential headers and request bodies never reach the log")
    func redactsCredentials() {
        let record = NetworkRecord(
            ts: "2026-01-01T00:00:00Z", type: "complete", requestId: "1", method: "POST",
            url: "https://example.com/login",
            requestHeaders: [
                "Cookie": "session=SECRET-COOKIE",
                "Authorization": "Bearer SECRET-TOKEN",
                "Proxy-Authorization": "Basic SECRET-PROXY",
                "User-Agent": "Mozilla/5.0"
            ],
            postData: "username=ada&password=hunter2",
            responseHeaders: [
                "set-cookie": "session=SECRET-SET-COOKIE; HttpOnly",
                "Content-Type": "text/html"
            ],
            body: "{\"access_token\": \"SECRET-ACCESS\", \"user\": \"ada\"}")
        let line = NetworkLogWriter.encode(record)

        for secret in ["SECRET-COOKIE", "SECRET-TOKEN", "SECRET-PROXY", "SECRET-SET-COOKIE",
                       "hunter2", "SECRET-ACCESS"] {
            #expect(!line.contains(secret), "\(secret) leaked into the network log line")
        }
        // The SHAPE of the request survives — that is what a network log is for.
        #expect(line.contains("Mozilla/5.0"))
        #expect(line.contains("text/html"))
        #expect(line.contains("https://example.com/login"))
        #expect(line.contains("\"Cookie\""))
        #expect(line.contains("ada"))   // the body's non-credential fields survive
    }

    @Test("a credential in the query string is masked too")
    func redactsUrlQueryCredentials() {
        let line = NetworkLogWriter.encode(NetworkRecord(
            ts: "t", type: "complete", requestId: "1", method: "GET",
            url: "https://example.com/cb?code=SECRET-CODE&access_token=SECRET-AT&page=2"))
        #expect(!line.contains("SECRET-CODE"))
        #expect(!line.contains("SECRET-AT"))
        #expect(line.contains("page=2"))
    }

    @Test("a credential the page URL carries into Referer is masked there too")
    func redactsUrlValuedHeaders() {
        let line = NetworkLogWriter.encode(NetworkRecord(
            ts: "t", type: "complete", requestId: "1", method: "GET",
            url: "https://example.com/favicon.ico",
            requestHeaders: [
                "Referer": "https://example.com/p?token=SECRET-TOK&page=2",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
            ],
            responseHeaders: ["Location": "https://example.com/next?session=SECRET-SESS&ok=1"]))
        #expect(!line.contains("SECRET-TOK"))
        #expect(!line.contains("SECRET-SESS"))
        // The shape of the request is why a log gets opened: what is not a credential stays.
        #expect(line.contains("page=2"))
        #expect(line.contains("ok=1"))
        #expect(line.contains("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"))
    }

    @Test("the log file is created 0600, not 0644")
    func createsPrivateFile() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("aj-netlog-perm-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }

        NetworkLogWriter(path: path).append(NetworkRecord(
            ts: "t", type: "complete", requestId: "1", method: "GET", url: "https://example.com/"))

        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        #expect(mode.int16Value == 0o600)
    }
}

// A password typed into a login form came back out through BOTH paths a page's text
// takes to the model: the document walker folded `input.value` into the element's
// comprehensive text (so `read` printed `input(password, "hunter2")`) and `get_text`
// returned `el.value` verbatim. Masking lives in the page-side scripts, which no unit
// test can execute — so this pins the guard at each site it has to be at, by name.
// The end-to-end proof is by hand, in this change's report.

@Suite("credential field masking")
@MainActor struct CredentialFieldMaskingTests {
    @Test("every page-side read of a field's value is guarded")
    func everyValueSiteIsGuarded() {
        let walker = buildAgentDomTreeScript(highlight: false, focusInteractive: true)
        let runtime = buildInpageAlohaRuntime()

        #expect(walker.contains("function __alohaIsSensitiveField"))
        #expect(runtime.contains("function __alohaIsSensitiveField"))

        // The document walker: comprehensive text (what `read` prints), the input/textarea
        // descriptors, and the form-value text source.
        #expect(walker.contains("if (input.value && !__alohaIsSensitiveField(input)) add(input.value);"))
        #expect(walker.contains("if (textarea.value && !__alohaIsSensitiveField(textarea)) add(textarea.value);"))
        #expect(walker.contains("__alohaIsSensitiveField(input) ? '[redacted: credential field]' : (input.value || \"\")"))
        #expect(walker.contains("__alohaIsSensitiveField(textarea) ? '[redacted: credential field]' : (textarea.value || \"\")"))
        #expect(walker.contains("__alohaIsSensitiveField(element) ? '[redacted: credential field]' : (element.value || \"\")"))

        // The `window.__aloha` runtime: the one read `get_text` drives.
        #expect(runtime.contains("if (__alohaIsSensitiveField(el)) return '[redacted: credential field]';"))
    }

    @Test("the predicate does not blank a passenger or passport field")
    func doesNotOvermatch() {
        // Bare `pass` is deliberately absent: it matches "Passenger", "Passport" and
        // "Bypass", and silently blanking those values would corrupt ordinary reads.
        #expect(!sensitiveFieldPredicateJS.contains("'pass'"))
        #expect(sensitiveFieldPredicateJS.contains("'password'"))
        #expect(sensitiveFieldPredicateJS.contains("'pwd'"))
    }
}
