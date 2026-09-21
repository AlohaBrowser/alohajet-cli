import Foundation
import Testing
@testable import BrowserTools
import ToolABI
import CDP
#if canImport(zlib)
import zlib
#endif

// MARK: - Stub CDP transport

/// A controllable ``CDPTransport`` for driving ``NetworkRecorder`` deterministically.
/// The recorder consumes `send`/`events()` from off-main tasks, so this is an
/// `actor`; tests read its recorded state and drive `emit`/`finishEvents` via
/// `await`.
private actor StubCDPTransport: CDPTransport {
    private var sent: [(method: String, params: [String: JSValue])] = []
    /// Canned responses keyed by CDP method.
    private var responses: [String: JSValue] = [:]
    /// Methods that should throw when sent.
    private var throwingMethods: Set<String> = []
    private var continuation: AsyncStream<CDPEvent>.Continuation?

    func setResponse(_ method: String, _ value: JSValue) { responses[method] = value }
    func setThrowingMethods(_ methods: Set<String>) { throwingMethods = methods }

    func connect() async throws {}

    func send(method: String, params: [String: JSValue]) async throws -> JSValue {
        sent.append((method, params))
        if throwingMethods.contains(method) { throw CDPError.notConnected }
        return responses[method] ?? .object([])
    }

    nonisolated func events() -> AsyncStream<CDPEvent> {
        AsyncStream { continuation in
            Task { await self.storeContinuation(continuation) }
        }
    }

    private func storeContinuation(_ continuation: AsyncStream<CDPEvent>.Continuation) {
        self.continuation = continuation
    }

    func emit(_ event: CDPEvent) {
        continuation?.yield(event)
    }

    func finishEvents() {
        continuation?.finish()
    }

    /// True once the event-loop task has subscribed (its `events()` stream has
    /// been built and the continuation captured).
    func hasSubscribed() -> Bool {
        continuation != nil
    }

    func sentMethods() -> [String] {
        sent.map(\.method)
    }
}

private final class RecordSink {
    private var records: [NetworkRecord] = []
    func append(_ record: NetworkRecord) {
        records.append(record); }
    var all: [NetworkRecord] {
        return records
    }
}

/// Polls `condition` at a short interval until it holds or the attempt cap is reached, so
/// event-loop subscription, body fetches and teardown can be awaited deterministically.
private func waitFor(attempts: Int = 400, _ condition: @escaping () async -> Bool) async {
    var tries = 0
    while await !condition() && tries < attempts {
        try? await Task.sleep(nanoseconds: 5_000_000)
        tries += 1
    }
}

// MARK: - decodeBase64Body (successful gunzip round trip)

#if canImport(zlib)
@Suite("decodeBase64Body gzip round trip")
struct DecodeBase64BodyGzipTests {
    @Test func gzipMagicBytesAreGunzipped() {
        let original = "the quick brown fox jumps over the lazy dog"
        guard let gzipped = gzipForTest(Data(original.utf8)) else {
            // If zlib compression is unavailable, the decoder cannot be exercised.
            return
        }
        // Sanity: the produced data begins with the gzip magic bytes.
        #expect(Int(gzipped[gzipped.startIndex]) == gzipMagicByte1)
        #expect(Int(gzipped[gzipped.index(after: gzipped.startIndex)]) == gzipMagicByte2)
        let decoded = decodeBase64Body(gzipped.base64EncodedString())
        #expect(decoded == original)
    }
}

/// Gzip-compresses data for the round-trip test, mirroring the windowBits = 31
/// gzip-header convention.
private func gzipForTest(_ data: Data) -> Data? {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        return nil
    }
    defer { deflateEnd(&stream) }
    var input = [UInt8](data)
    var output = Data()
    let chunkSize = 16_384
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    let ok: Bool = input.withUnsafeMutableBufferPointer { inBuf -> Bool in
        stream.next_in = inBuf.baseAddress
        stream.avail_in = uInt(inBuf.count)
        var status: Int32 = Z_OK
        repeat {
            status = chunk.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(chunkSize)
                let code = deflate(&stream, Z_FINISH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(outBuf.baseAddress!, count: produced) }
                return code
            }
            if status != Z_OK && status != Z_STREAM_END { return false }
        } while status != Z_STREAM_END
        return true
    }
    return ok ? output : nil
}
#endif

// MARK: - onCDPMessage event handling

@Suite("NetworkRecorder event handling")
struct NetworkRecorderEventTests {
    private func makeRecorder(_ sink: RecordSink) -> (NetworkRecorder, StubCDPTransport) {
        let transport = StubCDPTransport()
        let recorder = NetworkRecorder(transport: transport) { record in sink.append(record) }
        return (recorder, transport)
    }

    private func requestParams(id: String, url: String, method: String = "GET", type: String? = nil, postData: String? = nil) -> JSValue {
        var request: [(String, JSValue)] = [
            ("url", .string(url)),
            ("method", .string(method)),
        ]
        if let postData { request.append(("postData", .string(postData))) }
        var members: [(String, JSValue)] = [
            ("requestId", .string(id)),
            ("request", .object(request)),
        ]
        if let type { members.append(("type", .string(type))) }
        return .object(members)
    }

