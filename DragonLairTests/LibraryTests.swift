import Foundation
import SwiftData
import Testing
@testable import DragonLair

/// A library that lives only in memory, so tests never touch the app's real one.
@MainActor
struct TestLibrary {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, groupContainer: .none)
        container = try ModelContainer(for: Schema(versionedSchema: LibrarySchemaV1.self), configurations: configuration)
    }

    var bookmarks: [Bookmark] {
        (try? context.fetch(FetchDescriptor<Bookmark>(sortBy: [SortDescriptor(\.title)]))) ?? []
    }

    @discardableResult
    func add(_ title: String, category: BookmarkCategory = .book, original: String = "",
             status: BookmarkStatus = .saved) -> Bookmark {
        let bookmark = Bookmark(category: category, title: title)
        bookmark.originalTitle = original
        bookmark.status = status
        context.insert(bookmark)
        return bookmark
    }
}

func item(_ title: String, category: String = "book", english: String = "", creator: String = "",
          summary: String = "", tags: [String] = []) -> ExtractedItem {
    ExtractedItem(category: category, title: title, creator: creator, year: "", summary: summary, url: "",
                  location: "", tags: tags, englishTitle: english, englishCreator: "", photoBox: "")
}

// MARK: Importing

@Suite("Adding what a screenshot shows")
@MainActor
struct ImportMergeTests {
    @Test func newItemsAreAdded() throws {
        let library = try TestLibrary()
        let result = try ImportMerge.merge([item("Dune", creator: "Frank Herbert", tags: ["Sci-Fi"])],
                                           hash: "abc", screenshot: Data([1]), assetID: "asset-1",
                                           context: library.context)
        #expect(result == .init(added: 1, notes: []))
        let dune = try #require(library.bookmarks.first)
        #expect(dune.creator == "Frank Herbert")
        #expect(dune.tags == ["sci-fi"])
        #expect(dune.sourceHash == "abc")
        #expect(dune.sourceAssetID == "asset-1")
        #expect(dune.screenshot == Data([1]))
    }

    @Test("Something already saved is counted as seen again, not added")
    func duplicatesAreNotAdded() throws {
        let library = try TestLibrary()
        let saved = library.add("Café Kitsuné", category: .place)
        let result = try ImportMerge.merge([item("cafe kitsune", category: "place")], hash: "", screenshot: nil,
                                           assetID: nil, context: library.context)
        #expect(result.added == 0)
        #expect(result.notes.count == 1)
        #expect(saved.seenAgainCount == 1)
        #expect(saved.lastSeenAgainAt != nil)
        #expect(library.bookmarks.count == 1)
    }

    @Test("Archived bookmarks are recognised too")
    func archivedBookmarksMatch() throws {
        let library = try TestLibrary()
        library.add("Dune", status: .dropped)
        let result = try ImportMerge.merge([item("Dune")], hash: "", screenshot: nil, assetID: nil, context: library.context)
        #expect(result.added == 0)
        #expect(result.notes.first?.contains("archived") == true)
    }

    @Test("A screenshot in the original language matches a bookmark shown in English")
    func originalLanguageMatches() throws {
        let library = try TestLibrary()
        library.add("Solo Leveling", category: .manhwa, original: "나 혼자만 레벨업")
        let result = try ImportMerge.merge([item("나 혼자만 레벨업", category: "manhwa")], hash: "", screenshot: nil,
                                           assetID: nil, context: library.context)
        #expect(result.added == 0)
    }

    @Test("An English title from the AI matches a bookmark saved in English")
    func englishTitleMatches() throws {
        let library = try TestLibrary()
        library.add("Solo Leveling", category: .manhwa)
        let result = try ImportMerge.merge([item("나 혼자만 레벨업", category: "manhwa", english: "Solo Leveling")],
                                           hash: "", screenshot: nil, assetID: nil, context: library.context)
        #expect(result.added == 0)
    }

    @Test("The same thing twice on one screenshot is added once")
    func repeatsOnOneScreenshot() throws {
        let library = try TestLibrary()
        let result = try ImportMerge.merge([item("Dune"), item("DUNE")], hash: "", screenshot: nil, assetID: nil,
                                           context: library.context)
        #expect(result.added == 1)
        #expect(result.notes.count == 1)
    }

