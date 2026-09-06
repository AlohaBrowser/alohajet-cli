import Foundation
import CDP
import ToolABI
#if canImport(zlib)
import zlib
#endif

// MARK: - Constants

public nonisolated let GZIP_MAGIC_BYTE_1 = 31
public nonisolated let GZIP_MAGIC_BYTE_2 = 139
public nonisolated let MAX_BODY_CAPTURE_BYTES = 50_000

nonisolated let IGNORED_RESOURCE_TYPES: Set<String> = ["Image", "Media", "Font", "Stylesheet", "Ping", "CSPViolationReport", "Preflight"]
nonisolated let CAPTURABLE_MIME_TYPES: [String] = [
    "application/json", "text/html", "text/plain", "text/xml", "application/xml",
    "application/x-www-form-urlencoded", "application/x-protobuf", "application/octet-stream",
    "application/grpc-web",
]

public let TYPING_SESSION_CONFIG = TypingSessionConfig()
public struct TypingSessionConfig: Sendable {
    public let reuseWindowMs: Double = 60 * 60 * 1000
    public let textChangeThreshold: Double = 0.9
    public let minCharDistance: Int = 8
    public let emitDebounceMs: Double = 500
}

public let ACTIVITY_TRACKING_CONFIG = ActivityTrackingConfig()
public struct ActivityTrackingConfig: Sendable {
    public let scrollThresholdPx: Int = 1200
    public let scrollSettleMs: Double = 500
    public let idleCheckIntervalMs: Double = 30_000
    public let idleThresholdMs: Double = 60_000
    public let awayThresholdMs: Double = 120_000
    public let maxActiveSessions: Int = 5
}

// MARK: - Base64 body decoding

/// Decodes a base64-encoded response body, gunzipping when it carries the gzip
/// magic bytes. Falls back to a `base64:`-prefixed marker when decoding fails.
public func decodeBase64Body(_ base64: String) -> String {
    guard let data = Data(base64Encoded: base64) else { return "base64:\(base64)" }
    if data.count >= 2, Int(data[data.startIndex]) == GZIP_MAGIC_BYTE_1, Int(data[data.index(after: data.startIndex)]) == GZIP_MAGIC_BYTE_2 {
        if let decompressed = gunzip(data), let text = String(data: decompressed, encoding: .utf8) {
            return text
        }
        return "base64:\(base64)"
    }
    return String(data: data, encoding: .utf8) ?? "base64:\(base64)"
}

private func gunzip(_ data: Data) -> Data? {
    #if canImport(zlib)
    guard !data.isEmpty else { return nil }
    var stream = z_stream()
    // windowBits = 47 enables automatic gzip/zlib header detection.
    guard inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        return nil
    }
    defer { inflateEnd(&stream) }

    var output = Data()
    let chunkSize = 16_384
    var succeeded = false
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        stream.next_in = UnsafeMutablePointer(mutating: base)
        stream.avail_in = uInt(data.count)
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var status: Int32 = Z_OK
        repeat {
            status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(chunkSize)
                let code = inflate(&stream, Z_NO_FLUSH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer.baseAddress!, count: produced)
                }
                return code
            }
            if status != Z_OK && status != Z_STREAM_END { return }
        } while status != Z_STREAM_END && stream.avail_in > 0
        succeeded = (status == Z_STREAM_END)
    }
    return succeeded ? output : nil
    #else
    return nil
    #endif
}

// MARK: - Network event model

public nonisolated struct NetworkRecord: Sendable, Equatable {
    public var ts: String
    public var type: String
    public var requestId: String
    public var method: String
    public var url: String
    public var resourceType: String?
    public var requestHeaders: [String: String]?
    public var postData: String?
    public var status: Int?
    public var statusText: String?
    public var mimeType: String?
    public var responseHeaders: [String: String]?
    public var bodySize: Int?
    public var body: String?
    public var errorText: String?

    public init(
        ts: String, type: String, requestId: String, method: String, url: String,
        resourceType: String? = nil, requestHeaders: [String: String]? = nil, postData: String? = nil,
        status: Int? = nil, statusText: String? = nil, mimeType: String? = nil,
        responseHeaders: [String: String]? = nil, bodySize: Int? = nil, body: String? = nil,
        errorText: String? = nil
    ) {
        self.ts = ts
        self.type = type
        self.requestId = requestId
        self.method = method
        self.url = url
        self.resourceType = resourceType
        self.requestHeaders = requestHeaders
        self.postData = postData
        self.status = status
        self.statusText = statusText
        self.mimeType = mimeType
        self.responseHeaders = responseHeaders
        self.bodySize = bodySize
        self.body = body
        self.errorText = errorText
    }
}

private nonisolated struct PendingNetworkRequest {
    var method: String
    var url: String
    var resourceType: String?
    var requestHeaders: [String: String]?
    var postData: String?
    var responseStatus: Int?
    var responseStatusText: String?
    var responseMimeType: String?
    var responseHeaders: [String: String]?
}

