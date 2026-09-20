import Foundation
import ToolABI

/// `nil` when the value is not an object or lacks a bounding box.
public func decodeElementSnapshot(_ value: JSValue?) -> ElementSnapshot? {
    guard let value, case .object = value else { return nil }
    guard let bboxValue = value["bbox"], case .object = bboxValue else { return nil }
    let bbox = ElementBBox(
        x: bboxValue["x"]?.doubleValue ?? 0,
        y: bboxValue["y"]?.doubleValue ?? 0,
        width: bboxValue["width"]?.doubleValue ?? 0,
        height: bboxValue["height"]?.doubleValue ?? 0
    )
    var snapshot = ElementSnapshot(
        label: value["label"]?.stringValue ?? "",
        role: value["role"]?.stringValue ?? "",
        tagName: value["tagName"]?.stringValue ?? "",
        bbox: bbox
    )
    snapshot.htmlId = value["htmlId"]?.stringValue
    snapshot.name = value["name"]?.stringValue
    snapshot.inViewport = value["inViewport"]?.boolValue
    snapshot.ariaLabel = value["ariaLabel"]?.stringValue
    snapshot.title = value["title"]?.stringValue
    snapshot.innerText = value["innerText"]?.stringValue
    snapshot.altText = value["altText"]?.stringValue
    snapshot.inputType = value["inputType"]?.stringValue
    snapshot.autocomplete = value["autocomplete"]?.stringValue
    snapshot.placeholder = value["placeholder"]?.stringValue
    snapshot.disabled = value["disabled"]?.boolValue
    snapshot.required = value["required"]?.boolValue
    snapshot.checked = value["checked"]?.boolValue
    snapshot.href = value["href"]?.stringValue
    snapshot.pageUrl = value["pageUrl"]?.stringValue
    snapshot.pageTitle = value["pageTitle"]?.stringValue
    snapshot.frameUrl = value["frameUrl"]?.stringValue
    return snapshot
}
