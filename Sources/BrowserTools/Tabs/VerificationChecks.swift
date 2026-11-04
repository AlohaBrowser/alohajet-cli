import Foundation
import CDP
import ToolABI

// MARK: - Verification checks these tools cannot complete
//
// A CAPTCHA runs in a cross-origin frame (Turnstile's sits inside a closed shadow root), so
// the DOM walk gives it no aloha-id. Measured over MCP, a model shown such a page refused
// nine times in ten without saying why. A host that completes checks conforms its tabs to
// `PageReadRemediating` and speaks for itself; with none, the read names the check, says it
// is not completed, and says who can complete it.

/// Who makes the check, known by the public host its frame is served from.
enum VerificationCheckVendor: String, Sendable, CaseIterable {
    case cloudflare = "Cloudflare"
    case recaptcha = "reCAPTCHA"
    case hcaptcha = "hCaptcha"
    case mtcaptcha = "MTCaptcha"

    /// The key ``verificationCheckPageStateScript`` reports this vendor's completion under.
    var pageStateKey: String {
        switch self {
        case .cloudflare: "cloudflare"
        case .recaptcha: "recaptcha"
        case .hcaptcha: "hcaptcha"
        case .mtcaptcha: "mtcaptcha"
        }
    }
}

/// The vendor whose check a frame at `url` shows; `nil` for any other frame, and for the
/// frames a vendor loads that show no check: reCAPTCHA's challenge frame and invisible
/// anchor, hCaptcha's challenge frame and invisible checkbox. A challenge that pops up is
/// still behind its checkbox, which is the frame that counts.
nonisolated func verificationCheckVendor(frameURL url: String) -> VerificationCheckVendor? {
    guard let components = URLComponents(string: url), let host = components.host?.lowercased() else {
        return nil
    }
    func within(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
    if host == "challenges.cloudflare.com" { return .cloudflare }
    if ["www.google.com", "recaptcha.google.com", "www.recaptcha.net", "recaptcha.net"].contains(host) {
        guard components.path.hasPrefix("/recaptcha/"), components.path.hasSuffix("/anchor") else { return nil }
        return components.queryItems?.first(where: { $0.name == "size" })?.value == "invisible" ? nil : .recaptcha
    }
    if within("hcaptcha.com") {
        let fragment = URLComponents(string: "?" + (components.fragment ?? ""))?.queryItems ?? []
        return fragment.first(where: { $0.name == "frame" })?.value == "checkbox" ? .hcaptcha : nil
    }
    if within("mtcaptcha.com") { return .mtcaptcha }
    return nil
}

/// The checks one page shows and has not completed.
struct PendingVerificationChecks: Equatable, Sendable {
    var vendors: [VerificationCheckVendor]
    /// The browser runs with no window, so no person can complete a check in it.
    var headless: Bool
}

/// A tab that can say which verification checks its page shows. Probed with `as?`, like
/// the other tab seams.
@MainActor protocol VerificationCheckReporting: AnyObject {
    /// `nil` when the page could not be asked; an empty list when it shows none.
    func pendingVerificationChecks(_ signal: AbortSignal?) async -> PendingVerificationChecks?
}

/// What a page read that meets a verification check says beyond the check itself.
public enum VerificationCheckNote {
    /// Where the host's user can have such a check completed, appended to the line as one
    /// sentence. `nil`, the default, says nothing: this package knows no such place.
    public static var elsewhere: String?
}

func verificationCheckLine(
    _ checks: PendingVerificationChecks, elsewhere: String? = VerificationCheckNote.elsewhere
) -> String {
    let names = checks.vendors.map(\.rawValue)
    let named = names.count < 2
        ? names.joined()
        : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    let who = checks.headless
        ? "no one can complete it in this browser: it is headless, and no person can see it. Tell your user that the check blocked the page."
        : "a person at this browser's window can complete it: ask your user to, then read the tab again."
    var line = "Verification check not completed on this page: \(named). These tools cannot complete it,"
        + " because it runs in a frame of its own that carries no aloha-id, so do not try to click or type into it."
        + " Some checks complete by themselves within seconds: read the tab again before you go on."
        + " If it is still here, \(who)"
    if let elsewhere, !elsewhere.isEmpty { line += " " + elsewhere }
    return line
}

/// Run in the page's main world. A vendor's check counts as completed once its script has
/// written the token: into the form field its integration documents, or behind its own
/// `getResponse`. A Cloudflare challenge page (`_cf_chl_opt`) has none to write; it is
/// pending for as long as it is the page.
let verificationCheckPageStateScript = """
    (() => {
      const filled = (name) => Array.prototype.some.call(document.getElementsByName(name),
        (field) => typeof field.value === 'string' && field.value.length > 0);
      const answered = (api) => {
        try {
          const token = api && typeof api.getResponse === 'function' ? api.getResponse() : '';
          return typeof token === 'string' && token.length > 0;
        } catch (error) { return false; }
      };
      return {
        completed: {
          cloudflare: filled('cf-turnstile-response') || answered(window.turnstile),
          recaptcha: filled('g-recaptcha-response') || answered(window.grecaptcha),
          hcaptcha: filled('h-captcha-response') || answered(window.hcaptcha),
          mtcaptcha: filled('mtcaptcha-verifiedtoken')
        },
        challengePage: typeof window._cf_chl_opt === 'object' && window._cf_chl_opt !== null,
        headless: navigator.userAgent.indexOf('HeadlessChrome') !== -1
      };
    })()
    """

/// Every frame below the root of a `Page.getFrameTree` reply, with its fragment: the frames
/// that share the page's process. An out-of-process frame is not in it.
nonisolated func descendantFrameURLs(_ frameTree: JSValue?) -> [String] {
    (frameTree?["childFrames"]?.arrayValue ?? []).flatMap { child -> [String] in
        let frame = child["frame"]
        let own = frame?["url"]?.stringValue.map { [$0 + (frame?["urlFragment"]?.stringValue ?? "")] } ?? []
        return own + descendantFrameURLs(child)
    }
}

extension CDPTabHandle: VerificationCheckReporting {
    func pendingVerificationChecks(_ signal: AbortSignal?) async -> PendingVerificationChecks? {
        let answer = try? await withCDPDeadline(milliseconds: 6_000) { [weak self] in
            await self?.pendingVerificationChecks(
                classify: verificationCheckVendor(frameURL:), settleMilliseconds: 3_000, signal: signal)
        }
        return answer ?? nil
    }

    /// `settleMilliseconds` is how long a check that is shown but not completed is watched
    /// before it is reported: a widget that passes by itself writes its token within about
    /// two seconds of loading, and a read that lands in that window would report a check
    /// nobody has to complete.
    func pendingVerificationChecks(
        classify: @escaping @Sendable (String) -> VerificationCheckVendor?,
        settleMilliseconds: Int,
        signal: AbortSignal?
    ) async -> PendingVerificationChecks? {
        guard tabType == "website", !session.isDestroyed, let sessionId = try? await session.ensureAttached() else {
            return nil
        }
        let client = session.client
        var shown: [VerificationCheckVendor] = []
        func note(_ vendor: VerificationCheckVendor?) {
            if let vendor, !shown.contains(vendor) { shown.append(vendor) }
        }

        if let tree = try? await client.send(method: "Page.getFrameTree", params: [:], sessionId: sessionId) {
            descendantFrameURLs(tree["frameTree"]).forEach { note(classify($0)) }
        }
        if let listing = try? await client.send(method: "Target.getTargets", params: [:]) {
            for info in listing["targetInfos"]?.arrayValue ?? [] where info["type"]?.stringValue == "iframe" {
                guard let targetId = info["targetId"]?.stringValue,
                      let vendor = classify(info["url"]?.stringValue ?? ""), !shown.contains(vendor) else { continue }
                // The listing is browser-wide: another tab showing the same widget lists a frame
                // too, and only this page's session knows an owner for this page's frames.
                let owner = try? await client.send(
                    method: "DOM.getFrameOwner", params: ["frameId": .string(targetId)], sessionId: sessionId)
                if owner != nil { note(vendor) }
            }
        }

        func pageState() async -> JSValue? {
            guard let reply = try? await client.send(method: "Runtime.evaluate", params: [
                      "expression": .string(verificationCheckPageStateScript),
                      "returnByValue": .bool(true),
                  ], sessionId: sessionId),
                  reply["exceptionDetails"] == nil,
                  let state = reply["result"]?["value"], state["completed"] != nil else { return nil }
            return state
        }
        guard var state = await pageState() else { return nil }
        // A challenge page is pending for as long as it is the page, and the next document is
        // not the one this read described: it is never watched.
        let challengePage = state["challengePage"]?.boolValue == true
        if challengePage { note(.cloudflare) }
        func pending(_ state: JSValue) -> [VerificationCheckVendor] {
            shown.filter { vendor in
                (vendor == .cloudflare && challengePage) || state["completed"]?[vendor.pageStateKey]?.boolValue != true
            }
        }
        var vendors = pending(state)
        let settled = Date().addingTimeInterval(Double(settleMilliseconds) / 1_000)
        while !vendors.isEmpty, !challengePage, Date() < settled, signal?.aborted != true, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let next = await pageState() else { break }
            state = next
            vendors = pending(next)
        }
        var headless = state["headless"]?.boolValue == true
        if !headless { headless = await browserStartedHeadless(client) }
        return PendingVerificationChecks(vendors: vendors, headless: headless)
    }
}

/// Whether the browser behind `client` was started headless, by the command line
/// `SystemInfo.getInfo` reports. A page sees it only in a User-Agent that still says
/// HeadlessChrome, and a `--user-agent` on that command line takes it out.
/// `false` when the browser does not say: one without the domain, or a page-level connection.
@MainActor func browserStartedHeadless(_ client: CDPClient) async -> Bool {
    let info = try? await withCDPDeadline(milliseconds: 1_000) {
        try await client.send(method: "SystemInfo.getInfo", params: [:])
    }
    return info?["commandLine"]?.stringValue.map(commandLineStartsHeadless) ?? false
}

/// Whether a browser command line, as Chrome joins it with spaces, carries `--headless`.
nonisolated func commandLineStartsHeadless(_ commandLine: String) -> Bool {
    commandLine.split(whereSeparator: \.isWhitespace).contains { $0 == "--headless" || $0.hasPrefix("--headless=") }
}