    @Test("The same title in another category is a different bookmark")
    func otherCategoriesAreSeparate() throws {
        let library = try TestLibrary()
        library.add("Dune")
        let result = try ImportMerge.merge([item("Dune", category: "movie")], hash: "", screenshot: nil, assetID: nil,
                                           context: library.context)
        #expect(result.added == 1)
    }

    @Test("Titles in another script are shown in English, keeping the original")
    func englishNamesAreShown() throws {
        let library = try TestLibrary()
        _ = try ImportMerge.merge([item("나 혼자만 레벨업", category: "manhwa", english: "Solo Leveling")],
                                  hash: "", screenshot: nil, assetID: nil, context: library.context)
        let bookmark = try #require(library.bookmarks.first)
        #expect(bookmark.title == "Solo Leveling")
        #expect(bookmark.originalTitle == "나 혼자만 레벨업")
    }

    @Test("Unnamed finds in the same category are kept apart, across screenshots too")
    func unnamedFindsAreSeparate() throws {
        let library = try TestLibrary()
        let first = try ImportMerge.merge([item("", summary: "A book with a red cover")], hash: "a", screenshot: nil,
                                          assetID: nil, context: library.context)
        let second = try ImportMerge.merge([item(" ", summary: "Another book"), item("", summary: "And a third")],
                                           hash: "b", screenshot: nil, assetID: nil, context: library.context)
        #expect(first.added == 1 && second.added == 2)
        let titles = library.bookmarks.map(\.title)
        #expect(titles.allSatisfy { $0.hasPrefix("Unnamed book, ") })
        // Distinct titles also keep them apart when a backup is restored.
        let keys = library.bookmarks.map { Bookmark.matchKey(category: $0.category, title: $0.title) }
        #expect(Set(keys).count == 3)
    }

    @Test("A movie with no title is called a movie or show")
    func unnamedMovie() throws {
        let library = try TestLibrary()
        _ = try ImportMerge.merge([item("", category: "movie", creator: "Someone")], hash: "", screenshot: nil,
                                  assetID: nil, context: library.context)
        #expect(library.bookmarks.first?.title.hasPrefix("Unnamed movie or show, ") == true)
    }

    @Test("Items with nothing at all are dropped; a place with only an address is kept")
    func emptyItems() throws {
        let library = try TestLibrary()
        var place = item("", category: "place")
        place.location = "Kyoto, Japan"
        let result = try ImportMerge.merge([item(""), item("  "), place], hash: "", screenshot: nil, assetID: nil,
                                           context: library.context)
        #expect(result.added == 1)
        #expect(library.bookmarks.first?.location == "Kyoto, Japan")
    }

    @Test("Titles made only of symbols aren't all taken for the same thing")
    func symbolTitles() throws {
        let library = try TestLibrary()
        let first = try ImportMerge.merge([item("★★★"), item("☆☆☆")], hash: "", screenshot: nil, assetID: nil,
                                          context: library.context)
        let again = try ImportMerge.merge([item("★★★")], hash: "", screenshot: nil, assetID: nil, context: library.context)
        #expect(first.added == 2)
        #expect(again.added == 0 && again.notes.count == 1)
    }
}

// MARK: Never paying twice

@Suite("Skipping screenshots read before")
@MainActor
struct SkipTests {
    private func readBefore(_ library: TestLibrary, _ hash: String) {
        library.context.insert(ScannedImage(key: "hash:\(hash)"))
    }

    @Test func newScreenshotsAreRead() throws {
        let library = try TestLibrary()
        for automatic in [true, false] {
            #expect(!ImportMerge.canSkip(hash: "new", isAutomatic: automatic, forceRead: false, context: library.context))
        }
    }

    @Test("Watching and period imports skip anything read before")
    func automaticImportsSkip() throws {
        let library = try TestLibrary()
        readBefore(library, "abc")
        #expect(ImportMerge.canSkip(hash: "abc", isAutomatic: true, forceRead: false, context: library.context))
    }

    @Test("A screenshot picked or shared again is read again when nothing from it is saved")
    func pickedAgainIsRead() throws {
        let library = try TestLibrary()
        readBefore(library, "abc")
        #expect(!ImportMerge.canSkip(hash: "abc", isAutomatic: false, forceRead: false, context: library.context))
    }