    @Test func loadingFailedEmitsFailedRecord() {
        let sink = RecordSink()
        let (recorder, _) = makeRecorder(sink)
        recorder.onCDPMessage("Network.requestWillBeSent", requestParams(id: "r1", url: "https://api.example.com/v1", method: "POST", postData: "payload"))
        recorder.onCDPMessage("Network.loadingFailed", .object([
            ("requestId", .string("r1")),
            ("errorText", .string("net::ERR_TIMED_OUT")),
        ]))
        let records = sink.all
        #expect(records.count == 1)
        #expect(records.first?.type == "failed")
        #expect(records.first?.requestId == "r1")
        #expect(records.first?.method == "POST")
        #expect(records.first?.url == "https://api.example.com/v1")
        #expect(records.first?.postData == "payload")
        #expect(records.first?.errorText == "net::ERR_TIMED_OUT")
    }

    @Test func loadingFinishedWithoutCapturableMimeEmitsCompleteWithNoBody() {
        let sink = RecordSink()
        let (recorder, _) = makeRecorder(sink)
        recorder.onCDPMessage("Network.requestWillBeSent", requestParams(id: "r1", url: "https://x.test/page"))
        // text/css is NOT in capturableMimeTypes -> shouldCaptureBody is false.
        recorder.onCDPMessage("Network.responseReceived", .object([
            ("requestId", .string("r1")),
            ("response", .object([
                ("status", .number(200)),
                ("statusText", .string("OK")),
                ("mimeType", .string("text/css")),
                ("headers", .object([("content-type", .string("text/css"))])),
            ])),
        ]))
        recorder.onCDPMessage("Network.loadingFinished", .object([("requestId", .string("r1"))]))
        let records = sink.all
        #expect(records.count == 1)
        #expect(records.first?.type == "complete")
        #expect(records.first?.requestId == "")
        #expect(records.first?.status == 200)
        #expect(records.first?.statusText == "OK")
        #expect(records.first?.mimeType == "text/css")
        #expect(records.first?.body == nil)
        #expect(records.first?.responseHeaders?["content-type"] == "text/css")
    }

    @Test func dataUrlRequestsAreIgnored() {
        let sink = RecordSink()
        let (recorder, _) = makeRecorder(sink)
        recorder.onCDPMessage("Network.requestWillBeSent", requestParams(id: "r1", url: "data:text/plain;base64,QQ=="))
        // No pending request was stored, so loadingFinished emits nothing.
        recorder.onCDPMessage("Network.loadingFinished", .object([("requestId", .string("r1"))]))
        #expect(sink.all.isEmpty)
    }

    @Test func ignoredResourceTypesAreSkipped() {
        let sink = RecordSink()
        let (recorder, _) = makeRecorder(sink)
        // "Image" is in ignoredResourceTypes.
        recorder.onCDPMessage("Network.requestWillBeSent", requestParams(id: "r1", url: "https://x.test/logo.png", type: "Image"))
        recorder.onCDPMessage("Network.loadingFailed", .object([("requestId", .string("r1"))]))
        #expect(sink.all.isEmpty)
    }

    @Test func responseReceivedForUnknownRequestIsNoOp() {
        let sink = RecordSink()
        let (recorder, _) = makeRecorder(sink)
        // No matching pending request -> responseReceived returns early; nothing emitted.
        recorder.onCDPMessage("Network.responseReceived", .object([
            ("requestId", .string("ghost")),
            ("response", .object([("status", .number(404))])),
        ]))
        recorder.onCDPMessage("Network.loadingFinished", .object([("requestId", .string("ghost"))]))
        #expect(sink.all.isEmpty)
    }

    @Test func postDataIsClampedToCaptureBudget() {
        let sink = RecordSink()
        let (recorder, _) = makeRecorder(sink)
        let big = String(repeating: "a", count: maxBodyCaptureBytes + 500)
        recorder.onCDPMessage("Network.requestWillBeSent", requestParams(id: "r1", url: "https://x.test/upload", method: "POST", postData: big))
        recorder.onCDPMessage("Network.loadingFailed", .object([("requestId", .string("r1"))]))
        #expect(sink.all.first?.postData?.count == maxBodyCaptureBytes)
    }

    @Test func unknownMethodIsIgnored() {
        let sink = RecordSink()
        let (recorder, _) = makeRecorder(sink)
        recorder.onCDPMessage("Network.someUnhandledEvent", .object([("requestId", .string("r1"))]))
        #expect(sink.all.isEmpty)
    }

