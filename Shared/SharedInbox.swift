import Foundation

/// A folder in the App Group container where the share extension drops screenshots.
/// The main app picks them up and runs them through the import queue.
enum SharedInbox {
    // The library and the share inbox live in this group's folder.
    static let appGroup = "group.\(AppID.base)"

    static var folder: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        let url = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// For apps that share an image only as data, not as a file.
    static func add(_ data: Data) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).img"
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// Copies a shared image file into the inbox without loading it into memory, which keeps
    /// the share extension inside its tight memory limit even for 50 large photos.
    static func add(fileAt source: URL) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        // Timestamp prefix keeps files in the order they were shared. Copied under a temporary
        // name first, so the app never picks up a half-written file.
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        let partial = folder.appendingPathComponent(name + ".partial")
        try FileManager.default.copyItem(at: source, to: partial)
        try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent(name + ".img"))
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
