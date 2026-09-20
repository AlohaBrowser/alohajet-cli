import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// `docs/tools.md` is GENERATED from `Schemas.swift`, and this is the generator.
//
// A hand-written tool reference drifts the first time a description is edited, and the
// drift is invisible: nothing compiles the docs. So the renderer below is the only thing
// that writes that file, and this test fails when the checked-in copy no longer matches
// what the schemas say. To regenerate after changing a schema:
//
//     ALOHAJET_REGEN_DOCS=1 swift test --filter ToolsDoc
//
// KNOWN CEILING: a golden-file test, not a build plugin. It runs in the suite that already
// has to pass, and it needs no new target.

@Suite("ToolsDoc") struct ToolsDocTests {
    @Test func checkedInDocMatchesTheSchemas() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BrowserToolsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("docs/tools.md")

        let rendered = renderToolsDoc()

        if ProcessInfo.processInfo.environment["ALOHAJET_REGEN_DOCS"] == "1" {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rendered.write(to: path, atomically: true, encoding: .utf8)
            return
        }

        let onDisk = try? String(contentsOf: path, encoding: .utf8)
        #expect(onDisk == rendered, """
            docs/tools.md is out of date with Sources/BrowserTools/Tools/Schemas.swift.
            Regenerate it: ALOHAJET_REGEN_DOCS=1 swift test --filter ToolsDoc
            """)
    }
}

// MARK: - The renderer

/// `<select>` / `<input>` in a schema description are literal text, but a markdown
/// renderer reads them as raw HTML tags and shows nothing. Escape them so the page says
/// what the model was told.
private func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

/// One markdown cell: no raw pipe (it would split the cell) and no raw newline.
private func cell(_ text: String) -> String {
    escaped(text)
        .replacingOccurrences(of: "|", with: "\\|")
        .replacingOccurrences(of: "\n", with: " ")
}

/// `"a", "b"` from `["a", "b"]`.
private func quotedList(_ values: [JSValue]) -> String {
    values.compactMap { if case let .string(s) = $0 { return "`\(s)`" } else { return nil } }
        .joined(separator: ", ")
}

/// A JSON-ish rendering of a default value.
private func literal(_ value: JSValue) -> String {
    switch value {
    case .string(let s): return "`\"\(s)\"`"
    case .bool(let b): return "`\(b)`"
    case .number(let n):
        return n == n.rounded() && abs(n) < 1e15
            ? "`\(String(Int(n)))`" : "`\(String(n))`"
    default: return "`\(value.stringify())`"
    }
}

/// The type column: `string`, `integer`, or `array of objects` for a typed array.
private func typeLabel(_ schema: JSValue) -> String {
    let base = schema.string("type") ?? "any"
    guard base == "array", let items = schema["items"], let itemType = items.string("type") else {
        return "`\(base)`"
    }
    return "`array` of `\(itemType)`"
}

/// Everything a JSON-Schema property says beyond its type and prose: the enum, the
/// default, the bounds. These used to live only in prose, where a validating client
/// could not see them.
private func constraints(_ schema: JSValue) -> String {
    var parts: [String] = []
    if let values = schema.array("enum") { parts.append("one of \(quotedList(values))") }
    if let value = schema["default"] { parts.append("default \(literal(value))") }
    if let minimum = schema.number("minimum") { parts.append("min \(Int(minimum))") }
    if let maximum = schema.number("maximum") { parts.append("max \(Int(maximum))") }
    if let minItems = schema.number("minItems") { parts.append("min \(Int(minItems)) item(s)") }
    if let maxItems = schema.number("maxItems") { parts.append("max \(Int(maxItems)) items") }
    return parts.joined(separator: ", ")
}

private func propertyRows(_ properties: [(String, JSValue)], required: Set<String>, indent: String = "") -> [String] {
    var rows: [String] = []
    for (name, schema) in properties {
        let notes = [schema.string("description") ?? "", constraints(schema)]
            .filter { !$0.isEmpty }.joined(separator: " ")
        rows.append("| \(indent)`\(name)` | \(typeLabel(schema)) | "
            + "\(required.contains(name) ? "yes" : "no") | \(cell(notes)) |")
        // One level of nesting, which is all any of these schemas has: `page_type.fields`.
        if let items = schema["items"], let nested = items.object("properties") {
            let nestedRequired = Set(items.array("required")?.compactMap(\.stringValue) ?? [])
            rows.append(contentsOf: propertyRows(nested, required: nestedRequired, indent: "↳ "))
        }
    }
    return rows
}

func renderToolsDoc() -> String {
    var out = """
        # Tool reference

        <!-- GENERATED FILE — do not edit by hand.
             Source: Sources/BrowserTools/Tools/Schemas.swift
             Regenerate: ALOHAJET_REGEN_DOCS=1 swift test --filter ToolsDoc -->

        The tools alohajet exposes, rendered from the package's own schema registry,
        so this page cannot drift from what the MCP server actually advertises. Descriptions
        below are the exact text the model is given.

        Every tool acts on **the tab in use** — the one `manage_tabs open` or `manage_tabs use`
        last selected. Elements are addressed by `aloha-id`, the stable ref a `manage_tabs read`
        prints next to each actionable element; see [Stable element refs](../README.md#stable-element-refs).

        | tool | reads or writes |
        | --- | --- |

        """
    let schemas = getNativeAgentToolSchemas()
    for schema in schemas {
        let readOnly = nativeAgentToolReadOnlyHints[schema.name] ?? false
        out += "| [`\(schema.name)`](#\(schema.name)) | "
            + (readOnly ? "read-only" : "drives the page") + " |\n"
    }

    for schema in schemas {
        let readOnly = nativeAgentToolReadOnlyHints[schema.name] ?? false
        out += "\n---\n\n## \(schema.name)\n\n"
        out += "`readOnlyHint: \(readOnly)` · `destructiveHint: \(!readOnly)` · `openWorldHint: true`\n\n"
        if let description = schema.description {
            out += escaped(description) + "\n\n"
        }
        guard let input = schema.inputSchema, let properties = input.object("properties"),
              !properties.isEmpty else {
            out += "Takes no arguments.\n"
            continue
        }
        let required = Set(input.array("required")?.compactMap(\.stringValue) ?? [])
        out += "| parameter | type | required | notes |\n| --- | --- | --- | --- |\n"
        out += propertyRows(properties, required: required).joined(separator: "\n") + "\n"
    }
    return out
}
