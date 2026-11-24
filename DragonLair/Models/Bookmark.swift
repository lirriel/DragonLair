import Foundation
import SwiftData

enum BookmarkCategory: String, CaseIterable, Codable, Identifiable {
    case book, manhwa, movie, site, place, product, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .book: "Books"
        case .manhwa: "Manhwa"
        case .movie: "Movies & Shows"
        case .site: "Sites"
        case .place: "Places"
        case .product: "Products"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .book: "book.closed"
        case .manhwa: "text.book.closed"
        case .movie: "film"
        case .site: "globe"
        case .place: "mappin.and.ellipse"
        case .product: "bag"
        case .other: "square.grid.2x2"
        }
    }

    var startedLabel: String {
        switch self {
        case .book, .manhwa: "Started reading"
        case .movie: "Started watching"
        case .site: "Started using"
        case .place: "Been there"
        case .product: "Bought it"
        case .other: "Started"
        }
    }
}

/// Anything other than `saved` is archived: it leaves the main list but is never deleted,
/// so a later screenshot of the same thing can be recognised. Once something is started it's
/// out of the to-do collection, so there's no separate "finished".
enum BookmarkStatus: String, CaseIterable, Codable, Identifiable {
    case saved, started, dropped

    var id: String { rawValue }
    var isArchived: Bool { self != .saved }

    func label(for category: BookmarkCategory) -> String {
        switch self {
        case .saved: "Saved"
        case .started: category.startedLabel
        case .dropped: "Changed my mind"
        }
    }

    /// Completes "archived because …".
    func reason(for category: BookmarkCategory) -> String {
        switch self {
        case .saved: "it's still saved"
        case .started: "you marked it as \(category.startedLabel.lowercased())"
        case .dropped: "you changed your mind about it"
        }
    }

    var symbol: String {
        switch self {
        case .saved: "bookmark"
        case .started: "play.circle"
        case .dropped: "hand.thumbsdown"
        }
    }
}

/// Remembers every image already sent to the AI, including ones where nothing was found,
/// so period imports and watching never pay for the same screenshot twice.
@Model
final class ScannedImage {
    /// "hash:<sha256>" for image contents, "asset:<localIdentifier>" for Photos assets.
    @Attribute(.unique) var key: String
    var scannedAt: Date

    init(key: String) {
        self.key = key
        self.scannedAt = .now
    }
}

@Model
final class Bookmark {
    var categoryRaw: String
    var statusRaw: String
    var title: String
    var creator: String
    var year: String
    var summary: String
    var url: String
    var location: String
    var tags: [String]
    var notes: String
    var createdAt: Date
    /// SHA-256 of the original screenshot, used to skip re-imports.
    var sourceHash: String
    @Attribute(.externalStorage) var screenshot: Data?
    /// Photos library identifier of the original screenshot, if known.
    var sourceAssetID: String = ""
    var archivedAt: Date? = nil
    /// How many times this turned up again in a new screenshot after being saved.
    var seenAgainCount: Int = 0
    var lastSeenAgainAt: Date? = nil
    /// Official artwork (cover, poster, site preview) found online; shown instead of the screenshot.
    @Attribute(.externalStorage) var cover: Data? = nil
    /// Whether a cover search has run, so one that found nothing isn't repeated on every launch.
    var coverLookedUp = false
    /// When the last cover search ran, so ones that found nothing can be retried later
    /// (an upcoming book gets listed once it's out).
    var coverLookedUpAt: Date? = nil
    /// English edition title and author (or a translation) for titles saved in another
    /// language. Used to find covers; empty when the title is already English.
    var englishTitle = ""
    var englishCreator = ""
    /// Whether English names were asked for. Imports get them from the AI right away.
    var englishChecked = false
    /// The name as written in its own language (Korean, Japanese…) when the bookmark is shown
    /// under its English name instead. Empty for English titles and for Russian ones, which
    /// stay in their own language.
    var originalTitle = ""
    var originalCreator = ""
    /// Whether the English title was checked against a catalogue (AniList) rather than only
    /// translated by the AI.
    var englishVerified = false
    /// The item's own picture on the screenshot ("x,y,w,h" fractions), from the AI; used as the
    /// cover when no catalogue has one.
    var photoBox = ""

    init(category: BookmarkCategory, title: String, creator: String = "", year: String = "",
         summary: String = "", url: String = "", location: String = "", tags: [String] = [],
         sourceHash: String = "", screenshot: Data? = nil) {
        self.categoryRaw = category.rawValue
        self.statusRaw = BookmarkStatus.saved.rawValue
        self.title = title
        self.creator = creator
        self.year = year
        self.summary = summary
        self.url = url
        self.location = location
        self.tags = tags
        self.notes = ""
        self.createdAt = .now
        self.sourceHash = sourceHash
        self.screenshot = screenshot
    }