    @Test("“Read again” reads it even from watching")
    func readAgain() throws {
        let library = try TestLibrary()
        readBefore(library, "abc")
        #expect(!ImportMerge.canSkip(hash: "abc", isAutomatic: true, forceRead: true, context: library.context))
    }

    @Test("A screenshot with a saved bookmark is always skipped")
    func savedScreenshotsSkip() throws {
        let library = try TestLibrary()
        library.add("Dune").sourceHash = "abc"
        for automatic in [true, false] {
            #expect(ImportMerge.canSkip(hash: "abc", isAutomatic: automatic, forceRead: false, context: library.context))
        }
    }

    @Test("Deleting a wrong import keeps its screenshot marked as read")
    func deletedImports() throws {
        let library = try TestLibrary()
        let wrong = library.add("Wrong title")
        wrong.sourceHash = "abc"
        readBefore(library, "abc")
        wrong.delete()
        #expect(library.bookmarks.isEmpty)
        #expect(try library.context.fetchCount(FetchDescriptor<ScannedImage>()) == 1)
        // Watching doesn't bring it back; picking it again gives it another try.
        #expect(ImportMerge.canSkip(hash: "abc", isAutomatic: true, forceRead: false, context: library.context))
        #expect(!ImportMerge.canSkip(hash: "abc", isAutomatic: false, forceRead: false, context: library.context))
    }
}

// MARK: Import results

@Suite("After a screenshot is processed")
struct CleanupTests {
    private let shared = URL(fileURLWithPath: "/tmp/inbox/1-a.img")

    @Test("A failed import keeps the screenshot to try again")
    func failuresAreKept() {
        for source: ImportQueue.Job.Source in [.inbox(shared), .asset("photo-1")] {
            #expect(ImportQueue.cleanup(after: .failed("Offline"), of: source) == .keep)
        }
    }

    @Test("A shared file is removed from the inbox once it's handled", arguments: [
        ImportQueue.Job.State.done(added: 1, notes: []), .skipped, .nothingFound,
    ])
    func sharedFilesAreRemoved(_ state: ImportQueue.Job.State) {
        #expect(ImportQueue.cleanup(after: state, of: .inbox(shared)) == .removeSharedFile(shared))
    }

    @Test("A screenshot from Photos is marked as handled, so watching doesn't offer it again", arguments: [
        ImportQueue.Job.State.done(added: 0, notes: ["Already saved"]), .skipped, .nothingFound,
    ])
    func photosAreMarked(_ state: ImportQueue.Job.State) {
        #expect(ImportQueue.cleanup(after: state, of: .asset("photo-1")) == .markScanned("asset:photo-1"))
    }
}

@Suite("Deleting original screenshots")
struct DeleteOriginalsTests {
    @Test("Allowed only once the screenshot's contents are saved", arguments: [
        (ImportQueue.Job.State.done(added: 1, notes: []), true),
        (.done(added: 0, notes: ["“Dune” is already in your list."]), true),
        (.skipped, true),
        (.done(added: 0, notes: []), false),
        (.nothingFound, false),
        (.failed("Offline"), false),
        (.waiting, false),
        (.working, false),
    ])
    func onlyWhenSaved(_ state: ImportQueue.Job.State, _ allowed: Bool) {
        #expect(ImportQueue.Job(source: .asset("photo-1"), state: state).originalCanBeDeleted == allowed)
    }

    @Test func notTwice() {
        let job = ImportQueue.Job(source: .asset("photo-1"), state: .skipped, originalDeleted: true)
        #expect(!job.originalCanBeDeleted)
    }

    @Test("Shared files aren't in Photos, so there's nothing to delete")
    func sharedFiles() {
        let job = ImportQueue.Job(source: .inbox(URL(fileURLWithPath: "/tmp/1-a.img")), state: .done(added: 1, notes: []))
        #expect(!job.originalCanBeDeleted)
    }
}

// MARK: Share extension handoff