    @Test func loadingFinishedWithCapturableMimeFetchesAndDecodesBody() async {
        let sink = RecordSink()
        let transport = StubCDPTransport()
        // The body fetch returns a plain (non-base64) body.
        await transport.setResponse("Network.getResponseBody", .object([
            ("body", .string("{\"ok\":true}")),
            ("base64Encoded", .bool(false)),
        ]))
        let recorder = NetworkRecorder(transport: transport) { sink.append($0) }
        // Mark the recorder running so fetchResponseBodyAndEmit proceeds.
        await recorder.start()

        recorder.onCDPMessage("Network.requestWillBeSent", requestParams(id: "r1", url: "https://api.test/data"))
        recorder.onCDPMessage("Network.responseReceived", .object([
            ("requestId", .string("r1")),
            ("response", .object([
                ("status", .number(200)),
                ("mimeType", .string("application/json")),
            ])),
        ]))
        recorder.onCDPMessage("Network.loadingFinished", .object([("requestId", .string("r1"))]))

        // The body fetch is dispatched to a detached Task; poll briefly for it.
        await waitFor(attempts: 200) { !sink.all.isEmpty }
        let records = sink.all
        await recorder.stop()

        #expect(records.count == 1)
        #expect(records.first?.type == "complete")
        #expect(records.first?.body == "{\"ok\":true}")
        #expect(records.first?.mimeType == "application/json")
        #expect(await transport.sentMethods().contains("Network.getResponseBody"))
    }
}

// MARK: - start / stop lifecycle

@Suite("NetworkRecorder lifecycle")
struct NetworkRecorderLifecycleTests {
    @Test func startEnablesNetworkDomainAndMarksRecording() async {
        let sink = RecordSink()
        let transport = StubCDPTransport()
        let recorder = NetworkRecorder(transport: transport) { sink.append($0) }
        #expect(!recorder.isRecording())
        await recorder.start()
        #expect(recorder.isRecording())
        #expect(await transport.sentMethods().contains("Network.enable"))
        await recorder.stop()
        #expect(!recorder.isRecording())
        #expect(await transport.sentMethods().contains("Network.disable"))
    }

    @Test func startFailureLeavesRecorderNotRecording() async {
        let sink = RecordSink()
        let transport = StubCDPTransport()
        await transport.setThrowingMethods(["Network.enable"])
        let recorder = NetworkRecorder(transport: transport) { sink.append($0) }
        await recorder.start()
        // Network.enable threw -> running was never set.
        #expect(!recorder.isRecording())
    }

    @Test func doubleStartEnablesOnlyOnce() async {
        let sink = RecordSink()
        let transport = StubCDPTransport()
        let recorder = NetworkRecorder(transport: transport) { sink.append($0) }
        await recorder.start()
        await recorder.start()
        let enableCount = await transport.sentMethods().filter { $0 == "Network.enable" }.count
        #expect(enableCount == 1)
        await recorder.stop()
    }

    @Test func stopWhenNotRecordingDoesNothing() async {
        let sink = RecordSink()
        let transport = StubCDPTransport()
        let recorder = NetworkRecorder(transport: transport) { sink.append($0) }
        await recorder.stop()
        #expect(await !transport.sentMethods().contains("Network.disable"))
    }
}

// MARK: - external detach handling

@Suite("NetworkRecorder external detach")
struct NetworkRecorderDetachTests {
    @Test func inspectorDetachedEventStopsRecording() async {
        let sink = RecordSink()
        let transport = StubCDPTransport()
        let recorder = NetworkRecorder(transport: transport) { sink.append($0) }
        await recorder.start()
        #expect(recorder.isRecording())
        await waitFor { await transport.hasSubscribed() }

        await transport.emit(CDPEvent(method: "Inspector.detached", params: .object([("reason", .string("target_closed"))])))

        await waitFor(attempts: 200) { !recorder.isRecording() }
        #expect(!recorder.isRecording())
        // An external detach must NOT try to disable Network over the dead
        // transport (only the start enable was sent).
        #expect(await !transport.sentMethods().contains("Network.disable"))
    }

    @Test func detachClearsPendingRequests() {
        let sink = RecordSink()
        let transport = StubCDPTransport()
        let recorder = NetworkRecorder(transport: transport) { sink.append($0) }
        // Seed a pending request, then mark running so handleDetached proceeds.
        recorder.setRunningForTesting(true)
        recorder.onCDPMessage("Network.requestWillBeSent", .object([
            ("requestId", .string("r1")),
            ("request", .object([("url", .string("https://x.test/a")), ("method", .string("GET"))])),
        ]))
        #expect(recorder.pendingRequestCountForTesting() == 1)
        recorder.handleDetached()
        #expect(!recorder.isRecording())
        #expect(recorder.pendingRequestCountForTesting() == 0)
    }

    @Test func detachWhenNotRecordingIsNoOp() {
        let sink = RecordSink()
        let transport = StubCDPTransport()
        let recorder = NetworkRecorder(transport: transport) { sink.append($0) }
        recorder.handleDetached()
        #expect(!recorder.isRecording())
    }

    @Test func eventStreamFinishingWhileRecordingStopsRecording() async {
        let sink = RecordSink()
        let transport = StubCDPTransport()
        let recorder = NetworkRecorder(transport: transport) { sink.append($0) }
        await recorder.start()
        #expect(recorder.isRecording())
        await waitFor { await transport.hasSubscribed() }

        await transport.finishEvents()

        await waitFor(attempts: 200) { !recorder.isRecording() }
        #expect(!recorder.isRecording())
    }
}
