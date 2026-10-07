import Foundation

// TEMPORARY — branch `tab-attribution-trace` only, never merged. One line per event in
// the life of a tab (how it enters the tabs model, what each listing does to it, what
// the load wait writes, what the tab summary sends), appended to
// ~/.alohajet/logs/tabs-trace.log so a manual run can be read step by step.

public nonisolated func tabsTrace(_ message: String) {
    TabsTrace.append("\(TabsTrace.stamp()) \(message)\n")
}

nonisolated enum TabsTrace {
    static let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".alohajet/logs/tabs-trace.log")
    private static let lock = NSLock()

    static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data(line.utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