@Suite("Shared screenshot inbox")
struct InboxTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Only finished files are picked up, oldest first")
    func pending() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["2000-b.img", "1000-a.img", "3000-c.partial", "notes.txt"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        #expect(SharedInbox.pending(in: folder).map(\.lastPathComponent) == ["1000-a.img", "2000-b.img"])
    }

    @Test("A shared file is copied in whole and never left half-written")
    func copying() throws {
        let folder = try temporaryFolder()
        let source = try temporaryFolder().appendingPathComponent("photo.heic")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
        }
        let contents = Data((0..<100_000).map { UInt8($0 % 251) })
        try contents.write(to: source)
        try SharedInbox.add(fileAt: source, to: folder)
        try SharedInbox.add(contents, to: folder)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.hasSuffix(".img") })
        #expect(try SharedInbox.pending(in: folder).allSatisfy { try Data(contentsOf: $0) == contents })
        // The original stays where the sharing app keeps it.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func noFolder() {
        #expect(SharedInbox.pending(in: nil).isEmpty)
        #expect(throws: (any Error).self) { try SharedInbox.add(Data([1]), to: nil) }
    }
}

// MARK: Tracker

@Suite("Tracker status")
@MainActor
struct StatusTests {
    @Test("Statuses saved under older names still read correctly", arguments: [
        ("inProgress", BookmarkStatus.started), ("done", .started), ("started", .started),
        ("dropped", .dropped), ("saved", .saved), ("something new", .saved),
    ])
    func olderNames(_ raw: String, _ expected: BookmarkStatus) {
        let bookmark = Bookmark(category: .book, title: "Dune")
        bookmark.statusRaw = raw
        #expect(bookmark.status == expected)
    }

    @Test("Archiving records when; bringing back clears it")
    func archiving() {
        let bookmark = Bookmark(category: .book, title: "Dune")
        bookmark.status = .dropped
        let archivedAt = bookmark.archivedAt
        #expect(archivedAt != nil)
        bookmark.status = .dropped
        #expect(bookmark.archivedAt == archivedAt)
        bookmark.status = .saved
        #expect(bookmark.archivedAt == nil)
    }

    @Test("A bookmark backed up as “done” is restored as started and archived")
    func olderNamesInBackups() throws {
        let library = try TestLibrary()
        let record = BackupFile.Record(
            category: "book", status: "done", title: "Dune", creator: "", year: "", summary: "", url: "", location: "",
            tags: [], notes: "", createdAt: .now, archivedAt: .now, seenAgainCount: 0, lastSeenAgainAt: nil,
            sourceHash: "", sourceAssetID: "", image: nil)
        _ = try Backup.restore(BackupFile(createdAt: .now, bookmarks: [record], scannedKeys: []),
                               context: library.context) { _ in nil }
        let dune = try #require(library.bookmarks.first)
        #expect(dune.status == .started)
        #expect(dune.status.isArchived)
    }
}

// MARK: English names

@Suite("Showing English names")
@MainActor
struct EnglishNameTests {
    private func bookmark(_ title: String, creator: String = "", english: String, englishCreator: String = "") -> Bookmark {
        let bookmark = Bookmark(category: .manhwa, title: title, creator: creator)
        bookmark.englishTitle = english
        bookmark.englishCreator = englishCreator
        bookmark.preferEnglishNames()
        return bookmark
    }

    @Test("Korean, Japanese and Chinese titles are shown in English, keeping the original", arguments: [
        "나 혼자만 레벨업", "進撃の巨人", "天官赐福",
    ])
    func otherScripts(_ title: String) {
        let b = bookmark(title, creator: "작가", english: "English Title", englishCreator: "Author")
        #expect(b.title == "English Title" && b.originalTitle == title)
        #expect(b.creator == "Author" && b.originalCreator == "작가")
    }

    @Test("Russian and accented Latin titles stay as written", arguments: ["Ведьмак", "Café Kitsuné", "Straße"])
    func staysAsWritten(_ title: String) {
        let b = bookmark(title, english: "English Title")
        #expect(b.title == title && b.originalTitle.isEmpty)
    }

    @Test("Without an English name nothing changes, and a missing English author keeps the original")
    func partialNames() {
        #expect(bookmark("나 혼자만 레벨업", english: "").title == "나 혼자만 레벨업")
        let b = bookmark("나 혼자만 레벨업", creator: "추공", english: "Solo Leveling")
        #expect(b.creator == "추공")
    }

    @Test func safeToRepeat() {
        let b = bookmark("나 혼자만 레벨업", english: "Solo Leveling")
        b.preferEnglishNames()
        #expect(b.title == "Solo Leveling" && b.originalTitle == "나 혼자만 레벨업")
    }
}

