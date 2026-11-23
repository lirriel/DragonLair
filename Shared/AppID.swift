import Foundation

/// The app's base identifier (APP_ID in Config/Base.xcconfig), read from the AppIdentifier key
/// that both the app's and the share extension's Info.plist carry. The App Group, background
/// task and Keychain names are built from it, so a fork only has to change APP_ID.
enum AppID {
    static let base: String = {
        if let id = Bundle.main.object(forInfoDictionaryKey: "AppIdentifier") as? String, !id.isEmpty {
            return id
        }
        assertionFailure("AppIdentifier is missing from Info.plist")
        return "com.lirriel.endlessbookmark"
    }()
}