    /// What to show for this bookmark: the official cover when there is one.
    var image: Data? { cover ?? screenshot }

    /// Stores a found cover, and takes the author and year from its catalogue entry when the
    /// screenshot didn't show them.
    func apply(_ found: CoverArt.Found?) {
        coverLookedUp = true
        coverLookedUpAt = .now
        // A search that comes up empty (or fails offline) keeps the cover already there.
        guard let found else { return }
        cover = found.image
        if creator.isEmpty { creator = found.creator }
        if year.isEmpty { year = found.year }
    }

    var coverQuery: CoverArt.Query {
        let hash = sourceHash
        let fromSameScreenshot = hash.isEmpty ? 0
            : (try? modelContext?.fetchCount(FetchDescriptor<Bookmark>(predicate: #Predicate { $0.sourceHash == hash }))) ?? 0
        return CoverArt.Query(category: category, title: title, creator: creator, year: year, url: url, location: location,
                       screenshot: screenshot, photoBox: photoBox, screenshotIsShared: fromSameScreenshot > 1,
                       englishTitle: englishTitle, englishCreator: englishCreator, originalTitle: originalTitle)
    }

    /// Titles in another script, which cover sources mostly don't know under that name.
    var needsEnglishNames: Bool {
        !(title + creator).unicodeScalars.allSatisfy { $0.isASCII || !$0.properties.isAlphabetic || $0.value < 0x250 }
    }

    /// Shows the English names for titles in a non-Latin script other than Cyrillic, keeping
    /// the original alongside. Russian titles stay as written; Latin-script ones (German,
    /// French…) never need it. Safe to call repeatedly.
    func preferEnglishNames() {
        let cyrillic = (title + creator).unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        guard originalTitle.isEmpty, !englishTitle.isEmpty, needsEnglishNames, !cyrillic else { return }
        originalTitle = title
        originalCreator = creator
        title = englishTitle
        if !englishCreator.isEmpty { creator = englishCreator }
    }

    var category: BookmarkCategory {
        get { BookmarkCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var status: BookmarkStatus {
        // "done" (finished) was merged into started; "inProgress" is the oldest name for it.
        get { ["inProgress", "done"].contains(statusRaw) ? .started : BookmarkStatus(rawValue: statusRaw) ?? .saved }
        set {
            guard newValue != status else { return }
            statusRaw = newValue.rawValue
            archivedAt = newValue.isArchived ? .now : nil
        }
    }

    /// Same category and title (ignoring case, accents, punctuation, a leading "the"
    /// and bracketed extras like "(2023)").
    var matchKey: String { Self.matchKey(category: category, title: title) }

    /// Keys for every non-empty title, e.g. the shown and the original-language one. Two
    /// bookmarks are the same when any of their keys match.
    static func matchKeys(category: BookmarkCategory, titles: [String]) -> Set<String> {
        Set(titles.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { matchKey(category: category, title: $0) })
    }

    static func matchKey(category: BookmarkCategory, title: String) -> String {
        let words = title
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let trimmed = words.first == "the" ? Array(words.dropFirst()) : words
        // Titles with nothing left after that ("★★★", "(Untitled)", "The") are compared as
        // written, or they'd all count as the same thing.
        guard !trimmed.isEmpty else {
            let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            return "\(category.rawValue)|=\(folded.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return "\(category.rawValue)|\(trimmed.joined(separator: " "))"
    }

    /// Explains why an item from a new screenshot wasn't added again.
    var duplicateNote: String {
        let saved = createdAt.formatted(date: .abbreviated, time: .omitted)
        guard status.isArchived else { return "“\(title)” is already in your list (saved \(saved))." }
        let archived = (archivedAt ?? createdAt).formatted(date: .abbreviated, time: .omitted)
        return "“\(title)” was saved \(saved) and archived \(archived) because \(status.reason(for: category)). Not added again. Find it in Archive to bring it back."
    }

    /// Removes the bookmark for good, unlike archiving. Its screenshot stays marked as read,
    /// so a wrong import doesn't come back on the next scan.
    func delete() {
        guard let context = modelContext else { return }
        context.delete(self)
        try? context.save()
    }

    /// The bookmark's website. The URL comes from the AI reading a screenshot, which anyone can
    /// write text into, so only web links are allowed: never another app's URL scheme.
    var link: URL? { Self.webURL(url) }

    static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let raw = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    var mapsLink: URL? {
        let query = location.isEmpty ? title : "\(title), \(location)"
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}