// MARK: Covers

@Suite("When covers are searched again")
@MainActor
struct CoverRetryTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func searched(_ library: TestLibrary, _ title: String, cover: Bool = false, creator: String = "Someone",
                          daysAgo: Double = 0) -> Bookmark {
        let bookmark = library.add(title)
        bookmark.creator = creator
        bookmark.cover = cover ? Data([1]) : nil
        bookmark.coverLookedUp = true
        bookmark.coverLookedUpAt = now.addingTimeInterval(-daysAgo * 24 * 3600)
        return bookmark
    }

    @Test("A missing cover is tried again after a week")
    func weeklyRetry() throws {
        let library = try TestLibrary()
        let old = searched(library, "Old", daysAgo: 8)
        let recent = searched(library, "Recent", daysAgo: 2)
        let found = searched(library, "Found", cover: true, daysAgo: 30)
        CoverFinder.markForRetry(library.bookmarks, savedSourcesVersion: CoverArt.sourcesVersion, sourceAdded: false, now: now)
        #expect(!old.coverLookedUp)
        #expect(recent.coverLookedUp)
        #expect(found.coverLookedUp)
    }

    @Test("New cover sources retry missing covers and missing authors")
    func newSources() throws {
        let library = try TestLibrary()
        let missing = searched(library, "Missing")
        let noAuthor = searched(library, "No author", cover: true, creator: "")
        let complete = searched(library, "Complete", cover: true)
        CoverFinder.markForRetry(library.bookmarks, savedSourcesVersion: CoverArt.sourcesVersion - 1, sourceAdded: false,
                                 now: now)
        #expect(!missing.coverLookedUp)
        #expect(!noAuthor.coverLookedUp)
        #expect(complete.coverLookedUp)
        #expect(complete.cover != nil)
    }

    @Test("Adding a source in Settings retries only missing covers")
    func addedSource() throws {
        let library = try TestLibrary()
        let missing = searched(library, "Missing")
        let found = searched(library, "Found", cover: true, creator: "")
        CoverFinder.markForRetry(library.bookmarks, savedSourcesVersion: CoverArt.sourcesVersion, sourceAdded: true, now: now)
        #expect(!missing.coverLookedUp)
        #expect(found.coverLookedUp)
    }
}

// MARK: Backups

