import Foundation
import os

/// One thing recognised on a screenshot. A single screenshot can contain several
/// (e.g. a "top 10 manhwa" list), so the AI returns an array.
struct ExtractedItem: Codable, Sendable {
    var category: String
    var title: String
    var creator: String
    var year: String
    var summary: String
    var url: String
    var location: String
    var tags: [String]
    var englishTitle: String
    var englishCreator: String
    /// Where this item's own picture is on the screenshot, "x,y,width,height" as fractions,
    /// or "" when it isn't pictured.
    var photoBox: String
}

private struct ExtractionResult: Codable {
    var items: [ExtractedItem]
}

/// English names for a bookmark saved under a title in another language.
struct Translation: Codable, Sendable {
    var id: Int
    var englishTitle: String
    var englishCreator: String
}

private struct TranslationResult: Codable {
    var items: [Translation]
}

enum AIProviderKind: String, CaseIterable, Identifiable {
    case claude, openai, gemini
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude (Anthropic)"
        case .openai: "ChatGPT (OpenAI)"
        case .gemini: "Gemini (Google)"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: "claude-opus-5-5"
        case .openai: "gpt-5"
        // Reading a screenshot doesn't need a bigger model, and Lite is rarely overloaded.
        case .gemini: AIClient.geminiFallbackModel
        }
    }

    var keyHint: String {
        switch self {
        case .claude: "sk-ant-…"
        case .openai: "sk-…"
        case .gemini: "AIza…"
        }
    }

    /// The provider's page for creating API keys.
    var keyURL: URL {
        switch self {
        case .claude: URL(string: "https://platform.claude.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    var keySteps: String {
        switch self {
        case .claude:
            "Sign in to the Claude Console, tap Create Key, then copy it. Add a few dollars of credit under Billing; API use isn't covered by a Claude subscription."
        case .openai:
            "Sign in to the OpenAI Platform, tap Create new secret key, then copy it. Add a payment method under Billing; API use isn't covered by ChatGPT Plus."
        case .gemini:
            "Sign in to Google AI Studio with your Google account, tap Create API key, then copy it. There's a free tier, so no card is needed to start."
        }
    }
}

enum AIError: LocalizedError {
    case missingKey
    case http(Int, String)
    case refused(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add an API key in Settings first."
        case .http(429, _), .http(500..., _):
            "The AI service is busy right now. Tap Retry in a few minutes."
        case .http(let code, let body): "API error \(code): \(body.prefix(300))"
        case .refused(let why): "The model declined this screenshot. \(why)"
        case .badResponse(let why): "Couldn't read the AI response: \(why)"
        }
    }
}

enum Prompt {
    static let system = """
    You turn phone screenshots into a personal bookmark collection. Look at the screenshot \
    and list every distinct thing the user probably wanted to save for later:
    - book: novels, non-fiction, light novels, audiobooks
    - manhwa: manhwa, manga, manhua, webtoons, webcomics
    - movie: films, TV series, anime, documentaries
    - site: websites, apps, online tools, articles, recipes, courses, YouTube channels
    - place: restaurants, cafes, shops, attractions, cities, hotels, events with a venue
    - product: things to buy or try: skincare, makeup, perfume, tea, coffee, food and drink, \
    clothes, shoes, accessories, gadgets, home goods. Not books, comics, films, apps or sites, \
    which have their own categories. creator = the brand; title = the product's name.
    - other: anything worth saving that fits none of the above
    Rules:
    - Ignore phone UI chrome (status bar, keyboard, nav bars, ads) unless it is the subject.
    - But do read text that names the subject: captions, hashtags, comments, and search bars or \
    search suggestions (e.g. TikTok's "Search · <title>" bar under a video). A video showing a \
    book cover with such a caption is about that book.
    - Any text that names a work counts: on-screen titles, captions, hashtags, comments, \
    watermarks, search bars and search suggestions. Use it even if it's small or partly hidden.
    - Only when nothing on screen names it, don't guess a title from the artwork or art style.
    - If something is clearly being recommended but only identified by a code or where to find \
    it (e.g. "Search 141456 on webcomics app"), still include it: title = that hint, like \
    "WebComics #141456", and say in the summary how to find it.
    - title: the proper name of the work/site/place, not a description.
    - A series (book series, manga series, film franchise) is not an item: save its first \
    instalment instead, the one marked "Book one"/"Vol. 1" or the earliest, under that \
    instalment's own title, and name the series in the summary and as a tag. If only the series \
    name is visible, use the first instalment's title if you reliably know it.
    - creator: author, artist, director or studio; for places the city/area if no address.
    - year: release/publication year if visible or well known, else "".
    - summary: one or two sentences on what it is and why it looks interesting.
    - url: a URL visible in the screenshot, or the obvious official domain for a site; else "".
    - location: address or "City, Country" for places; else "".
    - tags: 1-5 short lowercase tags such as genre or cuisine.
    - photoBox: if the screenshot shows a photo or picture of this specific item (its cover, \
    the product itself, the place itself), its box as "x,y,width,height", fractions of the whole \
    screenshot from the top left, e.g. "0.1,0.2,0.5,0.4". "" if the item isn't pictured, or the \
    only picture is shared with other items or shows something else.
    - englishTitle / englishCreator: when title or creator isn't in English, the name of the \
    official English edition if one exists, else a faithful English translation of the title and \
    the usual Latin spelling of the name. One title only, never a list of alternatives. "" when it \
    is already English.
    - Use "" for unknown fields. Never invent details you can't see or don't reliably know.
    - If nothing worth saving is visible, return an empty items array.
    """

