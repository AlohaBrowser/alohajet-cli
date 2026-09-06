import Foundation

// MARK: - Workflow value

/// A JSON-like value used for workflow step inputs/outputs and snapshot
/// persistence. Supports a deep clone (the snapshot equivalent of
/// `structuredClone`) and round-trips through `Codable`.
///
/// `nonisolated`: this is a pure, `Sendable` value type with no mutable state
/// (its only members are `Codable` round-tripping and an identity `deepClone`),
/// used as data currency freely across executors on every isolation. Under the
/// package's `defaultIsolation(MainActor.self)` an unannotated declaration would
/// be main-actor-isolated, which would make its `Equatable`/`Codable`
/// conformances unusable from nonisolated contexts (e.g. off-main tool backends
/// and their unit tests) — see the nonisolated value-type carve-out in the
/// isolation note at the bottom of `Package.swift`.
public nonisolated indirect enum WorkflowValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([WorkflowValue])
    case object([String: WorkflowValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WorkflowValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: WorkflowValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public func deepClone() -> WorkflowValue { self }
}
