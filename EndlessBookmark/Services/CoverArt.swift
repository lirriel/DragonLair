import Foundation
import ImageIO
import MapKit
import OSLog
import UIKit
import Vision

private let log = Logger(subsystem: "com.lirriel.endlessbookmark", category: "covers")

/// Finds official artwork for a bookmark (book cover, poster, site preview…) from free
/// public sources that need no API key, so the list shows that instead of the screenshot.
enum CoverArt {
    /// Bump when adding a source (or what sources fill in), so earlier misses are searched again.
    static let sourcesVersion = 13

    struct Query: Sendable {
        var category: BookmarkCategory
        var title: String
        var creator: String
        var year: String
        var url: String
        /// Address or "City, Country", for finding a place in Apple Maps.
        var location = ""
        /// The bookmark's screenshot and where the item's own picture is on it: often the best
        /// photo of a café or product, and a cover no catalogue has.
        var screenshot: Data?
        var photoBox = ""
        /// Several bookmarks came from this screenshot (a list of cafés), so a guessed crop
        /// would give them all the same picture.
        var screenshotIsShared = false
        var englishTitle = ""
        var englishCreator = ""
        /// The name in its own language when the bookmark shows the English one; catalogues like
        /// AniList sometimes only know that.
        var originalTitle = ""

        /// The same search under the English edition's name, if that's different.
        var inEnglish: Query? {
            guard !englishTitle.isEmpty, englishTitle != title else { return nil }
            var q = self
            q.title = englishTitle
            if !englishCreator.isEmpty { q.creator = englishCreator }
            q.englishTitle = ""
            return q
        }
    }

    /// The cover, plus the author and year the matching catalogue entry lists, which fill in
    /// what a screenshot didn't show.
    struct Found: Sendable {
        var image: Data
        var creator = ""
        var year = ""
    }

    /// A source's match: where the image is, and what else the entry says.
    private struct Hit: Sendable {
        var url: URL
        var creator = ""
        var year = ""
    }

    /// The best image found, or nil if no source had a confident match. Searches under the
    /// English names first, since most sources catalogue those, then under the original title.
    static func find(_ q: Query) async -> Found? {
        if let english = q.inEnglish, let found = await search(english) {
            // The English entry's author is in English; keep the original-language field as it was.
            return Found(image: found.image, year: found.year)
        }
        if let found = await search(q) { return found }
        if let found = await webSearch(q) { return found }
        // Nothing online: the item's own picture on the screenshot, cropped out of the app's
        // interface, is usually the best photo of a café or product.
        guard let shot = q.screenshot else { return nil }
        if let box = parseBox(q.photoBox), let crop = crop(shot, to: box) {
            note("using the item's picture from the screenshot")
            return Found(image: crop)
        }
        // Places imported before the AI marked pictures: guess the main subject. Not for products,
        // whose screenshots are often just comments about them.
        guard q.category == .place, q.photoBox.isEmpty, !q.screenshotIsShared else { return nil }
        return await screenshotCrop(shot).map { Found(image: $0) }
    }