    static let user = "Extract the bookmarks from this screenshot."

    static let translateSystem = """
    You help find cover art for saved books, comics, films and places. For each item, give the \
    title and creator as officially published in English if an English edition exists; otherwise \
    a faithful English translation of the title and the usual Latin spelling of the creator's \
    name. Give exactly one title, the best-known official one, never a list of alternatives. \
    Use "" for a field that is already in English or empty. Keep each item's id.
    """

    // Never changed after it's built; [String: Any] just can't say so to the compiler.
    nonisolated(unsafe) static let translateSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["items"],
        "properties": [
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "englishTitle", "englishCreator"],
                    "properties": [
                        "id": ["type": "integer"],
                        "englishTitle": ["type": "string"],
                        "englishCreator": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]


    /// Every field is required and non-null so the same schema works with both
    /// Anthropic structured outputs and OpenAI strict json_schema mode. Gemini gets a copy
    /// without `additionalProperties`, which its OpenAPI-style schema doesn't accept.
    // Never changed after it's built; [String: Any] just can't say so to the compiler.
    nonisolated(unsafe) static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["items"],
        "properties": [
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["category", "title", "creator", "year", "summary", "url", "location", "tags",
                                 "englishTitle", "englishCreator", "photoBox"],
                    "properties": [
                        "category": ["type": "string", "enum": BookmarkCategory.allCases.map(\.rawValue)],
                        "title": ["type": "string"],
                        "creator": ["type": "string"],
                        "year": ["type": "string"],
                        "summary": ["type": "string"],
                        "url": ["type": "string"],
                        "location": ["type": "string"],
                        "tags": ["type": "array", "items": ["type": "string"]],
                        "englishTitle": ["type": "string"],
                        "englishCreator": ["type": "string"],
                        "photoBox": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]
}

struct AIClient: Sendable {
    let provider: AIProviderKind
    let apiKey: String
    let model: String

    /// One request: instructions, the user's message, an optional screenshot, and the JSON
    /// shape the answer must follow.
    struct Ask {
        var system: String
        var user: String
        var jpeg: Data?
        var schema: [String: Any]
    }

    func extract(jpeg: Data) async throws -> [ExtractedItem] {
        let ask = Ask(system: Prompt.system, user: Prompt.user, jpeg: jpeg, schema: Prompt.schema)
        return try decode(ExtractionResult.self, from: await call(ask)).items
    }

    /// Text only: English names for titles saved in another language.
    func translate(_ items: [(id: Int, category: String, title: String, creator: String)]) async throws -> [Translation] {
        let list = items.map { ["id": $0.id, "category": $0.category, "title": $0.title, "creator": $0.creator] }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)
        let ask = Ask(system: Prompt.translateSystem, user: json, schema: Prompt.translateSchema)
        return try decode(TranslationResult.self, from: await call(ask)).items
    }

