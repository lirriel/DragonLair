import CryptoKit
import Foundation
import Observation
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Processes picked screenshots one at a time and turns them into bookmarks.
@MainActor
@Observable
final class ImportQueue {
    struct Job: Identifiable {
        enum State: Equatable {
            /// `notes` explain items that weren't added because they already exist.
            case waiting, working, done(added: Int, notes: [String]), skipped, failed(String)
            /// The AI read it but named nothing to save. Not a success: the user may want to
            /// read it again.
            case nothingFound
        }
        enum Source {
            case picker(PhotosPickerItem)
            /// A file the share extension left in the shared inbox.
            case inbox(URL)
            /// A screenshot read straight from the Photos library (period import or watching).
            case asset(String)
        }
        let id = UUID()
        let source: Source
        var thumbnail: UIImage?
        /// Medium-size JPEG for the long-press preview in Imports (and what bookmarks keep).
        var previewData: Data?
        var state: State = .waiting
        var originalDeleted = false
        /// Kept after "nothing found" so it can be read again, even once a shared file is gone.
        var imageData: Data?
        /// Set by "Read again": read it even if it was read before.
        var forceRead = false

        var isFailed: Bool { if case .failed = state { true } else { false } }

        var assetID: String? {
            switch source {
            case .asset(let id): id
            case .picker(let item): item.itemIdentifier
            case .inbox: nil
            }
        }

        /// Only screenshots whose content is now in the collection are safe to delete:
        /// ones that added or matched a bookmark, or were imported before.
        var originalCanBeDeleted: Bool {
            guard !originalDeleted, assetID != nil else { return false }
            switch state {
            case .done(let added, let notes): return added > 0 || !notes.isEmpty
            case .skipped: return true
            default: return false
            }
        }
    }

    var jobs: [Job] = []
    /// New screenshots found by watching, waiting for the user to pick which to import. Nothing
    /// is sent to the AI until they do.
    var pendingReview: [String] = []
    var deleteError: String?
    /// A delete asked for while the app was in the background, where iOS can't show its
    /// confirmation; it runs the next time the app is opened.
    private var deletionPending = false
    private var isRunning = false
    private var isFindingCovers = false
    private let watcher = ScreenshotWatcher()
    private let background = BackgroundImport()
    private let coverBackground = BackgroundImport(title: "Finding covers", noun: "covers")
    /// Set while a cover search over many bookmarks runs, for the progress row in the library.
    private(set) var coverProgress: (done: Int, total: Int)?

    var isBusy: Bool { jobs.contains { $0.state == .waiting || $0.state == .working } }
    var finishedCount: Int { jobs.filter { $0.state != .waiting && $0.state != .working }.count }
    var failedCount: Int { jobs.filter(\.isFailed).count }
    var nothingFoundCount: Int { jobs.filter { $0.state == .nothingFound }.count }
    /// The most recent error, shown in the banner so failures aren't missed.
    var lastError: String? {
        jobs.last { $0.isFailed }.flatMap { if case .failed(let message) = $0.state { message } else { nil } }
    }
    var deletableCount: Int { jobs.filter(\.originalCanBeDeleted).count }

    /// Moves imported originals to Recently Deleted in Photos. iOS asks the user to confirm.
    func deleteOriginals() async {
        let ids = jobs.filter(\.originalCanBeDeleted).compactMap(\.assetID)
        guard !ids.isEmpty else { return }
        guard UIApplication.shared.applicationState == .active else {
            uiLog.info("Deleting \(ids.count) originals once the app is back on screen")
            deletionPending = true
            return
        }
        deletionPending = false
        do {
            let result = try await ScreenshotLibrary.delete(ids)
            // Only what was really deleted; declining the system confirmation isn't an error.
            for i in jobs.indices where jobs[i].assetID.map(result.deleted.contains) == true {
                jobs[i].originalDeleted = true
            }
            deleteError = result.problem
        } catch {
            deleteError = "Couldn't delete the original screenshots: \(error.localizedDescription)"
        }
    }

