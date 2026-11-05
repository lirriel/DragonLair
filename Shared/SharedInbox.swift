import Foundation

/// A folder in the App Group container where the share extension drops screenshots.
/// The main app picks them up and runs them through the import queue.
enum SharedInbox {
    static let appGroup = "group.com.lirriel.endlessbookmark"

    static var folder: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        let url = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func add(_ data: Data) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        // Timestamp prefix keeps files in the order they were shared.
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).img"
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    static func pending() -> [URL] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "img" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
