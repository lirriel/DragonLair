import Foundation
import SwiftData
import Synchronization
import Testing
@testable import DragonLair

// MARK: Fake network

enum StubReply: Sendable {
    case status(Int, Data = Data(), headers: [String: String] = [:])
    case failure(URLError.Code)
    case redirect(String)
}

/// Answers every request of a `StubProtocol.session()` from a handler, and records them.
/// One handler at a time, so the suites using it run one test after another.
final class StubProtocol: URLProtocol {
    private struct State {
        var handler: (@Sendable (URLRequest) -> StubReply)?
        var requests: [URLRequest] = []
    }
    private static let state = Mutex(State())

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    static func serve(_ handler: @escaping @Sendable (URLRequest) -> StubReply) {
        state.withLock { $0 = State(handler: handler) }
    }

    static var requests: [URLRequest] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream { recorded.httpBody = Self.read(stream) }
        let handler = Self.state.withLock { state in
            state.requests.append(recorded)
            return state.handler
        }
        guard let client, let url = request.url, let handler else { return }
        switch handler(recorded) {
        case .status(let code, let body, let headers):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            // When the redirect is refused, this response is the answer.
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("With a fake network", .serialized)
struct NetworkTests {

    // MARK: AI requests

    @Suite("Talking to AI providers")
    struct AIRequestTests {
        private let claudeAnswer = Data(#"{"content": [{"type": "text", "text": "{\"items\": []}"}]}"#.utf8)
        private let geminiAnswer = Data(#"{"candidates": [{"content": {"parts": [{"text": "{\"items\": []}"}]}}]}"#.utf8)
        private let openAIAnswer = Data(#"{"choices": [{"message": {"content": "{\"items\": []}"}}]}"#.utf8)

        private func client(_ provider: AIProviderKind = .claude, model: String = "test-model", key: String = "test-key") -> AIClient {
            AIClient(provider: provider, apiKey: key, model: model, session: StubProtocol.session(),
                     retryWaits: [.zero, .zero, .zero])
        }

        @Test("A busy provider is asked again until it answers")
        func busyThenAnswers() async throws {
            let answer = claudeAnswer
            StubProtocol.serve { _ in StubProtocol.requests.count < 3 ? .status(429) : .status(200, answer) }
            _ = try await client().extract(jpeg: Data([1]))
            #expect(StubProtocol.requests.count == 3)
        }

        @Test("A provider that stays busy is given up on after three retries")
        func staysBusy() async throws {
            StubProtocol.serve { _ in .status(503) }
            let error = await #expect(throws: AIError.self) { try await client().extract(jpeg: Data([1])) }
            guard case .http(503, _) = error else { Issue.record("expected HTTP 503, got \(String(describing: error))"); return }
            #expect(StubProtocol.requests.count == 4)
        }

        @Test("Errors that waiting won't fix aren't retried", arguments: [400, 401, 404])
        func notRetried(_ status: Int) async throws {
            StubProtocol.serve { _ in .status(status, Data("bad request".utf8)) }
            await #expect(throws: AIError.self) { try await client().extract(jpeg: Data([1])) }
            #expect(StubProtocol.requests.count == 1)
        }

        @Test("A timeout is retried; being offline isn't")
        func networkErrors() async throws {
            let answer = claudeAnswer
            StubProtocol.serve { _ in StubProtocol.requests.count == 1 ? .failure(.timedOut) : .status(200, answer) }
            _ = try await client().extract(jpeg: Data([1]))
            #expect(StubProtocol.requests.count == 2)

            StubProtocol.serve { _ in .failure(.notConnectedToInternet) }
            await #expect(throws: URLError.self) { try await client().extract(jpeg: Data([1])) }
            #expect(StubProtocol.requests.count == 1)
        }

        @Test("A busy Gemini model the user picked falls back to the default one")
        func geminiFallback() async throws {
            let answer = geminiAnswer
            StubProtocol.serve { request in
                request.url?.absoluteString.contains("gemini-pro-latest") == true ? .status(503) : .status(200, answer)
            }
            _ = try await client(.gemini, model: "gemini-pro-latest").extract(jpeg: Data([1]))
            let urls = StubProtocol.requests.compactMap(\.url?.absoluteString)
            // One quick try on the chosen model, then the default.
            #expect(urls.count == 2)
            #expect(urls.last?.contains(AIClient.geminiFallbackModel) == true)
        }

        @Test("Without a key nothing is sent")
        func missingKey() async throws {
            StubProtocol.serve { _ in .status(200) }
            let error = await #expect(throws: AIError.self) { try await client(key: "").extract(jpeg: Data([1])) }
            guard case .missingKey = error else { Issue.record("expected a missing key error"); return }
            #expect(StubProtocol.requests.isEmpty)
        }

        @Test("The key goes in a header, never the URL, and only to the provider's own host", arguments: [
            (AIProviderKind.claude, "x-api-key", "test-key", "api.anthropic.com"),
            (.openai, "Authorization", "Bearer test-key", "api.openai.com"),
            (.gemini, "x-goog-api-key", "test-key", "generativelanguage.googleapis.com"),
        ])
        func keyHandling(_ provider: AIProviderKind, _ header: String, _ value: String, _ host: String) async throws {
            let answer = switch provider {
            case .claude: claudeAnswer
            case .openai: openAIAnswer
            case .gemini: geminiAnswer
            }
            StubProtocol.serve { _ in .status(200, answer) }
            _ = try await client(provider, model: AIClient.geminiFallbackModel).extract(jpeg: Data([1, 2, 3]))
            let request = try #require(StubProtocol.requests.first)
            #expect(request.url?.host == host)
            #expect(request.url?.absoluteString.contains("test-key") == false)
            #expect(request.value(forHTTPHeaderField: header) == value)
            // The screenshot is in the request, base64-encoded.
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains(Data([1, 2, 3]).base64EncodedString()))
        }
    }

    // MARK: Downloads

    @Suite("Downloading covers and pages")
    struct DownloadTests {
        private func get(_ url: String, limit: Int = 1000, truncate: Bool = false) async -> Data? {
            await CoverArt.fetch(URLRequest(url: URL(string: url)!), limit: limit, truncate: truncate,
                                 session: StubProtocol.session())?.0
        }

        @Test func smallResponsesArrive() async {
            StubProtocol.serve { _ in .status(200, Data(repeating: 7, count: 500)) }
            #expect(await get("https://covers.example/a.jpg")?.count == 500)
        }

        @Test("Responses over the limit are dropped, whether or not their size is announced", arguments: [true, false])
        func overLimit(_ announced: Bool) async {
            let headers = announced ? ["Content-Length": "2000"] : [:]
            StubProtocol.serve { _ in .status(200, Data(repeating: 7, count: 2000), headers: headers) }
            #expect(await get("https://covers.example/a.jpg") == nil)
        }

        @Test("Pages over the limit keep their start, which holds the title and preview image")
        func truncated() async {
            StubProtocol.serve { _ in .status(200, Data(repeating: 7, count: 2000)) }
            #expect(await get("https://shop.example/item", truncate: true)?.count == 1000)
        }

        @Test func errorsGiveNothing() async {
            StubProtocol.serve { _ in .status(404, Data("Not found".utf8)) }
            #expect(await get("https://covers.example/a.jpg") == nil)
        }

        @Test("Local network addresses aren't contacted at all")
        func privateAddresses() async {
            StubProtocol.serve { _ in .status(200, Data("router admin page".utf8)) }
            #expect(await get("https://192.168.1.1/admin") == nil)
            #expect(StubProtocol.requests.isEmpty)
        }

        @Test("A redirect to the local network isn't followed")
        func redirectToPrivate() async {
            StubProtocol.serve { request in
                request.url?.host == "shop.example" ? .redirect("https://192.168.1.1/admin")
                    : .status(200, Data("router admin page".utf8))
            }
            #expect(await get("https://shop.example/item") == nil)
            #expect(!StubProtocol.requests.contains { $0.url?.host == "192.168.1.1" })
        }

        @Test("A redirect to another public site is followed")
        func redirectToPublic() async {
            StubProtocol.serve { request in
                request.url?.host == "shop.example" ? .redirect("https://cdn.example/a.jpg") : .status(200, Data([1, 2, 3]))
            }
            #expect(await get("https://shop.example/item") == Data([1, 2, 3]))
            #expect(StubProtocol.requests.contains { $0.url?.host == "cdn.example" })
        }
    }
}

// MARK: Re-reading

@Suite("Re-reading a bookmark's screenshot")
@MainActor
struct RereadTests {
    @Test("The item of the same category is used, else the first named one")
    func choosingTheItem() {
        let bookmark = Bookmark(category: .movie, title: "Wrong")
        let items = [item("", category: "movie"), item("A book"), item("The film", category: "movie")]
        #expect(ImportMerge.rereadItem(for: bookmark, from: items)?.title == "The film")
        #expect(ImportMerge.rereadItem(for: bookmark, from: [item(" "), item("A book")])?.title == "A book")
        #expect(ImportMerge.rereadItem(for: bookmark, from: [item(""), item("  ")]) == nil)
    }

    @Test("What the AI read is replaced; what the user added stays")
    func replacing() {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let bookmark = Bookmark(category: .book, title: "Wrong title", creator: "Wrong author", year: "1999",
                                summary: "Wrong", tags: ["old"], sourceHash: "abc", screenshot: Data([1]))
        bookmark.notes = "My note"
        bookmark.status = .started
        let archivedAt = bookmark.archivedAt
        bookmark.createdAt = created
        bookmark.seenAgainCount = 3
        bookmark.originalTitle = "Old original"
        bookmark.cover = Data([9])
        bookmark.coverLookedUp = true
        bookmark.englishVerified = true

        ImportMerge.applyReread(item("Dune", creator: "Frank Herbert", tags: ["Sci-Fi"]), to: bookmark)

        #expect(bookmark.title == "Dune" && bookmark.creator == "Frank Herbert")
        #expect(bookmark.year.isEmpty && bookmark.summary.isEmpty)
        #expect(bookmark.tags == ["sci-fi"])
        #expect(bookmark.originalTitle.isEmpty && !bookmark.englishVerified)
        // The old cover belonged to the wrong title.
        #expect(bookmark.cover == nil && !bookmark.coverLookedUp)
        #expect(bookmark.notes == "My note")
        #expect(bookmark.status == .started && bookmark.archivedAt == archivedAt)
        #expect(bookmark.createdAt == created && bookmark.seenAgainCount == 3)
        #expect(bookmark.sourceHash == "abc" && bookmark.screenshot == Data([1]))
    }

    @Test("A title in another script read again is shown in English")
    func englishNames() {
        let bookmark = Bookmark(category: .manhwa, title: "Wrong")
        ImportMerge.applyReread(item("나 혼자만 레벨업", category: "manhwa", english: "Solo Leveling"), to: bookmark)
        #expect(bookmark.title == "Solo Leveling" && bookmark.originalTitle == "나 혼자만 레벨업")
    }
}

// MARK: Search

@Suite("Searching")
@MainActor
struct SearchTests {
    private let bookmark: Bookmark = {
        let b = Bookmark(category: .place, title: "Café Kitsuné", creator: "Maison Kitsuné",
                         summary: "Coffee by the Palais-Royal gardens", location: "Paris, France", tags: ["coffee", "brunch"])
        b.originalTitle = "カフェ キツネ"
        b.notes = "Try the fox cookies"
        return b
    }()

    @Test("Finds a bookmark by any of its words, ignoring case, accents and width", arguments: [
        "kitsune", "CAFÉ", "cafe kitsune", "maison", "palais", "paris", "brunch", "fox cookies", "キツネ", "ｃａｆｅ",
    ])
    func finds(_ query: String) {
        #expect(bookmark.matches(query))
    }

    @Test("Doesn't find unrelated words", arguments: ["tea", "London", "kitsunee"])
    func doesntFind(_ query: String) {
        #expect(!bookmark.matches(query))
    }

    @Test func emptySearchShowsEverything() {
        #expect(bookmark.matches("  "))
    }
}

// MARK: Covers

@Suite("Saving a found cover")
@MainActor
struct CoverSavingTests {
    @Test("A search that finds nothing keeps the cover already there")
    func nothingFound() {
        let bookmark = Bookmark(category: .book, title: "Dune")
        bookmark.cover = Data([1])
        bookmark.apply(nil)
        #expect(bookmark.cover == Data([1]))
        #expect(bookmark.coverLookedUp && bookmark.coverLookedUpAt != nil)
    }

    @Test("A found cover fills in a missing author and year, but never replaces them")
    func fillsGaps() {
        let empty = Bookmark(category: .book, title: "Dune")
        empty.apply(CoverArt.Found(image: Data([2]), creator: "Frank Herbert", year: "1965"))
        #expect(empty.cover == Data([2]) && empty.creator == "Frank Herbert" && empty.year == "1965")

        let filled = Bookmark(category: .book, title: "Dune", creator: "F. Herbert", year: "2005")
        filled.apply(CoverArt.Found(image: Data([2]), creator: "Frank Herbert", year: "1965"))
        #expect(filled.creator == "F. Herbert" && filled.year == "2005")
    }
}

// MARK: Restoring

@Suite("Restoring unusual backups")
@MainActor
struct RestoreEdgeTests {
    private func record(_ title: String, category: String = "book", image: String? = nil) -> BackupFile.Record {
        BackupFile.Record(category: category, status: "saved", title: title, creator: "", year: "", summary: "", url: "",
                          location: "", tags: [], notes: "", createdAt: .now, archivedAt: nil, seenAgainCount: 0,
                          lastSeenAgainAt: nil, sourceHash: "", sourceAssetID: "", image: image)
    }

    @Test("Bookmarks whose screenshot copies are missing are restored without them")
    func missingImages() throws {
        let library = try TestLibrary()
        let backup = BackupFile(createdAt: .now, bookmarks: [record("Dune", image: "gone.jpg")], scannedKeys: [])
        let result = try Backup.restore(backup, context: library.context) { _ in nil }
        #expect(result.added == 1)
        #expect(library.bookmarks.first?.screenshot == nil)
    }

    @Test("A category this version doesn't know becomes Other")
    func unknownCategory() throws {
        let library = try TestLibrary()
        let backup = BackupFile(createdAt: .now, bookmarks: [record("A game", category: "games")], scannedKeys: [])
        _ = try Backup.restore(backup, context: library.context) { _ in nil }
        #expect(library.bookmarks.first?.category == .other)
    }

    @Test("A damaged backup file is refused before anything is restored", arguments: [
        #"{"version": 1, "createdAt": "2026-11-01T10:00:00Z", "bookmarks": [{"title": "Du"#,
        #"{"version": 1, "bookmarks": []}"#,
        "",
    ])
    func damaged(_ json: String) {
        #expect(throws: (any Error).self) { try Backup.decoder.decode(BackupFile.self, from: Data(json.utf8)) }
    }
}

// MARK: Watching the Screenshots album

@Suite("Watching for new screenshots")
@MainActor
struct WatchingTests {
    @Test("Screenshots queued, waiting for review or handled before aren't offered again")
    func onlyNewOnes() throws {
        let library = try TestLibrary()
        let queue = ImportQueue()
        queue.jobs = [ImportQueue.Job(source: .asset("queued"))]
        queue.pendingReview = ["waiting"]
        library.context.insert(ScannedImage(key: "asset:imported"))
        #expect(queue.unhandled(["queued", "waiting", "imported", "new"], context: library.context) == ["new"])
    }

    @Test("Skipped screenshots are never offered again")
    func skipping() throws {
        let library = try TestLibrary()
        let queue = ImportQueue()
        queue.pendingReview = ["a", "b"]
        queue.skip(["a"], context: library.context)
        #expect(queue.pendingReview == ["b"])
        #expect(queue.unhandled(["a", "c"], context: library.context) == ["c"])
    }
}

// MARK: The import queue

/// Lets a test hold one import until it says so.
@MainActor
final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting")
}

@Suite("The import queue")
@MainActor
struct QueueTests {
    @Test("Clearing finished rows while a screenshot is being read puts its result on the right row")
    func clearingDuringAnImport() async throws {
        let library = try TestLibrary()
        let gate = Gate()
        let queue = ImportQueue(testProcess: { job, _ in
            if job.assetID == "b" {
                await gate.wait()
                return .done(added: 2, notes: [])
            }
            return .done(added: 1, notes: [])
        })
        queue.importScreenshots(ids: ["a", "b", "c"], context: library.context)
        try await waitUntil { queue.jobs.first { $0.assetID == "b" }?.state == .working }
        queue.clearFinished()
        #expect(queue.jobs.map(\.assetID) == ["b", "c"])

        gate.open()
        try await waitUntil { !queue.isBusy }
        #expect(queue.jobs.map(\.state) == [.done(added: 2, notes: []), .done(added: 1, notes: [])])
        let scanned = Set(try library.context.fetch(FetchDescriptor<ScannedImage>()).map(\.key))
        #expect(scanned == ["asset:a", "asset:b", "asset:c"])
    }

    @Test("Failed screenshots can be retried, and aren't marked as handled until they work")
    func retrying() async throws {
        let library = try TestLibrary()
        let attempts = Mutex(0)
        let queue = ImportQueue(testProcess: { _, _ in
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            return attempt == 1 ? .failed("Offline") : .done(added: 1, notes: [])
        })
        queue.importScreenshots(ids: ["a"], context: library.context)
        try await waitUntil { !queue.isBusy }
        #expect(queue.failedCount == 1)
        #expect(try library.context.fetchCount(FetchDescriptor<ScannedImage>()) == 0)

        queue.retryFailed(context: library.context)
        try await waitUntil { !queue.isBusy }
        #expect(queue.failedCount == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<ScannedImage>()) == 1)
    }
}