    /// Runs a delete that was put off while the app was in the background.
    func deleteOriginalsIfPending() async {
        guard deletionPending else { return }
        await deleteOriginals()
    }

    func enqueue(_ items: [PhotosPickerItem], context: ModelContext) {
        jobs.append(contentsOf: items.map { Job(source: .picker($0)) })
        start(context: context)
    }

    /// Queues screenshots shared from other apps that aren't already queued.
    func importInbox(context: ModelContext) {
        let queued = Set(jobs.compactMap { job -> URL? in
            if case .inbox(let url) = job.source { url } else { nil }
        })
        let new = SharedInbox.pending().filter { !queued.contains($0) }
        guard !new.isEmpty else { return }
        jobs.append(contentsOf: new.map { Job(source: .inbox($0)) })
        start(context: context)
    }

    /// Screenshots in the range that were never scanned and aren't queued right now.
    func newScreenshotIDs(from start: Date, to end: Date = .distantFuture, context: ModelContext) -> [String] {
        let queued = Set(jobs.compactMap { job -> String? in
            if case .asset(let id) = job.source { id } else { nil }
        })
        let scanned = Set(((try? context.fetch(FetchDescriptor<ScannedImage>())) ?? []).map(\.key))
        let pending = Set(pendingReview)
        return ScreenshotLibrary.assetIDs(from: start, to: end)
            .filter { !queued.contains($0) && !pending.contains($0) && !scanned.contains("asset:\($0)") }
    }

    func importScreenshots(ids: [String], context: ModelContext) {
        guard !ids.isEmpty else { return }
        jobs.append(contentsOf: ids.map { Job(source: .asset($0)) })
        start(context: context)
    }

    /// Starts or stops watching the Screenshots album to match Settings, and catches up on
    /// anything taken since watching began (e.g. while the app was closed).
    func refreshWatching(context: ModelContext) {
        guard AppSettings.watchScreenshots, ScreenshotLibrary.canRead else {
            watcher.stop()
            return
        }
        watcher.onChange = { [weak self] in self?.scanWatched(context: context) }
        watcher.start()
        scanWatched(context: context)
    }

    private func scanWatched(context: ModelContext) {
        let new = newScreenshotIDs(from: AppSettings.watchSince, context: context)
        guard !new.isEmpty else { return }
        if AppSettings.askBeforeImportingWatched {
            uiLog.info("\(new.count) new screenshot(s) waiting for review")
            pendingReview.append(contentsOf: new)
        } else {
            importScreenshots(ids: new, context: context)
        }
    }

    /// Imports the reviewed screenshots the user picked.
    func approve(_ ids: [String], context: ModelContext) {
        pendingReview.removeAll { ids.contains($0) }
        uiLog.info("Importing \(ids.count) reviewed screenshot(s)")
        importScreenshots(ids: ids, context: context)
    }

    /// Skips reviewed screenshots for good: they're marked as handled, so watching doesn't
    /// offer them again.
    func skip(_ ids: [String], context: ModelContext) {
        pendingReview.removeAll { ids.contains($0) }
        uiLog.info("Skipping \(ids.count) screenshot(s)")
        for id in ids { context.insert(ScannedImage(key: "asset:\(id)")) }
        try? context.save()
    }

    /// Picks up screenshots left waiting when a background run was stopped.
    func resume(context: ModelContext) {
        if jobs.contains(where: { $0.state == .waiting }) { start(context: context) }
    }

