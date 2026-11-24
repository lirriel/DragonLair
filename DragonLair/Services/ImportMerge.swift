import Foundation
import SwiftData

/// Turns what the AI read on one screenshot into bookmarks, skipping anything already in the
/// library. Kept apart from the import queue so it can be tested without a network or Photos.
@MainActor
enum ImportMerge {
    struct Result: Equatable {
        var added = 0
        /// Why items weren't added: one note per item that was already saved.
        var notes: [String] = []
    }

    /// Adds the items that aren't saved yet. One that is, archived included, is counted as seen
    /// again instead. Matching uses both the shown and the original-language title of saved
    /// bookmarks, and both the title and the English title of new items, so a screenshot in
    /// either language is recognised.
    ///
    /// An item the AI recognised but couldn't name is still worth keeping, so the user can
    /// rename it once they find out what it is. It gets a placeholder title that no other
    /// bookmark has, and is never taken for one already saved. Items with nothing at all are
    /// dropped. Doesn't save the context.
    static func merge(_ items: [ExtractedItem], hash: String, screenshot: Data?, assetID: String?,
                      context: ModelContext, now: Date = .now) throws -> Result {
        var known: [String: Bookmark] = [:]
        for bookmark in try context.fetch(FetchDescriptor<Bookmark>()) {
            for title in [bookmark.title, bookmark.originalTitle] where !title.isEmpty {
                let key = Bookmark.matchKey(category: bookmark.category, title: title)
                if known[key] == nil { known[key] = bookmark }
            }
        }
        var result = Result()
        for var item in items {
            let category = BookmarkCategory(rawValue: item.category) ?? .other
            if isBlank(item.title) {
                guard !isBlank(item.summary + item.creator + item.url + item.location) else { continue }
                item.title = placeholderTitle(category: category, date: now, taken: known)
                item.englishTitle = ""
            }
            let key = Bookmark.matchKey(category: category, title: item.title)
            let englishKey = Bookmark.matchKey(category: category, title: item.englishTitle)
            if let existing = known[key] ?? (isBlank(item.englishTitle) ? nil : known[englishKey]) {
                existing.seenAgainCount += 1
                existing.lastSeenAgainAt = .now
                result.notes.append(existing.duplicateNote)
                continue
            }
            let bookmark = Bookmark(
                category: category,
                title: item.title, creator: item.creator, year: item.year,
                summary: item.summary, url: item.url, location: item.location,
                tags: item.tags.map { $0.lowercased() }, sourceHash: hash, screenshot: screenshot)
            bookmark.sourceAssetID = assetID ?? ""
            bookmark.englishTitle = item.englishTitle
            bookmark.englishCreator = item.englishCreator
            bookmark.photoBox = item.photoBox
            bookmark.englishChecked = true
            bookmark.preferEnglishNames()
            context.insert(bookmark)
            known[key] = bookmark
            if !isBlank(item.englishTitle) { known[englishKey] = bookmark }
            result.added += 1
        }
        return result
    }

    /// Whether a screenshot can be skipped without sending it to the AI, so it isn't paid for
    /// twice. Watching and period imports skip any screenshot read before. One the user picks or
    /// shares again is read again, unless a bookmark from it still exists (they may have deleted
    /// a wrong import to try again). `forceRead` is "Read again" after nothing was found.
    static func canSkip(hash: String, isAutomatic: Bool, forceRead: Bool, context: ModelContext) -> Bool {
        let fromThisScreenshot = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.sourceHash == hash })
        if ((try? context.fetchCount(fromThisScreenshot)) ?? 0) > 0 { return true }
        guard isAutomatic, !forceRead else { return false }
        let key = "hash:\(hash)"
        return ((try? context.fetchCount(FetchDescriptor<ScannedImage>(predicate: #Predicate { $0.key == key }))) ?? 0) > 0
    }

    /// "Unnamed book, 24 Nov 2026", numbered when that's taken: two unnamed finds are never
    /// the same thing, and distinct titles keep them apart in backups too.
    static func placeholderTitle(category: BookmarkCategory, date: Date, taken: [String: Bookmark]) -> String {
        let kind = category == .movie ? "movie or show" : category.rawValue
        let base = "Unnamed \(kind), \(date.formatted(date: .abbreviated, time: .omitted))"
        var title = base
        var number = 2
        while taken[Bookmark.matchKey(category: category, title: title)] != nil {
            title = "\(base) \(number)"
            number += 1
        }
        return title
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