    /// "x,y,w,h" fractions from the top left, if sensible.
    static func parseBox(_ text: String) -> CGRect? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[2] > 0.05, parts[3] > 0.05 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func crop(_ data: Data, to box: CGRect) -> Data? {
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let rect = CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height)
        guard rect.width >= 120, rect.height >= 120, let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped).resized(maxSide: 900).jpegData(compressionQuality: 0.8)
    }

    /// The screenshot cropped to its main subject (the café, the bottle), found with on-device
    /// Vision analysis. Nil when the crop wouldn't take away much of the screen.
    private static func screenshotCrop(_ data: Data) async -> Data? {
        guard let image = UIImage(data: data), let cg = image.cgImage else { return nil }
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil,
              let objects = (request.results?.first)?.salientObjects, !objects.isEmpty else { return nil }
        // Vision's boxes are normalised with the origin at the bottom left.
        let union = objects.map(\.boundingBox).reduce(objects[0].boundingBox) { $0.union($1) }
        let box = union.insetBy(dx: -0.03, dy: -0.03).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard box.width * box.height < 0.8 else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        guard rect.width >= 150, rect.height >= 150, let cropped = cg.cropping(to: rect) else { return nil }
        note("using a crop of the screenshot (\(Int(rect.width))×\(Int(rect.height)))")
        return UIImage(cgImage: cropped).resized(maxSide: 900).jpegData(compressionQuality: 0.8)
    }

    /// Last resort, for things no catalogue lists yet (e.g. a book before its release): Gemini
    /// searches the web for pages about it, and the first whose title matches supplies its
    /// preview image. Only with Gemini as the provider; each search uses the user's key.
    private static func webSearch(_ q: Query) async -> Found? {
        let client = AppSettings.client
        guard q.category != .site, client.provider == .gemini else { return nil }
        let pages: [URL]
        do {
            pages = try await client.findCoverPages(category: q.category.rawValue, title: q.title,
                                                    creator: q.creator, englishTitle: q.englishTitle)
        } catch {
            note("web search for “\(q.title)” failed: \(error)")
            return nil
        }
        note("web search for “\(q.title)” returned \(pages.count) page(s)")
        for page in pages {
            guard let meta = await pageMeta(page) else {
                note("  \(page.absoluteString): couldn't load"); continue
            }
            guard matches(meta.title, q.title, loose: true)
                    || (!q.englishTitle.isEmpty && matches(meta.title, q.englishTitle, loose: true)) else {
                note("  \(page.absoluteString): title “\(meta.title ?? "none")” doesn't match"); continue
            }
            guard let url = meta.image, let image = await download(url) else {
                note("  \(page.absoluteString): no usable image (\(meta.image?.absoluteString ?? "none"))"); continue
            }
            note("  using \(url.absoluteString)")
            return Found(image: image)
        }
        return nil
    }

    private static func search(_ q: Query) async -> Found? {
        // Sources run one after another in this task, so none of these closures cross an isolation boundary.
        func plain(_ source: @escaping (Query) async -> URL?) -> (Query) async -> Hit? {
            { await source($0).map { Hit(url: $0) } }
        }
        let sources: [(Query) async -> Hit?] = switch q.category {
        case .book: [appleBooks, hardcover, openLibrary, plain(googleBooks), plain(litnet), plain(bookcover),
                     plain { await wikipedia($0, hint: "book") }]
        case .manhwa: [plain { await aniList($0, type: "MANGA") }, plain { await aniList($0, type: "MANGA", original: true) },
                       plain { await wikipedia($0, hint: "manhwa") }]
        case .movie: [tmdb, plain { await wikipedia($0, hint: "film") }, plain(tvMaze), plain { await aniList($0, type: "ANIME") },
                      plain { await aniList($0, type: "ANIME", original: true) }]
        case .site: [plain(siteImage)]
        case .place: [placeWebsite, plain { await wikipedia($0, hint: "", strict: true) }]
        case .product: [plain(siteImage), plain { await productDatabase($0, host: "world.openbeautyfacts.org") },
                        plain(foodDatabase)]
        case .other: [plain { await wikipedia($0, hint: "") }]
        }
        for source in sources {
            if let hit = await source(q), let image = await download(hit.url) {
                return Found(image: image, creator: hit.creator, year: hit.year)
            }
        }
        return nil
    }

    // MARK: Sources

    /// Apple Books carries most commercial titles, including recent and indie ones that
    /// Open Library has no cover for.
    private static func appleBooks(_ q: Query) async -> Hit? {
        let term = [q.title, q.creator].filter { !$0.isEmpty }.joined(separator: " ")
        guard let json = await getJSON("https://itunes.apple.com/search", [
            URLQueryItem(name: "term", value: term), URLQueryItem(name: "media", value: "ebook"),
            URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "country", value: storefront(for: q.title)),
        ]), let results = json["results"] as? [[String: Any]] else { return nil }
        let candidates = results.filter { matches($0["trackName"] as? String, q.title) }
        let match = candidates.first { !q.creator.isEmpty && matches($0["artistName"] as? String, q.creator) }
            ?? candidates.first
        // "bb" scales within the box, so the cover keeps its shape.
        guard let match, let art = match["artworkUrl100"] as? String,
              let url = URL(string: art.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")) else { return nil }
        return Hit(url: url, creator: match["artistName"] as? String ?? "",
                   year: String((match["releaseDate"] as? String ?? "").prefix(4)))
    }

    private static func openLibrary(_ q: Query) async -> Hit? {
        var items = [URLQueryItem(name: "title", value: q.title), URLQueryItem(name: "limit", value: "5"),
                     URLQueryItem(name: "fields", value: "title,cover_i,author_name,first_publish_year")]
        if !q.creator.isEmpty { items.append(URLQueryItem(name: "author", value: q.creator)) }
        guard let json = await getJSON("https://openlibrary.org/search.json", items),
              let docs = json["docs"] as? [[String: Any]] else { return nil }
        guard let match = docs.first(where: { ($0["cover_i"] as? Int) != nil && matches($0["title"] as? String, q.title) }),
              let id = match["cover_i"] as? Int,
              let url = URL(string: "https://covers.openlibrary.org/b/id/\(id)-L.jpg") else { return nil }
        return Hit(url: url, creator: (match["author_name"] as? [String] ?? []).joined(separator: " & "),
                   year: (match["first_publish_year"] as? Int).map(String.init) ?? "")
    }

    /// TMDB, the most complete free film and TV catalogue. Needs the user's key; matches on
    /// the English or original title and prefers the release year from the screenshot.
    private static func tmdb(_ q: Query) async -> Hit? {
        let key = AppSettings.coverKey(.tmdb)
        guard !key.isEmpty else { return nil }
        for wanted in [q.title, q.originalTitle] where !wanted.isEmpty {
            var components = URLComponents(string: "https://api.themoviedb.org/3/search/multi")!
            components.queryItems = [URLQueryItem(name: "query", value: wanted), URLQueryItem(name: "include_adult", value: "false")]
            // TMDB hands out a short API key and a long read access token; accept either.
            let isToken = key.count > 40
            if !isToken { components.queryItems?.append(URLQueryItem(name: "api_key", value: key)) }
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            if isToken { request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
            guard let json = await fetchJSON(request) else {
                note("TMDB search for “\(wanted)” failed (check the key)")
                continue
            }
            let results = (json["results"] as? [[String: Any]] ?? []).filter { $0["poster_path"] is String }
            let candidates = results.filter { r in
                [r["title"], r["name"], r["original_title"], r["original_name"]].contains { matches($0 as? String, wanted) }
                    && sameYear((r["release_date"] ?? r["first_air_date"]) as? String, q.year)
            }
            let match = candidates.first { !q.year.isEmpty && ((($0["release_date"] ?? $0["first_air_date"]) as? String) ?? "").hasPrefix(q.year) }
                ?? candidates.first
            if let match, let path = match["poster_path"] as? String,
               let poster = URL(string: "https://image.tmdb.org/t/p/w780\(path)") {
                let date = ((match["release_date"] ?? match["first_air_date"]) as? String) ?? ""
                return Hit(url: poster, year: String(date.prefix(4)))
            }
        }
        return nil
    }

    /// Hardcover, a modern Goodreads alternative with good coverage of indie and BookTok
    /// titles. Needs the user's token.
    private static func hardcover(_ q: Query) async -> Hit? {
        var token = AppSettings.coverKey(.hardcover)
        guard !token.isEmpty else { return nil }
        if !token.lowercased().hasPrefix("bearer ") { token = "Bearer \(token)" }
        let body: [String: Any] = [
            "query": "query($q: String!) { search(query: $q, query_type: \"Book\", per_page: 8, page: 1) { results } }",
            "variables": ["q": [q.title, q.creator].filter { !$0.isEmpty }.joined(separator: " ")],
        ]
        var request = URLRequest(url: URL(string: "https://api.hardcover.app/v1/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(token, forHTTPHeaderField: "authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let json = await fetchJSON(request) else {
            note("Hardcover search for “\(q.title)” failed (check the token)")
            return nil
        }
        let results = ((json["data"] as? [String: Any])?["search"] as? [String: Any])?["results"] as? [String: Any]
        let documents = (results?["hits"] as? [[String: Any]] ?? []).compactMap { $0["document"] as? [String: Any] }
        let candidates = documents.filter { matches($0["title"] as? String, q.title) && ($0["image"] as? [String: Any])?["url"] is String }
        let byAuthor = candidates.first { doc in
            !q.creator.isEmpty && (doc["author_names"] as? [String] ?? []).contains { matches($0, q.creator) }
        }
        guard let match = byAuthor ?? candidates.first,
              let link = (match["image"] as? [String: Any])?["url"] as? String, let url = URL(string: link) else { return nil }
        return Hit(url: url, creator: (match["author_names"] as? [String] ?? []).joined(separator: " & "),
                   year: (match["release_year"] as? Int).map(String.init) ?? "")
    }

    private static func googleBooks(_ q: Query) async -> URL? {
        let search = "intitle:\(q.title)" + (q.creator.isEmpty ? "" : " inauthor:\(q.creator)")
        var items = [URLQueryItem(name: "q", value: search), URLQueryItem(name: "maxResults", value: "5")]
        // Without a key, every app shares one daily quota that's usually used up.
        let key = AppSettings.coverKey(.googleBooks)
        if !key.isEmpty { items.append(URLQueryItem(name: "key", value: key)) }
        guard let json = await getJSON("https://www.googleapis.com/books/v1/volumes", items),
              let items = json["items"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let info = item["volumeInfo"] as? [String: Any], matches(info["title"] as? String, q.title),
                  let thumb = (info["imageLinks"] as? [String: Any])?["thumbnail"] as? String else { continue }
            // Google serves bigger art with zoom=0 than the default thumbnail.
            let large = thumb.replacingOccurrences(of: "http://", with: "https://")
                .replacingOccurrences(of: "zoom=1", with: "zoom=0").replacingOccurrences(of: "&edge=curl", with: "")
            return URL(string: large)
        }
        return nil
    }

    /// `original`: search by the original-language title instead, which AniList always has.
    private static func aniList(_ q: Query, type: String, original: Bool = false) async -> URL? {
        let wanted = original ? q.originalTitle : q.title
        guard !wanted.isEmpty else { return nil }
        let body: [String: Any] = [
            "query": "query($s:String,$t:MediaType){Media(search:$s,type:$t){title{romaji english native} synonyms coverImage{extraLarge large}}}",
            "variables": ["s": wanted, "t": type],
        ]
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let json = await fetchJSON(request),
              let media = (json["data"] as? [String: Any])?["Media"] as? [String: Any] else { return nil }
        // AniList returns its closest match even for titles it doesn't have.
        let titles = Array(((media["title"] as? [String: Any]) ?? [:]).values) + (media["synonyms"] as? [Any] ?? [])
        guard titles.contains(where: { matches($0 as? String, wanted) }),
              let cover = media["coverImage"] as? [String: Any],
              let link = (cover["extraLarge"] as? String) ?? (cover["large"] as? String) else { return nil }
        return URL(string: link)
    }

    /// The official English title AniList lists for a manhwa, manga or anime, looked up by its
    /// original-language title. More reliable than asking a model to translate, which can
    /// confidently name a different series.
    static func aniListEnglishTitle(original: String, category: BookmarkCategory) async -> String? {
        guard category == .manhwa || category == .movie else { return nil }
        // Stray Latin letters typed onto the end of a Korean/Japanese/Chinese title break the search.
        let native = original.replacingOccurrences(of: #"[A-Za-z]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let body: [String: Any] = [
            "query": "query($s:String,$t:MediaType){Media(search:$s,type:$t){title{english native} synonyms}}",
            "variables": ["s": native, "t": category == .manhwa ? "MANGA" : "ANIME"],
        ]
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let json = await fetchJSON(request),
              let media = (json["data"] as? [String: Any])?["Media"] as? [String: Any],
              let titles = media["title"] as? [String: Any],
              // Only trust an exact match on the original title.
              normalized(titles["native"] as? String ?? "") == normalized(native) else { return nil }
        if let english = titles["english"] as? String, !english.isEmpty { return english }
        // No official English release: the first alternative title written in Latin letters.
        return (media["synonyms"] as? [String])?.first { $0.unicodeScalars.allSatisfy { $0.value < 0x250 } }
    }

    /// Bookcover API, a free open-source service that looks up the Goodreads cover; Goodreads
    /// often has covers for indie and upcoming books before stores list them.
    private static func bookcover(_ q: Query) async -> URL? {
        guard !q.creator.isEmpty,
              let json = await getJSON("https://bookcover.longitood.com/bookcover", [
                URLQueryItem(name: "book_title", value: q.title), URLQueryItem(name: "author_name", value: q.creator),
              ]) else { return nil }
        return (json["url"] as? String).flatMap(URL.init(string:))
    }

    private static func tvMaze(_ q: Query) async -> URL? {
        guard let json = await getJSON("https://api.tvmaze.com/singlesearch/shows", [URLQueryItem(name: "q", value: q.title)]),
              matches(json["name"] as? String, q.title),
              // A 2026 film isn't the 2015 series of the same name.
              sameYear(json["premiered"] as? String, q.year),
              let image = json["image"] as? [String: Any] else { return nil }
        return ((image["original"] as? String) ?? (image["medium"] as? String)).flatMap(URL.init(string:))
    }

    /// `strict`: near-exact title only, for places, where loosely similar names are usually
    /// somewhere else entirely.
    private static func wikipedia(_ q: Query, hint: String, strict: Bool = false) async -> URL? {
        let search = [q.title, q.category == .place ? "" : q.creator, hint].filter { !$0.isEmpty }.joined(separator: " ")
        guard let json = await getJSON("https://en.wikipedia.org/w/api.php", [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"), URLQueryItem(name: "gsrsearch", value: search),
            URLQueryItem(name: "gsrlimit", value: "3"), URLQueryItem(name: "prop", value: "pageimages|description"),
            URLQueryItem(name: "piprop", value: "thumbnail"), URLQueryItem(name: "pithumbsize", value: "900"),
            // Posters and book covers are non-free images, which are left out by default.
            URLQueryItem(name: "pilicense", value: "any"),
        ]), let pages = (json["query"] as? [String: Any])?["pages"] as? [String: [String: Any]] else { return nil }
        let ranked = pages.values.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        let match = ranked.first {
            $0["thumbnail"] != nil && matches(($0["title"] as? String).map(withoutParenthetical), q.title)
                && (!strict || similarity(normalized(withoutParenthetical($0["title"] as? String ?? "")), normalized(q.title)) >= 0.9)
                // "2015 British TV series" vs a 2026 bookmark: same name, different thing.
                && sameYear(($0["title"] as? String ?? "") + " " + ($0["description"] as? String ?? ""), q.year)
                // The village of Crookhaven isn't the series Crookhaven.
                && isRightKind(($0["title"] as? String ?? "") + " " + ($0["description"] as? String ?? ""), q.category)
        }
        return ((match?["thumbnail"] as? [String: Any])?["source"] as? String).flatMap(URL.init(string:))
    }

    // MARK: Places

    /// Apple Maps lookup of a place by name and area, built into iOS and keyless.
    private static func mapItem(_ q: Query) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = [q.title, q.location.isEmpty ? q.creator : q.location]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        request.resultTypes = .pointOfInterest
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        // Apple returns its nearest guess; only trust one with the same name.
        return response.mapItems.first { matches($0.name, q.title) }
    }

    /// The place's own website, as listed in Apple Maps (or read off the screenshot): hotels and
    /// cafés usually put a good photo in its share preview.
    private static func placeWebsite(_ q: Query) async -> Hit? {
        let mapsSite = await mapItem(q)?.url
        // Link-in-bio pages only show a profile picture.
        let ownSite = Bookmark.webURL(q.url)
            .flatMap { ["linktr.ee", "instagram.com", "tiktok.com"].contains(where: $0.absoluteString.contains) ? nil : $0 }
        for site in [mapsSite, q.url.isEmpty ? nil : ownSite].compactMap({ $0 }) {
            // A small share image is nearly always the logo, not a photo of the place.
            guard let image = await pageMeta(site)?.image, let data = await download(image),
                  let size = UIImage(data: data)?.size, min(size.width, size.height) >= 300 else { continue }
            return Hit(url: image)
        }
        return nil
    }

    // MARK: Products

    /// Open Beauty Facts (cosmetics, skincare): a free, open product database with photos.
    private static func productDatabase(_ q: Query, host: String) async -> URL? {
        let terms = [q.creator, q.title].filter { !$0.isEmpty }.joined(separator: " ")
        guard let json = await getJSON("https://\(host)/cgi/search.pl", [
            URLQueryItem(name: "search_terms", value: terms), URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "json", value: "1"), URLQueryItem(name: "page_size", value: "8"),
            URLQueryItem(name: "fields", value: "product_name,brands,image_front_url"),
        ]) else { return nil }
        return bestProduct(json["products"] as? [[String: Any]] ?? [], q, brands: { $0["brands"] as? String ?? "" })
    }

    /// Open Food Facts (tea, coffee, food and drink), through its newer search service.
    private static func foodDatabase(_ q: Query) async -> URL? {
        let terms = [q.creator, q.title].filter { !$0.isEmpty }.joined(separator: " ")
        guard let json = await getJSON("https://search.openfoodfacts.org/search", [
            URLQueryItem(name: "q", value: terms), URLQueryItem(name: "page_size", value: "8"),
            URLQueryItem(name: "fields", value: "product_name,brands,image_front_url"),
        ]) else { return nil }
        return bestProduct(json["hits"] as? [[String: Any]] ?? [], q, brands: {
            ($0["brands"] as? [String])?.joined(separator: ", ") ?? ($0["brands"] as? String ?? "")
        })
    }

    /// A product with a photo whose name matches, from the bookmark's brand when one is known.
    private static func bestProduct(_ products: [[String: Any]], _ q: Query,
                                    brands: ([String: Any]) -> String) -> URL? {
        let named = products.filter { ($0["image_front_url"] as? String)?.isEmpty == false
            && matches($0["product_name"] as? String, q.title, loose: true) }
        let match = named.first { q.creator.isEmpty || matches(brands($0), q.creator, loose: true) }
        return (match?["image_front_url"] as? String).flatMap(URL.init(string:))
    }

    /// The page's own share preview (`og:image`), which most sites set to a logo or hero image.
    private static func siteImage(_ q: Query) async -> URL? {
        guard let page = Bookmark.webURL(q.url) else { return nil }
        return await pageMeta(page)?.image
    }

    /// Litnet, the big Russian web-novel site, has many books no store or library lists.
    /// Searched only for Cyrillic titles, once per bookmark, after every other source.
    private static func litnet(_ q: Query) async -> URL? {
        guard storefront(for: q.title) == "ru",
              var components = URLComponents(string: "https://litnet.com/ru/search") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: q.title)]
        guard let search = components.url,
              let (data, _) = await fetch(URLRequest(url: search), limit: 2_000_000, truncate: true) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        let links = matchesOf(#"href="(/ru/book/[a-z0-9-]+-b\d+)""#, in: html)
        var seen = Set<String>()
        // The book page names the title, so check that before trusting its cover.
        for path in links where seen.insert(path).inserted {
            guard seen.count <= 3, let page = URL(string: "https://litnet.com\(path)"),
                  let meta = await pageMeta(page), matches(meta.title, q.title, loose: true) else { continue }
            return meta.image
        }
        return nil
    }

    private static func pageMeta(_ page: URL) async -> (title: String?, image: URL?)? {
        // The share preview tags are in the page's head, so the start of the page is enough.
        guard let (data, _) = await fetch(URLRequest(url: page), limit: 300_000, truncate: true) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        func meta(_ names: [String]) -> String? {
            for name in names {
                let patterns = [#"<meta[^>]+(?:property|name)=["']\#(name)["'][^>]+content=["']([^"']+)"#,
                                #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']\#(name)["']"#]
                for pattern in patterns {
                    if let value = matchesOf(pattern, in: html).first { return value.replacingOccurrences(of: "&amp;", with: "&") }
                }
            }
            return nil
        }
        let image = meta(["og:image", "og:image:url", "twitter:image"]).flatMap { URL(string: $0, relativeTo: page)?.absoluteURL }
        return (meta(["og:title"]), image)
    }

    /// First capture group of every match.
    private static func matchesOf(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: Helpers

    /// Logged to the system log: Xcode's console, or Console.app filtered by category "covers".
    /// Messages name titles and sites, so Release builds keep them private (shown as a hash).
    private static func note(_ message: String) {
        #if DEBUG
        log.info("\(message, privacy: .public)")
        #else
        log.info("\(message, privacy: .private(mask: .hash))")
        #endif
    }

    /// Apple Books catalogues differ by country; a title in another script is best searched
    /// in the store where that language is sold.
    private static func storefront(for title: String) -> String {
        for scalar in title.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF: return "ru"
            case 0xAC00...0xD7AF, 0x1100...0x11FF: return "kr"
            case 0x3040...0x30FF: return "jp"
            case 0x4E00...0x9FFF: return title.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) } ? "jp" : "cn"
            case 0x0E00...0x0E7F: return "th"
            case 0x0590...0x05FF: return "il"
            case 0x0600...0x06FF: return "sa"
            case 0x0370...0x03FF: return "gr"
            default: continue
            }
        }
        return "us"
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        // Open Library and Wikipedia ask clients to identify themselves.
        config.httpAdditionalHeaders = ["User-Agent": "DragonLair/0.1 (iOS bookmark app)"]
        return URLSession(configuration: config)
    }()

    private static func getJSON(_ base: String, _ items: [URLQueryItem]) async -> [String: Any]? {
        var components = URLComponents(string: base)
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        return await fetchJSON(URLRequest(url: url))
    }

    private static func fetchJSON(_ request: URLRequest) async -> [String: Any]? {
        guard let (data, _) = await fetch(request, limit: 5_000_000) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func download(_ url: URL) async -> Data? {
        let data: Data
        if url.scheme == "data" {
            // An image made on the phone (Look Around), passed along inline.
            guard let comma = url.absoluteString.firstIndex(of: ","),
                  let decoded = Data(base64Encoded: String(url.absoluteString[url.absoluteString.index(after: comma)...]))
            else { return nil }
            data = decoded
        } else {
            guard let (fetched, _) = await fetch(URLRequest(url: url), limit: 15_000_000) else { return nil }
            data = fetched
        }
        return downsampledJPEG(data)
    }

    /// Decodes only a small version of the image, so a huge or hostile file can't take the
    /// app's memory. Placeholders (Open Library's 1×1 pixel, tiny icons) aren't worth showing.
    static func downsampledJPEG(_ data: Data, maxSide: Int = 900, minSide: Double = 100) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              min(width, height) >= minSide, width * height <= 200_000_000 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }

    /// GETs a URL, reading at most `limit` bytes so a huge response can't fill memory. Over the
    /// limit, the response is dropped, or with `truncate` its start is kept. Hosts on the local
    /// network are never contacted: their URLs come from screenshots and web pages.
    private static func fetch(_ request: URLRequest, limit: Int, truncate: Bool = false) async -> (Data, HTTPURLResponse)? {
        guard let url = request.url, isPublicWebURL(url),
              let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        if !truncate && http.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(http.expectedContentLength))))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit {
                    bytes.task.cancel()
                    return truncate ? (data, http) : nil
                }
            }
        } catch {
            return nil
        }
        return (data, http)
    }

    /// HTTPS (or HTTP, which App Transport Security then refuses) to a public host name: not
    /// localhost, a .local name or a private, loopback or link-local IP address.
    static func isPublicWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 && host.split(separator: ".").count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return false
            case (172, 16...31), (100, 64...127): return false
            default: return true
            }
        }
        if host.contains(":") {
            // IPv6 literals: loopback, unique local (fc00::/7) and link-local (fe80::/10).
            return !(host == "::1" || host == "::" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8")
                     || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb"))
        }
        return true
    }

    /// Guards against a search returning something else: once case, accents and punctuation
    /// are ignored, one title has to contain the other or be nearly the same ("I Never
    /// Abandoned the Tyrant" / "I Have Never Abandoned the Tyrant").
    /// `loose`: for web page titles, which add "by Author | Shop" around the name.
    static func matches(_ found: String?, _ wanted: String, loose: Bool = false) -> Bool {
        guard let found else { return false }
        let a = normalized(found), b = normalized(wanted)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // A one- or two-letter title would "contain" almost anything.
        guard a == b || min(a.count, b.count) >= 3 else { return false }
        if similarity(a, b) >= 0.8 { return true }
        guard a.contains(b) || b.contains(a) else { return false }
        // "Operation Fortitude" contains "Fortitude" but is something else: the extra words
        // mustn't be most of the title.
        return loose || Double(min(a.count, b.count)) / Double(max(a.count, b.count)) >= 0.6
    }

    /// 1 for identical strings, falling towards 0 the more edits it takes to turn one into the other.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...max(y.count, 1) where !y.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// False only when the text names a year clearly different from the bookmark's. Two years'
    /// slack: the AI's year is sometimes a guess (Crookhaven 2026 read as 2024).
    static func sameYear(_ text: String?, _ year: String) -> Bool {
        guard let wanted = Int(year), let text else { return true }
        let years = matchesOf(#"\b((?:19|20)\d{2})\b"#, in: text).compactMap(Int.init)
        return years.isEmpty || years.contains { abs($0 - wanted) <= 2 }
    }

    /// Whether a Wikipedia page is about the kind of thing the bookmark is, going by its
    /// title and short description ("2026 British television series"). Places and other
    /// bookmarks take any page.
    private static func isRightKind(_ text: String, _ category: BookmarkCategory) -> Bool {
        let words: [String] = switch category {
        case .movie: ["film", "movie", "series", "television", "tv", "show", "anime", "documentary", "miniseries", "sitcom", "drama", "animated"]
        case .book: ["novel", "book", "novella", "memoir", "anthology", "series", "non-fiction", "nonfiction", "poetry", "collection"]
        case .manhwa: ["manhwa", "manga", "manhua", "webtoon", "comic", "webcomic", "light novel", "series", "anime"]
        case .site, .place, .product, .other: []
        }
        guard !words.isEmpty else { return true }
        let lower = text.lowercased()
        return words.contains { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    private static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func withoutParenthetical(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
    }
}