    /// Sends a screenshot where nothing was found to the AI again.
    func readAgain(_ id: Job.ID, context: ModelContext) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        uiLog.info("Reading a screenshot again after nothing was found")
        jobs[index].forceRead = true
        jobs[index].state = .waiting
        start(context: context)
    }

    func retryFailed(context: ModelContext) {
        for i in jobs.indices where jobs[i].isFailed { jobs[i].state = .waiting }
        start(context: context)
    }

    private func start(context: ModelContext) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await run(context: context)
            isRunning = false
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state != .waiting && $0.state != .working }
    }

    private func run(context: ModelContext) async {
        background.begin(total: jobs.filter { $0.state == .waiting }.count)
        defer { background.end() }
        // Stopping (by iOS or from the progress indicator) leaves the rest waiting for next time.
        while !background.isCancelled, let index = jobs.firstIndex(where: { $0.state == .waiting }) {
            jobs[index].state = .working
            let state = await process(index: index, context: context)
            jobs[index].state = state
            background.progress(remaining: jobs.filter { $0.state == .waiting }.count)
            // Failed images aren't marked as handled, so they can be retried later.
            guard !jobs[index].isFailed else { continue }
            switch jobs[index].source {
            case .inbox(let url): SharedInbox.remove(url)
            case .asset(let id): markScanned("asset:\(id)", context: context)
            case .picker: break
            }
        }
        await findCovers(context: context)
        Backup.autoBackup(context: context)
        if AppSettings.deleteOriginalsAfterImport { await deleteOriginals() }
    }

    /// Sends a bookmark's stored screenshot to the AI again with the current instructions and
    /// replaces its details with what's found, for imports that were read wrong. Takes the
    /// item of the same category if the screenshot shows several.
    func reread(_ bookmark: Bookmark, context: ModelContext) async throws {
        guard let screenshot = bookmark.screenshot, let image = UIImage(data: screenshot),
              let jpeg = image.resized(maxSide: 1568).jpegData(compressionQuality: 0.8) else {
            throw AIError.badResponse("this bookmark has no screenshot")
        }
        let items = try await AppSettings.client.extract(jpeg: jpeg).filter { !$0.title.isEmpty }
        guard let item = items.first(where: { $0.category == bookmark.categoryRaw }) ?? items.first else {
            throw AIError.badResponse("nothing recognisable was found on the screenshot")
        }
        uiLog.info("Re-read “\(bookmark.title, privacy: .public)” as “\(item.title, privacy: .public)”")
        bookmark.categoryRaw = (BookmarkCategory(rawValue: item.category) ?? .other).rawValue
        bookmark.title = item.title
        bookmark.creator = item.creator
        bookmark.year = item.year
        bookmark.summary = item.summary
        bookmark.url = item.url
        bookmark.location = item.location
        bookmark.tags = item.tags.map { $0.lowercased() }
        bookmark.englishTitle = item.englishTitle
        bookmark.englishCreator = item.englishCreator
        bookmark.photoBox = item.photoBox
        bookmark.originalTitle = ""
        bookmark.originalCreator = ""
        bookmark.englishChecked = true
        bookmark.englishVerified = false
        bookmark.preferEnglishNames()
        bookmark.cover = nil
        bookmark.coverLookedUp = false
        try context.save()
        await findCovers(context: context)
    }

    /// Asks the AI, text only and in one request, for English names of bookmarks saved
    /// before imports returned them. Ones whose cover search came up empty get another try.
    private func addEnglishNames(context: ModelContext) async {
        // Earlier answers sometimes listed alternatives ("A / B / C"); undo any switch to such a
        // list and ask again for one title.
        for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        where bookmark.englishTitle.contains(" / ") {
            if !bookmark.originalTitle.isEmpty, bookmark.title == bookmark.englishTitle {
                bookmark.title = bookmark.originalTitle
                bookmark.creator = bookmark.originalCreator
                bookmark.originalTitle = ""
                bookmark.originalCreator = ""
            }
            bookmark.englishTitle = ""
            bookmark.englishChecked = false
        }
        // Manhwa and anime: take the official English title from AniList when it has the series.
        for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        where !bookmark.englishVerified && (bookmark.category == .manhwa || bookmark.category == .movie)
            && (bookmark.needsEnglishNames || !bookmark.originalTitle.isEmpty) {
            let original = bookmark.originalTitle.isEmpty ? bookmark.title : bookmark.originalTitle
            if let english = await CoverArt.aniListEnglishTitle(original: original, category: bookmark.category) {
                if !bookmark.originalTitle.isEmpty, bookmark.title == bookmark.englishTitle { bookmark.title = english }
                if bookmark.englishTitle != english, bookmark.cover == nil { bookmark.coverLookedUp = false }
                bookmark.englishTitle = english
                bookmark.englishChecked = true
                bookmark.preferEnglishNames()
            }
            bookmark.englishVerified = true
        }
        try? context.save()
        let unchecked = FetchDescriptor<Bookmark>(predicate: #Predicate { !$0.englishChecked })
        let bookmarks = (try? context.fetch(unchecked)) ?? []
        for bookmark in bookmarks where !bookmark.needsEnglishNames { bookmark.englishChecked = true }
        let foreign = Array(bookmarks.filter(\.needsEnglishNames).prefix(50))
        guard !foreign.isEmpty else { return }
        do {
            let answers = try await AppSettings.client.translate(foreign.enumerated().map {
                (id: $0.offset, category: $0.element.categoryRaw, title: $0.element.title, creator: $0.element.creator)
            })
            for answer in answers where foreign.indices.contains(answer.id) {
                let bookmark = foreign[answer.id]
                bookmark.englishTitle = answer.englishTitle
                bookmark.englishCreator = answer.englishCreator
                bookmark.preferEnglishNames()
                if bookmark.cover == nil && !answer.englishTitle.isEmpty { bookmark.coverLookedUp = false }
            }
            foreign.forEach { $0.englishChecked = true }
            try? context.save()
        } catch {
            // No key or the provider is busy: try again next time.
            print("Translating titles failed: \(error)")
        }
    }

    /// Looks up official artwork for bookmarks that haven't been searched yet: new imports,
    /// and anything saved before covers existed or restored from a backup.
    func findCovers(context: ModelContext) async {
        guard !isFindingCovers else { return }
        isFindingCovers = true
        defer { isFindingCovers = false }
        // When sources are added, bookmarks that found nothing (or no author) before get another try.
        if AppSettings.coverSourcesVersion < 13 {
            // Guessed crops of comment screenshots and café logos are gone; search those again.
            for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
            where bookmark.category == .place || bookmark.category == .product {
                bookmark.cover = nil
                bookmark.coverLookedUp = false
            }
        }
        if AppSettings.coverSourcesVersion < 12 {
            // Look Around street views (parked vans, a Maps watermark) gave way to crops of the
            // screenshot itself; products gained the same fallback.
            for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
            where bookmark.category == .place || bookmark.category == .product {
                bookmark.cover = nil
                bookmark.coverLookedUp = false
            }
        }
        if AppSettings.coverSourcesVersion < 11 {
            // Requested re-run with the current sources (TMDB, Apple Maps, product databases).
            for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
            where [.movie, .product, .place].contains(bookmark.category) {
                bookmark.cover = nil
                bookmark.coverLookedUp = false
            }
            uiLog.info("Re-running cover search for movies, products and places")
        }
        if AppSettings.coverSourcesVersion < 10 {
            // Places used to get only loosely matched Wikipedia photos; Apple Maps does better.
            for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? [] where bookmark.category == .place {
                bookmark.cover = nil
                bookmark.coverLookedUp = false
            }
        }
        if AppSettings.coverSourcesVersion < 9 {
            // Before year checks, a film could get the poster of an older series with the same
            // name (Fortitude 2026 → Fortitude 2015), and loose title matching let in pages like
            // "Operation Fortitude", or a village photo for the series Crookhaven. Search those
            // again from scratch.
            for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
            where bookmark.category == .movie {
                bookmark.cover = nil
            }
        }
        if AppSettings.coverSourcesVersion < CoverArt.sourcesVersion {
            // Filtered here rather than in a predicate: covers are stored outside the database.
            for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
            where bookmark.cover == nil || bookmark.creator.isEmpty {
                bookmark.coverLookedUp = false
            }
            AppSettings.coverSourcesVersion = CoverArt.sourcesVersion
        }
        // A cover source was just added in Settings: it may have what the others didn't.
        if AppSettings.retryMissingCovers {
            AppSettings.retryMissingCovers = false
            for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? [] where bookmark.cover == nil {
                bookmark.coverLookedUp = false
            }
        }
        // Covers that weren't anywhere a week ago may be now, e.g. for books not yet released.
        let weekAgo = Date.now.addingTimeInterval(-7 * 24 * 3600)
        for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        where bookmark.coverLookedUp && bookmark.cover == nil && (bookmark.coverLookedUpAt ?? .distantPast) < weekAgo {
            bookmark.coverLookedUp = false
        }
        await addEnglishNames(context: context)
        // Bookmarks saved before English names were shown for non-Cyrillic titles.
        for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? [] { bookmark.preferEnglishNames() }
        let pending = (try? context.fetch(FetchDescriptor<Bookmark>(predicate: #Predicate { !$0.coverLookedUp }))) ?? []
        guard !pending.isEmpty else { return }
        uiLog.info("Finding covers for \(pending.count) bookmark(s)")
        // Keeps going (with iOS's progress indicator) if the user leaves the app mid-run.
        let inBackground = pending.count > 3
        if inBackground { coverBackground.begin(total: pending.count) }
        coverProgress = (0, pending.count)
        defer {
            coverProgress = nil
            if inBackground { coverBackground.end() }
        }
        // A few at a time: each search waits on several slow catalogues, one after another.
        await withTaskGroup(of: (Int, CoverArt.Found?).self) { group in
            var next = 0
            func startNext() {
                guard next < pending.count else { return }
                let index = next, query = pending[index].coverQuery
                next += 1
                group.addTask { (index, await CoverArt.find(query)) }
            }
            for _ in 0..<4 { startNext() }
            var done = 0
            for await (index, found) in group {
                pending[index].apply(found)
                done += 1
                coverProgress = (done, pending.count)
                if inBackground { coverBackground.progress(remaining: pending.count - done) }
                if done % 5 == 0 || done == pending.count { try? context.save() }
                // Stopped by iOS or from its progress indicator: the rest wait for next time.
                if !coverBackground.isCancelled { startNext() }
            }
        }
        try? context.save()
        uiLog.info("Cover search finished")
    }

    private func markScanned(_ key: String, context: ModelContext) {
        context.insert(ScannedImage(key: key))
        try? context.save()
    }

    private func isScanned(_ key: String, context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<ScannedImage>(predicate: #Predicate { $0.key == key }))) ?? 0) > 0
    }

    private func loadData(_ job: Job) async throws -> Data? {
        if let data = job.imageData { return data }
        return switch job.source {
        case .picker(let item): try await item.loadTransferable(type: Data.self)
        case .inbox(let url): try Data(contentsOf: url)
        case .asset(let id): try await ScreenshotLibrary.imageData(for: id)
        }
    }

    private func process(index: Int, context: ModelContext) async -> Job.State {
        do {
            print("Import: loading image")
            guard let data = try await loadData(jobs[index]),
                  let image = UIImage(data: data) else {
                return .failed("Couldn't load the image")
            }
            jobs[index].thumbnail = image.resized(maxSide: 200)
            jobs[index].previewData = image.resized(maxSide: 1200).jpegData(compressionQuality: 0.7)

            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let existing = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.sourceHash == hash })
            let hasBookmark = (try? context.fetchCount(existing)) ?? 0 > 0
            // Screenshots read before are skipped by watching and period imports, so they aren't
            // paid for twice. One the user picks or shares again is read again unless a bookmark
            // from it still exists (e.g. they deleted a wrong import and want another try).
            let isAutomatic = if case .asset = jobs[index].source { true } else { false }
            if hasBookmark || (isAutomatic && !jobs[index].forceRead && isScanned("hash:\(hash)", context: context)) {
                return .skipped
            }

            // Vision models downscale anything larger anyway; this keeps uploads small.
            guard let upload = image.resized(maxSide: 1568).jpegData(compressionQuality: 0.8) else {
                return .failed("Couldn't encode the image")
            }
            print("Import: sending \(upload.count / 1024) KB to \(AppSettings.provider.rawValue)")
            let started = Date.now
            // An item the AI recognised but couldn't name is still worth keeping; the user can
            // rename it once they find out what it is.
            let items = try await AppSettings.client.extract(jpeg: upload).map { item in
                guard item.title.trimmingCharacters(in: .whitespaces).isEmpty,
                      !(item.summary + item.creator + item.url).trimmingCharacters(in: .whitespaces).isEmpty else { return item }
                var named = item
                let category = BookmarkCategory(rawValue: item.category) ?? .other
                // Dated, so two unnamed finds aren't taken for the same thing.
                named.title = "Unnamed \(category == .movie ? "movie or show" : category.rawValue) "
                    + "(\(Date.now.formatted(date: .abbreviated, time: .shortened)))"
                return named
            }
            print("Import: got \(items.count) items in \(Int(Date.now.timeIntervalSince(started)))s")
            let stored = jobs[index].previewData

            // Everything ever saved, archived included, so old items are recognised.
            // Keyed by both the shown and the original-language title, so a screenshot in
            // either language is recognised.
            var known: [String: Bookmark] = [:]
            for bookmark in try context.fetch(FetchDescriptor<Bookmark>()) {
                for title in [bookmark.title, bookmark.originalTitle] where !title.isEmpty {
                    let key = Bookmark.matchKey(category: bookmark.category, title: title)
                    if known[key] == nil { known[key] = bookmark }
                }
            }
            var added = 0
            var notes: [String] = []

            for item in items where !item.title.trimmingCharacters(in: .whitespaces).isEmpty {
                let category = BookmarkCategory(rawValue: item.category) ?? .other
                let key = Bookmark.matchKey(category: category, title: item.title)
                let englishKey = Bookmark.matchKey(category: category, title: item.englishTitle)
                if let existing = known[key] ?? (item.englishTitle.isEmpty ? nil : known[englishKey]) {
                    existing.seenAgainCount += 1
                    existing.lastSeenAgainAt = .now
                    notes.append(existing.duplicateNote)
                    continue
                }
                let bookmark = Bookmark(
                    category: category,
                    title: item.title, creator: item.creator, year: item.year,
                    summary: item.summary, url: item.url, location: item.location,
                    tags: item.tags.map { $0.lowercased() }, sourceHash: hash, screenshot: stored)
                bookmark.sourceAssetID = jobs[index].assetID ?? ""
                bookmark.englishTitle = item.englishTitle
                bookmark.englishCreator = item.englishCreator
                bookmark.photoBox = item.photoBox
                bookmark.englishChecked = true
                bookmark.preferEnglishNames()
                context.insert(bookmark)
                known[key] = bookmark
                if !item.englishTitle.isEmpty { known[englishKey] = bookmark }
                added += 1
            }
            context.insert(ScannedImage(key: "hash:\(hash)"))
            try context.save()
            if added == 0 && notes.isEmpty {
                print("Import: nothing found (the AI returned \(items.count) item(s))")
                jobs[index].imageData = data
                return .nothingFound
            }
            return .done(added: added, notes: notes)
        } catch {
            print("Import failed: \(error)")
            return .failed(error.localizedDescription)
        }
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
