import CryptoKit
import Foundation
import SwiftData

/// The backup format: one JSON file plus a folder of screenshot copies, named by content hash
/// so bookmarks from the same screenshot share one file.
struct BackupFile: Codable {
    var version = 1
    var createdAt: Date
    var bookmarks: [Record]
    /// Screenshots already sent to the AI, so a restored app doesn't pay for them again.
    var scannedKeys: [String]

    struct Record: Codable {
        var category: String
        var status: String
        var title: String
        var creator: String
        var year: String
        var summary: String
        var url: String
        var location: String
        var tags: [String]
        var notes: String
        var createdAt: Date
        var archivedAt: Date?
        var seenAgainCount: Int
        var lastSeenAgainAt: Date?
        var sourceHash: String
        var sourceAssetID: String
        var image: String?
        // Added later, so optional: backups made before them still load.
        var englishTitle: String?
        var englishCreator: String?
        var originalTitle: String?
        var originalCreator: String?
        var englishChecked: Bool?
        var englishVerified: Bool?
        var photoBox: String?
    }
}

enum BackupError: LocalizedError {
    case noFolder, noAccess, noBackup

    var errorDescription: String? {
        switch self {
        case .noFolder: "Choose a backup folder first."
        case .noAccess: "The app lost access to the backup folder. Choose it again."
        case .noBackup: "There's no Dragon Lair backup in this folder."
        }
    }
}

/// Backs up to a folder the user picks in Files (e.g. in iCloud Drive). Picking the folder
/// grants access, so this works without the paid-account iCloud entitlement.
@MainActor
enum Backup {
    static let fileName = "Dragon Lair backup.json"
    static let imagesFolder = "Dragon Lair images"
    /// Names from before the app was called Dragon Lair. Backups found under them are renamed.
    private static let oldFileName = "Endless Bookmark backup.json"
    private static let oldImagesFolder = "Endless Bookmark images"

    // MARK: Folder

    static var folderURL: URL? {
        guard let data = AppSettings.backupFolderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale { try? setFolder(url) }
        return url
    }

    /// The name Files shows, e.g. "On My iPhone" rather than the internal folder name.
    static var folderDisplayName: String? {
        guard let url = folderURL else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? url.lastPathComponent
    }

