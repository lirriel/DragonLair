import Foundation
import Observation
import SwiftData

/// Looks up official artwork for bookmarks, and English names for titles in another script
/// (which most cover sources only know in English).
@MainActor
@Observable
final class CoverFinder {
    /// Set while a search over many bookmarks runs, for the progress row in the library.
    private(set) var progress: (done: Int, total: Int)?
    private var isRunning = false
    private let background = BackgroundImport(title: "Finding covers", noun: "covers")

    /// Searches for bookmarks that haven't been searched yet: new imports, and anything
    /// restored from a backup. Ones that found nothing get another try when cover sources
    /// change, when a source is added in Settings, and after a week.
    func find(context: ModelContext) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        Self.markForRetry((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [],
                          savedSourcesVersion: AppSettings.coverSourcesVersion,
                          sourceAdded: AppSettings.retryMissingCovers)
        AppSettings.coverSourcesVersion = CoverArt.sourcesVersion
        AppSettings.retryMissingCovers = false
        await addEnglishNames(context: context)
        // Restored or older bookmarks may have an English name that isn't shown yet.
        for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? [] { bookmark.preferEnglishNames() }
        let pending = (try? context.fetch(FetchDescriptor<Bookmark>(predicate: #Predicate { !$0.coverLookedUp }))) ?? []
        guard !pending.isEmpty else { return }
        uiLog.info("Finding covers for \(pending.count) bookmark(s)")
        // Keeps going (with iOS's progress indicator) if the user leaves the app mid-run.
        let inBackground = pending.count > 3
        if inBackground { background.begin(total: pending.count) }
        progress = (0, pending.count)
        defer {
            progress = nil
            if inBackground { background.end() }
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
                progress = (done, pending.count)
                if inBackground { background.progress(remaining: pending.count - done) }
                if done % 5 == 0 || done == pending.count { try? context.save() }
                // Stopped by iOS or from its progress indicator: the rest wait for next time.
                if !background.isCancelled { startNext() }
            }
        }
        try? context.save()
        uiLog.info("Cover search finished")
    }

    /// Clears `coverLookedUp` on bookmarks worth searching again. `savedSourcesVersion` is the
    /// cover sources version of the last search; `sourceAdded` is set when a source was just
    /// added in Settings. Filtered in memory rather than in a predicate: covers are stored
    /// outside the database.
    static func markForRetry(_ bookmarks: [Bookmark], savedSourcesVersion: Int, sourceAdded: Bool,
                             now: Date = .now) {
        // New or better sources may have what the old ones didn't, or the author they lacked.
        if savedSourcesVersion < CoverArt.sourcesVersion {
            for bookmark in bookmarks where bookmark.cover == nil || bookmark.creator.isEmpty {
                bookmark.coverLookedUp = false
            }
        }
        if sourceAdded {
            for bookmark in bookmarks where bookmark.cover == nil { bookmark.coverLookedUp = false }
        }
        // Covers that weren't anywhere a week ago may be now, e.g. for books not yet released.
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        for bookmark in bookmarks
        where bookmark.coverLookedUp && bookmark.cover == nil && (bookmark.coverLookedUpAt ?? .distantPast) < weekAgo {
            bookmark.coverLookedUp = false
        }
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
            importLog.error("Translating titles failed: \(error, privacy: .public)")
        }
    }
}