@Suite("Backups")
@MainActor
struct BackupTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// Backs up `library` to JSON the way the app does, with screenshots kept by name.
    private func backUp(_ library: TestLibrary) throws -> (Data, [String: Data]) {
        var images: [String: Data] = [:]
        let records = library.bookmarks.map { bookmark in
            let name = bookmark.screenshot.map { _ in "\(bookmark.title).jpg" }
            if let name { images[name] = bookmark.screenshot }
            return Backup.record(for: bookmark, image: name)
        }
        let file = BackupFile(createdAt: date, bookmarks: records, scannedKeys: ["hash:abc", "asset:1"])
        return (try Backup.encoder.encode(file), images)
    }

    private func restore(_ json: Data, images: [String: Data], into library: TestLibrary) throws -> (added: Int, kept: Int) {
        let file = try Backup.decoder.decode(BackupFile.self, from: json)
        return try Backup.restore(file, context: library.context) { images[$0] }
    }

    @Test("Restoring brings back every field")
    func roundTrip() throws {
        let source = try TestLibrary()
        let solo = source.add("Solo Leveling", category: .manhwa, original: "나 혼자만 레벨업")
        solo.creator = "Chugong"
        solo.originalCreator = "추공"
        solo.englishTitle = "Solo Leveling"
        solo.englishChecked = true
        solo.englishVerified = true
        solo.year = "2018"
        solo.summary = "A weak hunter levels up."
        solo.tags = ["action", "fantasy"]
        solo.notes = "Recommended by a friend"
        solo.createdAt = date
        solo.status = .started
        solo.archivedAt = date.addingTimeInterval(3600)
        solo.seenAgainCount = 2
        solo.lastSeenAgainAt = date.addingTimeInterval(7200)
        solo.sourceHash = "abc"
        solo.sourceAssetID = "asset-1"
        solo.photoBox = "0.1,0.2,0.3,0.4"
        solo.screenshot = Data([1, 2, 3])
        let place = source.add("Moss & Kettle", category: .place)
        place.location = "Kyoto, Japan"
        place.url = "mossandkettle.example"
        place.createdAt = date

        let (json, images) = try backUp(source)
        let target = try TestLibrary()
        let result = try restore(json, images: images, into: target)
        #expect(result.added == 2 && result.kept == 0)

        let restored = try #require(target.bookmarks.first { $0.title == "Solo Leveling" })
        #expect(restored.category == .manhwa)
        #expect(restored.originalTitle == "나 혼자만 레벨업")
        #expect(restored.creator == "Chugong")
        #expect(restored.originalCreator == "추공")
        #expect(restored.englishTitle == "Solo Leveling")
        #expect(restored.englishChecked && restored.englishVerified)
        #expect(restored.year == "2018")
        #expect(restored.summary == "A weak hunter levels up.")
        #expect(restored.tags == ["action", "fantasy"])
        #expect(restored.notes == "Recommended by a friend")
        #expect(restored.status == .started)
        #expect(restored.createdAt == date)
        #expect(restored.archivedAt == date.addingTimeInterval(3600))
        #expect(restored.seenAgainCount == 2)
        #expect(restored.lastSeenAgainAt == date.addingTimeInterval(7200))
        #expect(restored.sourceHash == "abc")
        #expect(restored.sourceAssetID == "asset-1")
        #expect(restored.photoBox == "0.1,0.2,0.3,0.4")
        #expect(restored.screenshot == Data([1, 2, 3]))
        // Covers aren't backed up; they're searched for again.
        #expect(!restored.coverLookedUp)

        let restoredPlace = try #require(target.bookmarks.first { $0.title == "Moss & Kettle" })
        #expect(restoredPlace.location == "Kyoto, Japan")
        #expect(restoredPlace.url == "mossandkettle.example")
        #expect(restoredPlace.screenshot == nil)

        let scanned = try target.context.fetch(FetchDescriptor<ScannedImage>()).map(\.key)
        #expect(Set(scanned) == ["hash:abc", "asset:1"])
    }

    @Test("Every stored bookmark field is either backed up or deliberately left out")
    func backupCoversEveryField() throws {
        let entity = try #require(Schema(versionedSchema: LibrarySchemaV1.self).entities.first { $0.name == "Bookmark" })
        let stored = Set(entity.properties.map(\.name))
        // Fields named differently in the backup.
        let renamed = ["category": "categoryRaw", "status": "statusRaw", "image": "screenshot"]
        let record = Backup.record(for: Bookmark(category: .book, title: "Dune"), image: nil)
        let backedUp = Set(Mirror(reflecting: record).children.compactMap(\.label).map { renamed[$0] ?? $0 })
        // Covers aren't backed up: they're searched for again after restoring.
        let leftOut: Set = ["cover", "coverLookedUp", "coverLookedUpAt"]
        // A new field on Bookmark must be added to BackupFile.Record, Backup.record and
        // Backup.restore (as an optional, so older backups still load), or listed in leftOut.
        #expect(stored.subtracting(backedUp).subtracting(leftOut).isEmpty,
                "Not backed up: \(stored.subtracting(backedUp).subtracting(leftOut).sorted())")
        #expect(backedUp.subtracting(stored).isEmpty,
                "In backups but not on Bookmark: \(backedUp.subtracting(stored).sorted())")
    }

    @Test("Clean-up deletes only screenshot copies no bookmark uses, including iCloud placeholders")
    func pruning() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["used.jpg", "unused.jpg", ".usedInCloud.jpg.icloud", ".unusedInCloud.jpg.icloud", "notes.txt"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        Backup.pruneImages(in: folder, keeping: ["used.jpg", "usedInCloud.jpg"])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == ["used.jpg", ".usedInCloud.jpg.icloud", "notes.txt"])
    }

    @Test("Restoring twice adds nothing the second time")
    func restoreIsAdditive() throws {
        let source = try TestLibrary()
        source.add("Dune")
        source.add("Past Lives", category: .movie)
        let (json, images) = try backUp(source)
        let target = try TestLibrary()
        _ = try restore(json, images: images, into: target)
        let second = try restore(json, images: images, into: target)
        #expect(second.added == 0 && second.kept == 2)
        #expect(target.bookmarks.count == 2)
        #expect(try target.context.fetchCount(FetchDescriptor<ScannedImage>()) == 2)
    }

    @Test("A bookmark already here under another language's title isn't restored again")
    func restoreMatchesOriginalTitles() throws {
        let source = try TestLibrary()
        source.add("I Level Up Alone", category: .manhwa, original: "나 혼자만 레벨업")
        let (json, images) = try backUp(source)
        let target = try TestLibrary()
        target.add("Solo Leveling", category: .manhwa, original: "나 혼자만 레벨업")
        let result = try restore(json, images: images, into: target)
        #expect(result.added == 0 && result.kept == 1)
    }
}

