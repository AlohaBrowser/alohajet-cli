import Testing
import Foundation
@testable import CDP
import ToolABI

/// The CDP wire log records every outbound command. A text-entry command carries
/// what is being typed — a password, a one-time code, a form answer — so its logged
/// copy must keep the command's shape while dropping every field that spells the text.
@Suite struct CDPWireLogRedactionTests {

    private func payload(
        _ method: String,
        _ params: [(String, JSValue)],
        sessionId: String? = nil
    ) -> String {
        var message: [(String, JSValue)] = [("id", .number(7)), ("method", .string(method))]
        if let sessionId { message.append(("sessionId", .string(sessionId))) }
        message.append(("params", .object(params)))
        return JSValue.object(message).stringify()
    }

    @Test("a key event keeps its shape and loses every field that names the character")
    func keyEventKeepsShapeAndLosesTheCharacter() throws {
        let logged = CDPClient.payloadForWireLog(
            method: "Input.dispatchKeyEvent",
            payload: payload("Input.dispatchKeyEvent", [
                ("type", .string("keyDown")),
                ("key", .string("Q")),
                ("code", .string("KeyQ")),
                ("text", .string("Q")),
                ("unmodifiedText", .string("Q")),
                ("keyIdentifier", .string("U+0051")),
                ("windowsVirtualKeyCode", .number(81)),
                ("nativeVirtualKeyCode", .number(81)),
                ("modifiers", .number(8)),
                ("autoRepeat", .bool(false)),
                ("location", .number(0)),
            ], sessionId: "S1"))

        #expect(!logged.contains("Q"))
        #expect(!logged.contains("81"))
        #expect(!logged.contains("0051"))

        let message = try #require(JSValue.parse(logged))
        #expect(message["id"] == .number(7))
        #expect(message["method"] == .string("Input.dispatchKeyEvent"))
        #expect(message["sessionId"] == .string("S1"))

        let params = try #require(message["params"])
        #expect(params["type"] == .string("keyDown"))
        #expect(params["modifiers"] == .number(8))
        #expect(params["autoRepeat"] == .bool(false))
        #expect(params["location"] == .number(0))
        #expect(params["key"] == .string("[redacted 1 chars]"))
        #expect(params["text"] == .string("[redacted 1 chars]"))
        #expect(params["unmodifiedText"] == .string("[redacted 1 chars]"))
        #expect(params["code"] == .string("[redacted 4 chars]"))
        #expect(params["keyIdentifier"] == .string("[redacted 6 chars]"))
        #expect(params["windowsVirtualKeyCode"] == .string("[redacted]"))
        #expect(params["nativeVirtualKeyCode"] == .string("[redacted]"))
    }

    @Test("inserted text is logged as its length only")
    func insertedTextIsLoggedAsItsLength() throws {
        let secret = "hunter2 пароль"
        let logged = CDPClient.payloadForWireLog(
            method: "Input.insertText",
            payload: payload("Input.insertText", [("text", .string(secret))]))

        #expect(!logged.contains("hunter2"))
        #expect(!logged.contains("пароль"))
        let params = try #require(JSValue.parse(logged)?["params"])
        #expect(params["text"] == .string("[redacted \(secret.count) chars]"))
    }

    @Test("composition text is logged as its length only")
    func compositionTextIsLoggedAsItsLength() throws {
        let logged = CDPClient.payloadForWireLog(
            method: "Input.imeSetComposition",
            payload: payload("Input.imeSetComposition", [
                ("text", .string("かな")),
                ("selectionStart", .number(2)),
                ("selectionEnd", .number(2)),
            ]))

        #expect(!logged.contains("かな"))
        let params = try #require(JSValue.parse(logged)?["params"])
        #expect(params["text"] == .string("[redacted 2 chars]"))
    }

    @Test("an editing command a key event carries stays readable")
    func editingCommandsStayReadable() throws {
        let logged = CDPClient.payloadForWireLog(
            method: "Input.dispatchKeyEvent",
            payload: payload("Input.dispatchKeyEvent", [
                ("type", .string("keyDown")),
                ("commands", .array([.string("selectAll")])),
            ]))

        let params = try #require(JSValue.parse(logged)?["params"])
        #expect(params["commands"] == .array([.string("selectAll")]))
    }

    @Test("a repeated text field is redacted every time it appears")
    func repeatedFieldsAreAllRedacted() {
        let raw = #"{"id":1,"method":"Input.insertText","params":{"text":"first","text":"second"}}"#
        let logged = CDPClient.payloadForWireLog(method: "Input.insertText", payload: raw)

        #expect(!logged.contains("first"))
        #expect(!logged.contains("second"))
    }