    /// Gemini only: searches the web (Google Search grounding) for pages showing the cover of
    /// a work the free catalogues don't have yet, such as an upcoming book. Returns page
    /// links, best first; the caller checks each page's title before using its image.
    func findCoverPages(category: String, title: String, creator: String, englishTitle: String) async throws -> [URL] {
        guard provider == .gemini else { return [] }
        guard !apiKey.isEmpty else { throw AIError.missingKey }
        let work = [title, englishTitle.isEmpty || englishTitle == title ? "" : "(in English: \(englishTitle))",
                    creator.isEmpty ? "" : "by \(creator)"].filter { !$0.isEmpty }.joined(separator: " ")
        let prompt = """
        Search the web for pages that show the cover art or poster of this \(category): \(work). \
        Prefer store, publisher, audiobook, Goodreads or database pages about exactly this work \
        (any edition, including upcoming releases). Reply with up to 3 page URLs, one per line, nothing else.
        """
        let path = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: path) else { throw AIError.badResponse("invalid model name") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "tools": [["google_search": [String: Any]()]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": "low"]],
        ]
        // No retries: the usual failure here is the search quota, which waiting seconds won't fix.
        let response = try await send(request, body: body, retrying: false)
        let candidate = (response["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        let named = text.split(whereSeparator: \.isWhitespace).compactMap { word -> URL? in
            let link = word.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]\"',.*"))
            return link.hasPrefix("http") ? URL(string: link) : nil
        }
        // The pages the search actually used; Google serves these as redirect links.
        let chunks = (candidate?["groundingMetadata"] as? [String: Any])?["groundingChunks"] as? [[String: Any]] ?? []
        let grounded = chunks.compactMap { ($0["web"] as? [String: Any])?["uri"] as? String }.compactMap(URL.init(string:))
        return Array((named + grounded).prefix(6))
    }

    private func call(_ ask: Ask) async throws -> String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-stubAI") { return try await Self.stubAnswer(ask) }
        #endif
        guard !apiKey.isEmpty else { throw AIError.missingKey }
        return switch provider {
        case .claude: try await callClaude(ask)
        case .openai: try await callOpenAI(ask)
        case .gemini: try await callGeminiWithFallback(ask)
        }
    }

    #if DEBUG
    /// Launch with `-stubAI` to try imports without an API key or network: each screenshot
    /// takes a few seconds and becomes one made-up bookmark.
    private static func stubAnswer(_ ask: Ask) async throws -> String {
        guard ask.jpeg != nil else { return #"{"items":[]}"# }
        try await Task.sleep(for: .seconds(4))
        let item = ExtractedItem(category: "other", title: "Stub find \(UUID().uuidString.prefix(4))", creator: "",
                                 year: "", summary: "Made up by -stubAI.", url: "", location: "", tags: ["stub"],
                                 englishTitle: "", englishCreator: "", photoBox: "")
        return String(decoding: try JSONEncoder().encode(ExtractionResult(items: [item])), as: UTF8.self)
    }
    #endif

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw AIError.badResponse(error.localizedDescription)
        }
    }

    // MARK: Anthropic Messages API

    private func callClaude(_ ask: Ask) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Lets the API retry on a fallback model if a safety classifier declines.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "fallbacks": "default",
            "system": ask.system,
            "output_config": ["format": ["type": "json_schema", "schema": ask.schema]],
            "messages": [[
                "role": "user",
                "content": (ask.jpeg.map { [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                                        "data": $0.base64EncodedString()]]] } ?? [])
                    + [["type": "text", "text": ask.user]],
            ]],
        ]
        let response = try await send(request, body: body)

        if response["stop_reason"] as? String == "refusal" {
            let details = response["stop_details"] as? [String: Any]
            throw AIError.refused(details?["explanation"] as? String ?? "")
        }
        let blocks = response["content"] as? [[String: Any]] ?? []
        // Thinking blocks may come first; the JSON is in the text block.
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw AIError.badResponse("no text block")
        }
        return text
    }

    // MARK: OpenAI Chat Completions API

    private func callOpenAI(_ ask: Ask) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": ask.system],
                ["role": "user", "content": [["type": "text", "text": ask.user]]
                    + (ask.jpeg.map { [["type": "image_url",
                                        "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]] } ?? [])],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "result", "strict": true, "schema": ask.schema],
            ],
        ]
        let response = try await send(request, body: body)

        let message = (response["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        if let refusal = message?["refusal"] as? String { throw AIError.refused(refusal) }
        guard let text = message?["content"] as? String else { throw AIError.badResponse("no message content") }
        return text
    }

    // MARK: Gemini generateContent API

    /// The default, and what a bigger Gemini model the user picked falls back to when it's overloaded.
    static let geminiFallbackModel = "gemini-flash-lite-latest"

    private func callGeminiWithFallback(_ ask: Ask) async throws -> String {
        guard model != Self.geminiFallbackModel else { return try await callGemini(ask, model: model) }
        // One quick try on the chosen model; when it's busy, the fallback gets the retries.
        do {
            return try await callGemini(ask, model: model, timeout: 45, retrying: false)
        } catch let error where Self.isBusy(error) {
            importLog.notice("\(model, privacy: .public) still busy, trying \(Self.geminiFallbackModel, privacy: .public)")
            return try await callGemini(ask, model: Self.geminiFallbackModel)
        }
    }

    private static func isBusy(_ error: Error) -> Bool {
        switch error {
        case AIError.http(let status, _): status == 429 || status >= 500
        case let error as URLError: error.code == .timedOut
        default: false
        }
    }

    private func callGemini(_ ask: Ask, model: String, timeout: TimeInterval = 90,
                            retrying: Bool = true) async throws -> String {
        let path = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: path) else { throw AIError.badResponse("invalid model name") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Short, so a stalled request gets retried rather than hanging for minutes.
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": ask.system]]],
            "contents": [[
                "role": "user",
                "parts": (ask.jpeg.map { [["inlineData": ["mimeType": "image/jpeg", "data": $0.base64EncodedString()]]] } ?? [])
                    + [["text": ask.user]],
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": Self.withoutAdditionalProperties(ask.schema),
                // Default thinking can run for minutes on a busy screenshot; reading it doesn't need it.
                "thinkingConfig": ["thinkingLevel": "low"],
            ],
        ]
        let response = try await send(request, body: body, retrying: retrying)

        if let blocked = (response["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            throw AIError.refused(blocked)
        }
        let candidate = (response["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        // Thought parts may come first; the JSON is in the remaining text.
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            let reason = candidate?["finishReason"] as? String ?? "no text in response"
            if ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION"].contains(reason) {
                throw AIError.refused(reason)
            }
            throw AIError.badResponse(reason)
        }
        return text
    }

    private static func withoutAdditionalProperties(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.filter { $0.key != "additionalProperties" }.mapValues(withoutAdditionalProperties)
        }
        if let array = value as? [Any] { return array.map(withoutAdditionalProperties) }
        return value
    }

    private func send(_ request: URLRequest, body: [String: Any], retrying: Bool = true) async throws -> [String: Any] {
        var request = request
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await sendRetrying(request, retrying: retrying)
        guard status == 200 else { throw AIError.http(status, String(decoding: data, as: UTF8.self)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse("not a JSON object")
        }
        return json
    }

    /// Providers turn requests away or stall when overloaded; that usually passes within
    /// seconds, so busy responses and timeouts are retried a few times before giving up.
    private func sendRetrying(_ request: URLRequest, retrying: Bool) async throws -> (Data, Int) {
        let waits: [Duration] = retrying ? [.seconds(3), .seconds(10), .seconds(30)] : []
        for attempt in 0... {
            let isLast = attempt == waits.count
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if isLast || !(status == 429 || status >= 500) { return (data, status) }
                importLog.notice("\(provider.rawValue, privacy: .public) busy (\(status)), retrying")
            } catch let error as URLError where !isLast && [.timedOut, .networkConnectionLost].contains(error.code) {
                importLog.notice("\(provider.rawValue, privacy: .public) network error \(error.code.rawValue), retrying")
            }
            try await Task.sleep(for: waits[attempt])
        }
        fatalError("unreachable")
    }
}
