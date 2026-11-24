import Foundation
import Testing
import UIKit
@testable import DragonLair

// MARK: Duplicate detection

@Suite("Matching bookmarks")
struct MatchKeyTests {
    @Test("Ignores case, accents, punctuation, a leading “the” and bracketed extras", arguments: [
        ("The Great Gatsby", "great gatsby"),
        ("Café Kitsuné", "cafe kitsune"),
        ("Past Lives (2023)", "Past Lives"),
        ("Solo Leveling [Official]", "solo-leveling"),
        ("Spider-Man: Homecoming", "spider man homecoming"),
    ])
    func sameTitle(_ a: String, _ b: String) {
        #expect(Bookmark.matchKey(category: .book, title: a) == Bookmark.matchKey(category: .book, title: b))
    }

    @Test func differentCategoriesNeverMatch() {
        #expect(Bookmark.matchKey(category: .book, title: "Dune") != Bookmark.matchKey(category: .movie, title: "Dune"))
    }

    @Test func differentTitlesDontMatch() {
        #expect(Bookmark.matchKey(category: .book, title: "Dune") != Bookmark.matchKey(category: .book, title: "Dune Messiah"))
    }

    @Test("A bookmark is recognised under its original-language title")
    func originalTitleMatches() {
        let saved = Bookmark.matchKeys(category: .manhwa, titles: ["Solo Leveling", "나 혼자만 레벨업"])
        let restored = Bookmark.matchKeys(category: .manhwa, titles: ["I Level Up Alone", "나 혼자만 레벨업"])
        #expect(!saved.isDisjoint(with: restored))
    }

    @Test("Titles with nothing left after cleanup are compared as written")
    func symbolTitles() {
        func key(_ title: String) -> String { Bookmark.matchKey(category: .book, title: title) }
        #expect(key("★★★") != key("☆☆☆"))
        #expect(key("★★★") != key("(Untitled)"))
        #expect(key("(Untitled)") == key("(untitled)"))
        #expect(key("The") != key("★★★"))
    }

    @Test func emptyTitlesAreIgnored() {
        #expect(Bookmark.matchKeys(category: .book, titles: ["Dune", "", "  "]).count == 1)
    }
}

// MARK: Links from screenshots

@Suite("Website links")
struct WebURLTests {
    @Test("Web links open, with https added when missing", arguments: [
        ("excalidraw.com", "https://excalidraw.com"),
        ("https://example.com/a?b=1", "https://example.com/a?b=1"),
        ("http://example.com", "http://example.com"),
        ("  example.org  ", "https://example.org"),
    ])
    func allowed(_ text: String, _ expected: String) {
        #expect(Bookmark.webURL(text)?.absoluteString == expected)
    }

    @Test("Other apps' URL schemes are refused", arguments: [
        "shortcuts://run-shortcut?name=Anything",
        "javascript://alert(1)",
        "file:///private/var/mobile",
        "sms://123",
        "tel://123",
        "",
        "https://",
    ])
    func refused(_ text: String) {
        #expect(Bookmark.webURL(text) == nil)
    }
}

@Suite("Hosts cover searches may contact")
struct PublicHostTests {
    @Test("Public hosts are allowed", arguments: [
        "https://en.wikipedia.org/wiki/Dune", "https://8.8.8.8/", "https://172.32.0.1/", "https://[2606:4700::1111]/",
    ])
    func allowed(_ text: String) {
        #expect(CoverArt.isPublicWebURL(URL(string: text)!))
    }

    @Test("Local network hosts are refused", arguments: [
        "https://localhost/", "https://printer.local/", "https://10.0.0.1/", "https://192.168.1.1/admin",
        "https://172.16.5.4/", "https://127.0.0.1:8080/", "https://169.254.1.1/", "https://[::1]/",
        "https://[fd00::1]/", "https://[fe80::1]/", "ftp://example.com/", "data:image/png;base64,AAAA",
    ])
    func refused(_ text: String) {
        #expect(!CoverArt.isPublicWebURL(URL(string: text)!))
    }

    @Test("Redirects to local network hosts aren't followed", arguments: [
        ("https://192.168.1.1/admin", false), ("http://localhost:8080/", false), ("https://[fd00::1]/", false),
        ("https://covers.example/dune.jpg", true),
    ])
    func redirects(_ target: String, _ followed: Bool) async throws {
        let page = try #require(URL(string: "https://example.com/book"))
        let task = URLSession.shared.dataTask(with: page)
        let response = try #require(HTTPURLResponse(url: page, statusCode: 302, httpVersion: nil,
                                                    headerFields: ["Location": target]))
        let next = try await CoverArt.PublicRedirectsOnly.shared.urlSession(
            URLSession.shared, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: try #require(URL(string: target))))
        #expect((next != nil) == followed)
    }
}

// MARK: Cover matching

@Suite("Cover matching")
struct CoverMatchingTests {
    @Test func nearlyTheSameTitleMatches() {
        #expect(CoverArt.matches("I Have Never Abandoned the Tyrant", "I Never Abandoned the Tyrant"))
    }

    @Test func pageTitlesWithExtrasMatchLoosely() {
        #expect(CoverArt.matches("Project Hail Mary by Andy Weir | Bookshop", "Project Hail Mary", loose: true))
    }

    @Test func differentTitlesDontMatch() {
        #expect(!CoverArt.matches("The Martian", "Project Hail Mary"))
        #expect(!CoverArt.matches(nil, "Project Hail Mary"))
    }