    static func setFolder(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw BackupError.noAccess }
        defer { url.stopAccessingSecurityScopedResource() }
        AppSettings.backupFolderBookmark = try url.bookmarkData()
    }

    private static func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url = folderURL else { throw BackupError.noFolder }
        guard url.startAccessingSecurityScopedResource() else { throw BackupError.noAccess }
        defer { url.stopAccessingSecurityScopedResource() }
        migrateOldNames(in: url)
        return try body(url)
    }

    /// Renames a backup made under the old names, unless one under the new names exists.
    private static func migrateOldNames(in folder: URL) {
        for (old, new) in [(oldFileName, fileName), (oldImagesFolder, imagesFolder)] {
            let from = folder.appendingPathComponent(old), to = folder.appendingPathComponent(new)
            let fm = FileManager.default
            guard fm.fileExists(atPath: from.path) || fm.fileExists(atPath: folder.appendingPathComponent(".\(old).icloud").path),
                  !fm.fileExists(atPath: to.path) else { continue }
            do { try coordinatedMove(from, to: to) } catch {
                AppSettings.lastBackupError = "Couldn't rename the old backup “\(old)”: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Writing

    /// Backs up if a folder is set, recording any error for the Backup screen instead of throwing.
    static func autoBackup(context: ModelContext) {
        guard AppSettings.backupFolderBookmark != nil else { return }
        do {
            try write(context: context)
        } catch {
            AppSettings.lastBackupError = error.localizedDescription
        }
    }

    static func write(context: ModelContext) throws {
        let bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
        let scanned = try context.fetch(FetchDescriptor<ScannedImage>()).map(\.key)

        try withFolder { folder in
            let images = folder.appendingPathComponent(imagesFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            var used = Set<String>()

            let records = try bookmarks.map { b -> BackupFile.Record in
                var name: String?
                if let data = b.screenshot {
                    let file = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".jpg"
                    name = file
                    if used.insert(file).inserted && !exists(file, in: images) {
                        try coordinatedWrite(data, to: images.appendingPathComponent(file))
                    }
                }
                return BackupFile.Record(
                    category: b.categoryRaw, status: b.status.rawValue, title: b.title, creator: b.creator,
                    year: b.year, summary: b.summary, url: b.url, location: b.location, tags: b.tags,
                    notes: b.notes, createdAt: b.createdAt, archivedAt: b.archivedAt,
                    seenAgainCount: b.seenAgainCount, lastSeenAgainAt: b.lastSeenAgainAt,
                    sourceHash: b.sourceHash, sourceAssetID: b.sourceAssetID, image: name,
                    englishTitle: b.englishTitle, englishCreator: b.englishCreator,
                    originalTitle: b.originalTitle, originalCreator: b.originalCreator,
                    englishChecked: b.englishChecked, englishVerified: b.englishVerified, photoBox: b.photoBox)
            }

            let backup = BackupFile(createdAt: .now, bookmarks: records, scannedKeys: scanned)
            try coordinatedWrite(encoder.encode(backup), to: folder.appendingPathComponent(fileName))
            pruneImages(in: images, keeping: used)
        }
        AppSettings.lastBackupAt = .now
        AppSettings.lastBackupError = nil
    }

    /// iCloud Drive shows files that aren't downloaded yet as ".name.icloud" placeholders.
    private static func exists(_ name: String, in folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent(name).path)
            || fm.fileExists(atPath: folder.appendingPathComponent(".\(name).icloud").path)
    }

    private static func pruneImages(in folder: URL, keeping used: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files {
            let name = file.hasPrefix(".") && file.hasSuffix(".icloud")
                ? String(file.dropFirst().dropLast(".icloud".count)) : file
            guard name.hasSuffix(".jpg"), !used.contains(name) else { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }

    // MARK: Restoring

    static func read() throws -> BackupFile {
        try withFolder { folder in
            let url = folder.appendingPathComponent(fileName)
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            guard exists(fileName, in: folder) else { throw BackupError.noBackup }
            return try decoder.decode(BackupFile.self, from: coordinatedRead(url))
        }
    }

    /// Adds bookmarks that aren't in the app yet. Ones already here are left exactly as they
    /// are, so restoring twice never creates duplicates. Like imports, a bookmark counts as here
    /// when its shown or original-language title matches either title of one in the app.
    static func restore(_ backup: BackupFile, context: ModelContext) throws -> (added: Int, kept: Int) {
        var known = Set(try context.fetch(FetchDescriptor<Bookmark>()).flatMap { b in
            [b.title, b.originalTitle].filter { !$0.isEmpty }.map { Bookmark.matchKey(category: b.category, title: $0) }
        })
        let scanned = Set(try context.fetch(FetchDescriptor<ScannedImage>()).map(\.key))
        var added = 0, kept = 0

        try withFolder { folder in
            let images = folder.appendingPathComponent(imagesFolder, isDirectory: true)
            for r in backup.bookmarks {
                let category = BookmarkCategory(rawValue: r.category) ?? .other
                let keys = [r.title, r.originalTitle ?? ""].filter { !$0.isEmpty }
                    .map { Bookmark.matchKey(category: category, title: $0) }
                guard known.isDisjoint(with: keys) else { kept += 1; continue }
                known.formUnion(keys)

                let screenshot = r.image.flatMap { name -> Data? in
                    let url = images.appendingPathComponent(name)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    return try? coordinatedRead(url)
                }
                let b = Bookmark(category: category, title: r.title, creator: r.creator, year: r.year,
                                 summary: r.summary, url: r.url, location: r.location, tags: r.tags,
                                 sourceHash: r.sourceHash, screenshot: screenshot)
                // Set raw fields directly so the original dates are kept.
                b.statusRaw = r.status
                b.archivedAt = r.archivedAt
                b.createdAt = r.createdAt
                b.notes = r.notes
                b.seenAgainCount = r.seenAgainCount
                b.lastSeenAgainAt = r.lastSeenAgainAt
                b.sourceAssetID = r.sourceAssetID
                b.englishTitle = r.englishTitle ?? ""
                b.englishCreator = r.englishCreator ?? ""
                b.originalTitle = r.originalTitle ?? ""
                b.originalCreator = r.originalCreator ?? ""
                b.englishChecked = r.englishChecked ?? false
                b.englishVerified = r.englishVerified ?? false
                b.photoBox = r.photoBox ?? ""
                context.insert(b)
                added += 1
            }
        }
        for key in backup.scannedKeys where !scanned.contains(key) {
            context.insert(ScannedImage(key: key))
        }
        try context.save()
        return (added, kept)
    }

    // MARK: File helpers

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // File coordination keeps iCloud Drive from syncing a half-written file, and makes reads
    // wait for files that are still downloading.
    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private static func coordinatedMove(_ from: URL, to: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: from, options: .forMoving,
                                       writingItemAt: to, options: .forReplacing, error: &coordinationError) { from, to in
            do { try FileManager.default.moveItem(at: from, to: to) } catch { moveError = error }
        }
        if let error = coordinationError ?? moveError { throw error }
    }

    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