// MARK: AI responses

@Suite("Reading AI responses")
struct AIResponseTests {
    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func claudeTextAfterThinking() throws {
        let response = try json("""
        {"stop_reason": "end_turn", "content": [{"type": "thinking", "thinking": "Looking"},
                                                {"type": "text", "text": "{\\"items\\": []}"}]}
        """)
        #expect(try AIClient.text(fromClaude: response) == #"{"items": []}"#)
    }

    @Test func claudeRefusal() throws {
        let response = try json("""
        {"stop_reason": "refusal", "stop_details": {"explanation": "Not allowed"}, "content": []}
        """)
        let error = #expect(throws: AIError.self) { try AIClient.text(fromClaude: response) }
        guard case .refused(let why) = error else { Issue.record("expected a refusal, got \(String(describing: error))"); return }
        #expect(why == "Not allowed")
    }

    @Test func claudeWithoutText() throws {
        let error = #expect(throws: AIError.self) { try AIClient.text(fromClaude: try json(#"{"content": []}"#)) }
        guard case .badResponse = error else { Issue.record("expected a bad response"); return }
    }

    @Test func openAIText() throws {
        let response = try json(#"{"choices": [{"message": {"content": "{}", "refusal": null}}]}"#)
        #expect(try AIClient.text(fromOpenAI: response) == "{}")
    }

    @Test func openAIRefusal() throws {
        let response = try json(#"{"choices": [{"message": {"content": null, "refusal": "No"}}]}"#)
        let error = #expect(throws: AIError.self) { try AIClient.text(fromOpenAI: response) }
        guard case .refused("No") = error else { Issue.record("expected a refusal"); return }
    }

    @Test("Gemini thought parts are skipped and the rest joined")
    func geminiText() throws {
        let response = try json("""
        {"candidates": [{"content": {"parts": [{"text": "thinking…", "thought": true},
                                                {"text": "{\\"items\\":"}, {"text": " []}"}]}}]}
        """)
        #expect(try AIClient.text(fromGemini: response) == #"{"items": []}"#)
    }

    @Test("Gemini blocks and safety stops are refusals; other empty answers are errors", arguments: [
        (#"{"promptFeedback": {"blockReason": "SAFETY"}}"#, true),
        (#"{"candidates": [{"finishReason": "PROHIBITED_CONTENT", "content": {"parts": []}}]}"#, true),
        (#"{"candidates": [{"finishReason": "MAX_TOKENS", "content": {"parts": []}}]}"#, false),
    ])
    func geminiEmpty(_ body: String, isRefusal: Bool) throws {
        let response = try json(body)
        let error = #expect(throws: AIError.self) { try AIClient.text(fromGemini: response) }
        switch error {
        case .refused: #expect(isRefusal)
        case .badResponse: #expect(!isRefusal)
        default: Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test("Cover pages: named links first, then the pages the search used")
    func geminiCoverPages() throws {
        let response = try json("""
        {"candidates": [{
          "content": {"parts": [{"text": "Here: <https://books.example/dune>, and (https://shop.example/d). Not a link."}]},
          "groundingMetadata": {"groundingChunks": [{"web": {"uri": "https://redirect.example/1"}},
                                                    {"web": {"uri": "https://redirect.example/2"}}]}}]}
        """)
        #expect(AIClient.coverPages(fromGemini: response).map(\.absoluteString) == [
            "https://books.example/dune", "https://shop.example/d",
            "https://redirect.example/1", "https://redirect.example/2",
        ])
    }

    @Test func malformedAnswersAreReported() {
        let error = #expect(throws: AIError.self) { try AIClient.decode(ExtractionResult.self, from: #"{"items": ["#) }
        guard case .badResponse = error else { Issue.record("expected a bad response"); return }
    }
}
