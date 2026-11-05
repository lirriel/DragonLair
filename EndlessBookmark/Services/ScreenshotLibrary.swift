import Foundation
import OSLog
import Photos
import UIKit

private let log = Logger(subsystem: "com.lirriel.endlessbookmark", category: "photos")

/// Reads the system Screenshots album directly, for period imports and watching.
enum ScreenshotLibrary {
    static var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    static var canRead: Bool { status == .authorized || status == .limited }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Local identifiers of screenshots taken in the range, oldest first.
    static func assetIDs(from start: Date, to end: Date = .distantFuture) -> [String] {
        guard canRead,
              let album = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumScreenshots, options: nil).firstObject
        else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                        start as NSDate, end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var ids: [String] = []
        PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    /// Which of these screenshots are still in Photos (not deleted or out of a limited selection).
    static func existing(_ ids: [String]) -> [String] {
        guard canRead, !ids.isEmpty else { return [] }
        var found: [String] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            found.append(asset.localIdentifier)
        }
        return found
    }

    struct DeleteResult {
        /// Moved to Recently Deleted.
        var deleted: [String] = []
        /// Not visible to the app: already deleted, or outside a limited photo selection.
        var notFound: [String] = []
        /// The user tapped "Don't Allow" in iOS's confirmation.
        var declined = false

        /// What to tell the user when not everything was deleted, or nil if it all went.
        var problem: String? {
            guard !notFound.isEmpty else { return nil }
            let count = "\(notFound.count) screenshot\(notFound.count == 1 ? "" : "s")"
            return status == .limited
                ? "\(count) couldn't be deleted: Dragon Lair only has access to selected photos. Allow Full Access in Settings → Dragon Lair → Photos."
                : "\(count) couldn't be found in Photos; they may already be deleted."
        }
    }

    /// Moves screenshots to Recently Deleted. iOS asks the user to confirm, which it can only do
    /// while the app is on screen. Throws on real failures.
    static func delete(_ ids: [String]) async throws -> DeleteResult {
        if !canRead { _ = await requestAccess() }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var found: [String] = []
        assets.enumerateObjects { asset, _, _ in found.append(asset.localIdentifier) }
        var result = DeleteResult(notFound: ids.filter { !found.contains($0) })
        log.info("Delete: \(ids.count) requested, \(found.count) found, access \(String(describing: status.rawValue), privacy: .public)")
        guard !found.isEmpty else {
            log.error("Delete: none of the \(ids.count) screenshots are visible to the app")
            return result
        }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            result.deleted = found
            log.info("Delete: moved \(found.count) to Recently Deleted")
        } catch where (error as NSError).code == PHPhotosError.userCancelled.rawValue {
            result.declined = true
            log.info("Delete: the user declined")
        } catch {
            log.error("Delete failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        return result
    }

    /// A small preview for the review grid, or nil if the screenshot is gone.
    static func thumbnail(for id: String, side: CGFloat = 300) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat // one callback, so the continuation resumes once
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side * 2),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    static func imageData(for id: String) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw CocoaError(.fileNoSuchFile)
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true // screenshots may only be in iCloud
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: info?[PHImageErrorKey] as? Error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}

/// Calls `onChange` whenever the photo library changes while the app is running.
final class ScreenshotWatcher: NSObject, PHPhotoLibraryChangeObserver {
    var onChange: (@MainActor () -> Void)?
    private var registered = false

    func start() {
        guard !registered else { return }
        PHPhotoLibrary.shared().register(self)
        registered = true
    }

    func stop() {
        guard registered else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        registered = false
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.onChange?() }
    }
}