// MARK: - NetworkRecorder

/// Captures a tab's network activity over a CDP transport and emits structured
/// records via a callback. Bodies are captured for a small allow-list of
/// content types, gunzipped when needed and clamped to a byte budget.
public final class NetworkRecorder {
    private let transport: CDPTransport
    private let callback: @MainActor @Sendable (NetworkRecord) -> Void
    private var pendingRequests: [String: PendingNetworkRequest] = [:]
    private var running = false
    private var eventTask: Task<Void, Never>?

    public init(transport: CDPTransport, callback: @escaping @MainActor @Sendable (NetworkRecord) -> Void) {
        self.transport = transport
        self.callback = callback
    }

    public func isRecording() -> Bool {
        return running
    }

    func setRunningForTesting(_ value: Bool) {
        running = value;
    }

    func pendingRequestCountForTesting() -> Int {
        return pendingRequests.count
    }

    public func start() async {
        if running { return }
        do {
            _ = try await transport.send(method: "Network.enable", params: [
                "maxTotalBufferSize": .number(Double(10 * 1024 * 1024)),
                "maxResourceBufferSize": .number(Double(5 * 1024 * 1024)),
            ])
        } catch {
            agentLog(.error, "[NetworkRecorder] Failed to enable Network domain: \(error)")
            return
        }
        running = true
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.transport.events() {
                if !self.isRecording() { break }
                if event.method == "Inspector.detached" {
                    self.handleDetached()
                    break
                }
                self.onCDPMessage(event.method, event.params)
            }
            // The event stream finishing while still recording means the
            // transport disconnected out from under us (the in-process
            // equivalent of the debugger's `detach` event firing externally).
            if self.isRecording() {
                self.handleDetached()
            }
        }
    }

    /// Reacts to the CDP connection being torn down externally — either an
    /// `Inspector.detached` event or the event stream ending while recording is
    /// still active. Stops recording without trying to issue `Network.disable`
    /// over the now-dead transport, cancels the event loop, and clears any
    /// in-flight pending requests, without issuing further CDP commands.
    func handleDetached() {
        if !running { return }
        running = false
        agentLog(.warn, "[NetworkRecorder] Debugger was detached externally, stopping recording")
        eventTask?.cancel()
        eventTask = nil
        pendingRequests.removeAll()
    }

    public func stop() async {
        if !running { return }
        running = false
        do {
            _ = try await transport.send(method: "Network.disable")
        } catch {}
        eventTask?.cancel()
        eventTask = nil
        pendingRequests.removeAll()
    }

    func onCDPMessage(_ method: String, _ params: JSValue) {
        switch method {
        case "Network.requestWillBeSent":
            onRequestWillBeSent(params)
        case "Network.responseReceived":
            onResponseReceived(params)
        case "Network.loadingFinished":
            onLoadingFinished(params)
        case "Network.loadingFailed":
            onLoadingFailed(params)
        default:
            break
        }
    }

    private func onRequestWillBeSent(_ params: JSValue) {
        guard let requestId = params.string("requestId"),
              let request = params["request"],
              let url = request.string("url") else { return }
        let type = params.string("type")
        if url.hasPrefix("data:") { return }
        if let type, IGNORED_RESOURCE_TYPES.contains(type) { return }
        let method = request.string("method") ?? ""
        let headers = stringDictionary(request["headers"])
        let postData = request.string("postData")
        pendingRequests[requestId] = PendingNetworkRequest(
            method: method,
            url: url,
            resourceType: type,
            requestHeaders: headers,
            postData: postData.map { String($0.prefix(MAX_BODY_CAPTURE_BYTES)) }
        )
    }

    private func onResponseReceived(_ params: JSValue) {
        guard let requestId = params.string("requestId"), let response = params["response"] else { return }
        guard var pending = pendingRequests[requestId] else { return }
        pending.responseStatus = response.number("status").map { Int($0) }
        pending.responseStatusText = response.string("statusText")
        pending.responseMimeType = response.string("mimeType")
        pending.responseHeaders = stringDictionary(response["headers"])
        pendingRequests[requestId] = pending
    }

    private func onLoadingFinished(_ params: JSValue) {
        guard let requestId = params.string("requestId") else { return }
        let pending = pendingRequests.removeValue(forKey: requestId)
        guard let pending else { return }
        if shouldCaptureBody(pending) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.fetchResponseBodyAndEmit(requestId, pending)
                } catch {
                    self.emitComplete(pending)
                }
            }
        } else {
            emitComplete(pending)
        }
    }

    private func onLoadingFailed(_ params: JSValue) {
        guard let requestId = params.string("requestId") else { return }
        let pending = pendingRequests.removeValue(forKey: requestId)
        guard let pending else { return }
        emit(NetworkRecord(
            ts: isoTimestamp(),
            type: "failed",
            requestId: requestId,
            method: pending.method,
            url: pending.url,
            resourceType: pending.resourceType,
            requestHeaders: pending.requestHeaders,
            postData: pending.postData,
            status: pending.responseStatus,
            statusText: pending.responseStatusText,
            errorText: params.string("errorText")
        ))
    }

    private func emitComplete(_ pending: PendingNetworkRequest, body: String? = nil, bodySize: Int? = nil) {
        emit(NetworkRecord(
            ts: isoTimestamp(),
            type: "complete",
            requestId: "",
            method: pending.method,
            url: pending.url,
            resourceType: pending.resourceType,
            requestHeaders: pending.requestHeaders,
            postData: pending.postData,
            status: pending.responseStatus,
            statusText: pending.responseStatusText,
            mimeType: pending.responseMimeType,
            responseHeaders: pending.responseHeaders,
            bodySize: bodySize,
            body: body
        ))
    }

    private func fetchResponseBodyAndEmit(_ requestId: String, _ pending: PendingNetworkRequest) async throws {
        if !isRecording() {
            emitComplete(pending)
            return
        }
        do {
            let result = try await transport.send(method: "Network.getResponseBody", params: ["requestId": .string(requestId)])
            let rawBody = result.string("body") ?? ""
            let base64Encoded = result.bool("base64Encoded") ?? false
            let decoded = base64Encoded ? decodeBase64Body(rawBody) : rawBody
            emitComplete(pending, body: String(decoded.prefix(MAX_BODY_CAPTURE_BYTES)), bodySize: rawBody.count)
        } catch {
            emitComplete(pending)
        }
    }

    private func shouldCaptureBody(_ pending: PendingNetworkRequest) -> Bool {
        guard let mimeType = pending.responseMimeType else { return false }
        return CAPTURABLE_MIME_TYPES.contains { mimeType.hasPrefix($0) }
    }

    private func emit(_ record: NetworkRecord) {
        callback(record)
    }
}

