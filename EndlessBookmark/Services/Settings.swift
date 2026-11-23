import Foundation
import os
import Security

/// Optional catalogues that need a free personal key and find covers the keyless ones miss.
enum CoverService: String, CaseIterable, Identifiable {
    case tmdb, hardcover, googleBooks
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tmdb: "TMDB"
        case .hardcover: "Hardcover"
        case .googleBooks: "Google Books"
        }
    }

    var purpose: String {
        switch self {
        case .tmdb: "Official posters for movies, series and anime."
        case .hardcover: "Covers for indie, BookTok and new books."
        case .googleBooks: "Book covers, including many Kindle titles."
        }
    }

    var keyHint: String {
        switch self {
        case .tmdb: "API key or read access token"
        case .hardcover: "Bearer eyJ…"
        case .googleBooks: "AIza…"
        }
    }

    var keyURL: URL {
        switch self {
        case .tmdb: URL(string: "https://www.themoviedb.org/settings/api")!
        case .hardcover: URL(string: "https://hardcover.app/account/api")!
        case .googleBooks: URL(string: "https://console.cloud.google.com/apis/library/books.googleapis.com")!
        }
    }

    var keySteps: String {
        switch self {
        case .tmdb:
            "Create a free TMDB account, open Settings → API, request a key for personal use and copy the API key."
        case .hardcover:
            "Create a free Hardcover account, open Settings → Hardcover API and copy the token."
        case .googleBooks:
            "In Google Cloud, enable the Books API for a project (your Gemini key's project works), then copy an API key from Credentials."
        }
    }
}

/// API keys live in the Keychain; provider and model choice in UserDefaults.
enum AppSettings {
    private static let providerKey = "provider"

    static var provider: AIProviderKind {
        get { AIProviderKind(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    static func model(for provider: AIProviderKind) -> String {
        let saved = UserDefaults.standard.string(forKey: "model.\(provider.rawValue)") ?? ""
        return saved.isEmpty ? provider.defaultModel : saved
    }

    static func setModel(_ model: String, for provider: AIProviderKind) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: "model.\(provider.rawValue)")
    }

    static func apiKey(for provider: AIProviderKind) -> String {
        Keychain.read(account: provider.rawValue) ?? ""
    }

    /// False when the Keychain refused the change, so the caller can say so.
    @discardableResult
    static func setAPIKey(_ key: String, for provider: AIProviderKind) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Keychain.delete(account: provider.rawValue) : Keychain.write(trimmed, account: provider.rawValue)
    }

    static func coverKey(_ service: CoverService) -> String {
        Keychain.read(account: "cover.\(service.rawValue)") ?? ""
    }

    static func setCoverKey(_ key: String, for service: CoverService) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != coverKey(service) else { return }
        let account = "cover.\(service.rawValue)"
        guard trimmed.isEmpty ? Keychain.delete(account: account) : Keychain.write(trimmed, account: account) else { return }
        // A new source may have what the others didn't.
        retryMissingCovers = true
    }

    /// Set when a cover source is added; bookmarks without a cover are searched again.
    static var retryMissingCovers: Bool {
        get { UserDefaults.standard.bool(forKey: "retryMissingCovers") }
        set { UserDefaults.standard.set(newValue, forKey: "retryMissingCovers") }
    }

    /// Watching collects new screenshots for review rather than importing them all. On unless
    /// turned off (stored inverted so the default is "ask").
    static var askBeforeImportingWatched: Bool {
        get { !UserDefaults.standard.bool(forKey: "importWatchedWithoutAsking") }
        set { UserDefaults.standard.set(!newValue, forKey: "importWatchedWithoutAsking") }
    }

    static var watchScreenshots: Bool {
        get { UserDefaults.standard.bool(forKey: "watchScreenshots") }
        set { UserDefaults.standard.set(newValue, forKey: "watchScreenshots") }
    }

    /// Watching only picks up screenshots taken after this moment.
    static var watchSince: Date {
        get { UserDefaults.standard.object(forKey: "watchSince") as? Date ?? .now }
        set { UserDefaults.standard.set(newValue, forKey: "watchSince") }
    }

    static var deleteOriginalsAfterImport: Bool {
        get { UserDefaults.standard.bool(forKey: "deleteOriginalsAfterImport") }
        set { UserDefaults.standard.set(newValue, forKey: "deleteOriginalsAfterImport") }
    }

    /// Security-scoped bookmark to the backup folder the user picked.
    static var backupFolderBookmark: Data? {
        get { UserDefaults.standard.data(forKey: "backupFolderBookmark") }
        set { UserDefaults.standard.set(newValue, forKey: "backupFolderBookmark") }
    }

    static var coverSourcesVersion: Int {
        get { UserDefaults.standard.integer(forKey: "coverSourcesVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "coverSourcesVersion") }
    }

    static var lastBackupAt: Date? {
        get { UserDefaults.standard.object(forKey: "lastBackupAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastBackupAt") }
    }

    static var lastBackupError: String? {
        get { UserDefaults.standard.string(forKey: "lastBackupError") }
        set { UserDefaults.standard.set(newValue, forKey: "lastBackupError") }
    }

    static var client: AIClient {
        let p = provider
        return AIClient(provider: p, apiKey: apiKey(for: p), model: model(for: p))
    }
}

private let keychainLog = Logger(subsystem: "com.lirriel.endlessbookmark", category: "keychain")

enum Keychain {
    private static let service = "com.lirriel.endlessbookmark.apikeys"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Updates the key in place, or adds it. Readable after the first unlock (background imports
    /// need it), and only on this device, so it never goes into backups. False on failure.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(attributes) { $1 } as CFDictionary, nil)
        }
        if status != errSecSuccess { keychainLog.error("Saving a key failed: OSStatus \(status)") }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            keychainLog.error("Deleting a key failed: OSStatus \(status)")
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