    @Test func veryShortTitlesDontMatchEverything() {
        #expect(!CoverArt.matches("Itinerary", "It"))
    }

    @Test("The year may be off by at most two")
    func years() {
        #expect(CoverArt.sameYear("Published 2021", "2023"))
        #expect(!CoverArt.sameYear("Published 2015", "2023"))
        #expect(CoverArt.sameYear("No year here", "2023"))
        #expect(CoverArt.sameYear("Published 2015", ""))
    }

    @Test func photoBoxes() {
        func close(_ a: CGRect?, _ b: CGRect) -> Bool {
            guard let a else { return false }
            return [a.minX - b.minX, a.minY - b.minY, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < 1e-9 }
        }
        #expect(close(CoverArt.parseBox("0.1,0.2,0.5,0.4"), CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)))
        #expect(CoverArt.parseBox("") == nil)
        #expect(CoverArt.parseBox("0.1,0.2,0.01,0.4") == nil)
        // Boxes running off the screenshot are clipped to it.
        #expect(close(CoverArt.parseBox("0.8,0.8,0.5,0.5"), CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2)))
    }
}

// MARK: Images

@Suite("Image decoding")
struct ImageTests {
    static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        UIImage(data: data).map { CGSize(width: $0.size.width * $0.scale, height: $0.size.height * $0.scale) }
    }

    @Test func coversAreScaledDown() throws {
        let jpeg = try #require(CoverArt.downsampledJPEG(Self.png(width: 3000, height: 2000)))
        let size = try #require(Self.pixelSize(jpeg))
        #expect(max(size.width, size.height) <= 900)
        #expect(abs(size.width / size.height - 1.5) < 0.01)
    }

    @Test func smallCoversAreKeptAtTheirSize() throws {
        let jpeg = try #require(CoverArt.downsampledJPEG(Self.png(width: 400, height: 600)))
        #expect(Self.pixelSize(jpeg) == CGSize(width: 400, height: 600))
    }

    @Test("Placeholders and non-images are rejected")
    func rejected() {
        #expect(CoverArt.downsampledJPEG(Self.png(width: 1, height: 1)) == nil)
        #expect(CoverArt.downsampledJPEG(Self.png(width: 900, height: 60)) == nil)
        #expect(CoverArt.downsampledJPEG(Data("<html></html>".utf8)) == nil)
    }

    @Test("Screenshots are scaled down for sending, previews and thumbnails")
    func screenshotsArePreparedForImport() throws {
        let prepared = try #require(PreparedImage(Self.png(width: 1179, height: 2556)))
        let upload = try #require(prepared.upload.flatMap(Self.pixelSize))
        let preview = try #require(prepared.preview.flatMap(Self.pixelSize))
        let thumbnail = try #require(prepared.thumbnail.map { max($0.size.width, $0.size.height) * $0.scale })
        // Vision models scale anything bigger down anyway; sending more only costs more.
        #expect(max(upload.width, upload.height) <= 1568)
        #expect(max(preview.width, preview.height) <= 1200)
        #expect(thumbnail <= 200)
        #expect(abs(upload.width / upload.height - 1179.0 / 2556.0) < 0.01)
    }

    @Test("The same screenshot always gets the same fingerprint, and different ones never share it")
    func screenshotFingerprints() throws {
        let data = Self.png(width: 1179, height: 2556)
        let hash = try #require(PreparedImage(data)?.hash)
        #expect(hash.count == 64)
        #expect(PreparedImage(data)?.hash == hash)
        #expect(PreparedImage(Self.png(width: 1179, height: 2555))?.hash != hash)
    }

    @Test func notAnImage() {
        #expect(PreparedImage(Data("not an image".utf8)) == nil)
    }
}

// MARK: AI answers and backups

@Suite("Formats")
struct FormatTests {
    @Test("The JSON schema asks for exactly the fields ExtractedItem decodes")
    func schemaMatchesModel() throws {
        let item = ExtractedItem(category: "book", title: "Dune", creator: "Frank Herbert", year: "1965", summary: "",
                                 url: "", location: "", tags: [], englishTitle: "", englishCreator: "", photoBox: "")
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        let properties = try #require(Prompt.schema["properties"] as? [String: Any])
        let items = try #require((properties["items"] as? [String: Any])?["items"] as? [String: Any])
        let required = try #require(items["required"] as? [String])
        #expect(Set(required) == Set(encoded.keys))
        let categories = try #require((items["properties"] as? [String: Any])?["category"] as? [String: Any])
        #expect(categories["enum"] as? [String] == BookmarkCategory.allCases.map(\.rawValue))
    }

    @Test("Backups made before the language fields still load")
    @MainActor
    func oldBackupsLoad() throws {
        let json = """
        {"version": 1, "createdAt": "2026-11-01T10:00:00Z", "scannedKeys": ["hash:abc"],
         "bookmarks": [{"category": "book", "status": "saved", "title": "Dune", "creator": "", "year": "",
                        "summary": "", "url": "", "location": "", "tags": [], "notes": "",
                        "createdAt": "2026-11-01T10:00:00Z", "seenAgainCount": 0, "sourceHash": "", "sourceAssetID": ""}]}
        """
        let backup = try Backup.decoder.decode(BackupFile.self, from: Data(json.utf8))
        #expect(backup.bookmarks.first?.title == "Dune")
        #expect(backup.bookmarks.first?.originalTitle == nil)
    }
}