private func stringDictionary(_ value: JSValue?) -> [String: String]? {
    guard let members = value?.objectValue else { return nil }
    var result: [String: String] = [:]
    for (key, val) in members {
        if let s = val.stringValue { result[key] = s }
        else if let n = val.doubleValue { result[key] = numberToString(n) }
        else if let b = val.boolValue { result[key] = String(b) }
    }
    return result
}

private func numberToString(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}

private func isoTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

// MARK: - TypingSession

/// Tracks a single in-page typing session, deciding when keystroke bursts belong
/// to the same edit and emitting a debounced text-input event.
public final class TypingSession {
    public let sessionId: String
    public let elementSelector: String
    public let url: String
    public private(set) var text: String
    public private(set) var lastUpdate: Double
    public let startTime: Double

    private let emit: @MainActor @Sendable (TypingSession) -> Void
    private var debounceTask: Task<Void, Never>?

    public init(
        elementSelector: String,
        url: String,
        text: String,
        timestamp: Double,
        emit: @escaping @MainActor @Sendable (TypingSession) -> Void,
        generateId: () -> String = { UUID().uuidString }
    ) {
        self.sessionId = generateId()
        self.elementSelector = elementSelector
        self.url = url
        self.text = text
        self.lastUpdate = timestamp
        self.startTime = timestamp
        self.emit = emit
        debouncedEmit(timestamp)
    }

    public func isSameTypingSession(_ selector: String, _ url: String, _ candidateText: String, _ timestamp: Double) -> Bool {
        if elementSelector != selector || self.url != url || timestamp - lastUpdate >= TYPING_SESSION_CONFIG.reuseWindowMs {
            return false
        }
        let distance = levenshteinDistance(text, candidateText)
        let shrinkRatio = text.count > 0 ? Double(text.count - candidateText.count) / Double(text.count) : 0
        return !(shrinkRatio > TYPING_SESSION_CONFIG.textChangeThreshold && distance > TYPING_SESSION_CONFIG.minCharDistance)
    }

    public func updateText(_ newText: String, _ timestamp: Double) {
        text = newText
        lastUpdate = timestamp
        debouncedEmit(timestamp)
    }

    public func isStale(_ now: Double) -> Bool {
        now - lastUpdate > TYPING_SESSION_CONFIG.reuseWindowMs
    }

    public func cancelPendingEmit() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func debouncedEmit(_ timestamp: Double) {
        // Leading + trailing debounce: fire immediately, then again after the
        // debounce interval if further updates arrive.
        let isLeadingEdge = debounceTask == nil
        if isLeadingEdge {
            emit(self)
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            let nanos = UInt64(TYPING_SESSION_CONFIG.emitDebounceMs * 1_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled else { return }
            self.emit(self)
            self.debounceTask = nil
        }
    }
}

/// Classic Levenshtein edit distance between two strings.
func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs)
    let b = Array(rhs)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}