    @Test("a text-entry payload that does not parse is withheld whole")
    func unparseableTextEntryPayloadIsWithheld() {
        for raw in [#"{"params":{"text":"secret""#, #"["secret"]"#] {
            let logged = CDPClient.payloadForWireLog(method: "Input.insertText", payload: raw)
            #expect(logged == "[payload redacted]")
        }
    }

    @Test("a text-entry params value that is not an object is withheld whole")
    func nonObjectParamsAreWithheld() {
        let raw = #"{"id":1,"method":"Input.insertText","params":"secret"}"#
        let logged = CDPClient.payloadForWireLog(method: "Input.insertText", payload: raw)

        #expect(!logged.contains("secret"))
        #expect(JSValue.parse(logged)?["params"] == .string("[redacted]"))
    }

    @Test("every other command keeps the existing bounded diagnostic")
    func otherCommandsKeepTheBoundedDiagnostic() {
        let short = payload("Runtime.evaluate", [("expression", .string("document.title"))])
        #expect(CDPClient.payloadForWireLog(method: "Runtime.evaluate", payload: short) == short)

        let long = payload("Runtime.evaluate", [("expression", .string(String(repeating: "x", count: 900)))])
        let logged = CDPClient.payloadForWireLog(method: "Runtime.evaluate", payload: long)
        #expect(logged == truncateString(long, limit: 800))
        #expect(logged.count < long.count)
    }

    actor RecordingChannel: CDPMessageChannel {
        private(set) var sent: [String] = []
        private var inbox: [String] = []
        private var waiter: CheckedContinuation<String, Error>?
        private var closed = false

        func open() async {}

        func send(_ text: String) async throws {
            sent.append(text)
            guard let id = JSValue.parse(text)?["id"]?.intValue else { return }
            deliver(JSValue.object([("id", .number(Double(id))), ("result", .object([]))]).stringify())
        }

        func receive() async throws -> String {
            if !inbox.isEmpty { return inbox.removeFirst() }
            if closed { throw CDPError.connectionClosed }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }

        func close() async {
            closed = true
            let pending = waiter
            waiter = nil
            pending?.resume(throwing: CDPError.connectionClosed)
        }

        private func deliver(_ frame: String) {
            if let pending = waiter {
                waiter = nil
                pending.resume(returning: frame)
            } else {
                inbox.append(frame)
            }
        }
    }

    actor WireLogLines {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
    }

    @Test("the line the client writes for a typed command names the command and not the text")
    func theWrittenWireLogLineCarriesNoTypedText() async throws {
        let log = WireLogLines()
        let client = CDPClient(
            channel: RecordingChannel(), callTimeout: 10, wireLog: { await log.append($0) })
        try await client.connect()

        _ = try await client.send(
            method: "Input.dispatchKeyEvent",
            params: ["type": .string("keyDown"), "key": .string("Q"), "text": .string("Q")],
            sessionId: "S1")
        _ = try await client.send(method: "Input.insertText", params: ["text": .string("hunter2")])
        await client.close()

        let lines = await log.lines
        let outbound = lines.filter { $0.hasPrefix("[CDP] → ") }
        #expect(outbound.count == 2)
        #expect(outbound.first?.hasPrefix("[CDP] → Input.dispatchKeyEvent id=") == true)
        #expect(outbound.last?.hasPrefix("[CDP] → Input.insertText id=") == true)
        #expect(!lines.contains { $0.contains("hunter2") || $0.contains("\"Q\"") })
    }

    @Test("the browser still receives the typed text verbatim")
    func browserReceivesTheTypedText() async throws {
        let channel = RecordingChannel()
        let client = CDPClient(channel: channel, callTimeout: 10)
        try await client.connect()

        _ = try await client.send(
            method: "Input.dispatchKeyEvent",
            params: ["type": .string("keyDown"), "key": .string("Q"), "text": .string("Q")],
            sessionId: "S1")
        _ = try await client.send(method: "Input.insertText", params: ["text": .string("hunter2")])
        await client.close()

        let sent = await channel.sent.compactMap { JSValue.parse($0) }
        #expect(sent.count == 2)
        #expect(sent.first?["sessionId"] == .string("S1"))
        #expect(sent.first?["params"]?["key"] == .string("Q"))
        #expect(sent.first?["params"]?["text"] == .string("Q"))
        #expect(sent.last?["params"]?["text"] == .string("hunter2"))
    }
}
