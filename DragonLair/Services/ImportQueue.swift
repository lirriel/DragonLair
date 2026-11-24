import CryptoKit
import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import os

/// Import pipeline and AI calls. Filter Console.app by category "import" to follow an import.
let importLog = Logger(subsystem: "com.lirriel.dragonlair", category: "import")

/// Processes picked screenshots one at a time and turns them into bookmarks.
@MainActor
@Observable
final class ImportQueue {
    struct Job: Identifiable {
        enum State: Equatable {
            /// `notes` explain items that weren't added because they already exist.
            case waiting, working, done(added: Int, notes: [String]), skipped, failed(String)
            /// The AI read it but named nothing to save. Not a success: the user may want to
            /// read it again.
            case nothingFound
        }
        enum Source {
            case picker(PhotosPickerItem)
            /// A file the share extension left in the shared inbox.
            case inbox(URL)
            /// A screenshot read straight from the Photos library (period import or watching).
            case asset(String)
        }
        let id = UUID()
        let source: Source
        var thumbnail: UIImage?
        /// Medium-size JPEG for the long-press preview in Imports (and what bookmarks keep).
        var previewData: Data?
        var state: State = .waiting
        var originalDeleted = false
        /// Kept after "nothing found" so it can be read again, even once a shared file is gone.
        var imageData: Data?
        /// Set by "Read again": read it even if it was read before.
        var forceRead = false

        var isFailed: Bool { if case .failed = state { true } else { false } }

        var assetID: String? {
            switch source {
            case .asset(let id): id
            case .picker(let item): item.itemIdentifier
            case .inbox: nil
            }
        }

        /// Only screenshots whose content is now in the collection are safe to delete:
        /// ones that added or matched a bookmark, or were imported before.
        var originalCanBeDeleted: Bool {
            guard !originalDeleted, assetID != nil else { return false }
            switch state {
            case .done(let added, let notes): return added > 0 || !notes.isEmpty
            case .skipped: return true
            default: return false
            }
        }
    }

    var jobs: [Job] = []
    /// Set by tests: replaces reading a screenshot, and skips the background task and the cover
    /// search, backup and deletion that follow a run.
    private let testProcess: (@MainActor (Job, ModelContext) async -> Job.State)?

    init(testProcess: (@MainActor (Job, ModelContext) async -> Job.State)? = nil) {
        self.testProcess = testProcess
    }

    /// New screenshots found by watching, waiting for the user to pick which to import. Nothing
    /// is sent to the AI until they do.
    var pendingReview: [String] = []
    var deleteError: String?
    /// A delete asked for while the app was in the background, where iOS can't show its
    /// confirmation; it runs the next time the app is opened.
    private var deletionPending = false
    private var isRunning = false
    private let watcher = ScreenshotWatcher()
    private let background = BackgroundImport()
    let covers = CoverFinder()

    var isBusy: Bool { jobs.contains { $0.state == .waiting || $0.state == .working } }
    var finishedCount: Int { jobs.filter { $0.state != .waiting && $0.state != .working }.count }
    var failedCount: Int { jobs.filter(\.isFailed).count }
    var nothingFoundCount: Int { jobs.filter { $0.state == .nothingFound }.count }
    /// The most recent error, shown in the banner so failures aren't missed.
    var lastError: String? {
        jobs.last { $0.isFailed }.flatMap { if case .failed(let message) = $0.state { message } else { nil } }
    }
    var deletableCount: Int { jobs.filter(\.originalCanBeDeleted).count }

    /// Moves imported originals to Recently Deleted in Photos. iOS asks the user to confirm.
    func deleteOriginals() async {
        let ids = jobs.filter(\.originalCanBeDeleted).compactMap(\.assetID)
        guard !ids.isEmpty else { return }
        guard UIApplication.shared.applicationState == .active else {
            uiLog.info("Deleting \(ids.count) originals once the app is back on screen")
            deletionPending = true
            return
        }
        deletionPending = false
        do {
            let result = try await ScreenshotLibrary.delete(ids)
            // Only what was really deleted; declining the system confirmation isn't an error.
            for i in jobs.indices where jobs[i].assetID.map(result.deleted.contains) == true {
                jobs[i].originalDeleted = true
            }
            deleteError = result.problem
        } catch {
            deleteError = "Couldn't delete the original screenshots: \(error.localizedDescription)"
        }
    }

    /// Runs a delete that was put off while the app was in the background.
    func deleteOriginalsIfPending() async {
        guard deletionPending else { return }
        await deleteOriginals()
    }

    func enqueue(_ items: [PhotosPickerItem], context: ModelContext) {
        jobs.append(contentsOf: items.map { Job(source: .picker($0)) })
        start(context: context)
    }

    /// Queues screenshots shared from other apps that aren't already queued.
    func importInbox(context: ModelContext) {
        let queued = Set(jobs.compactMap { job -> URL? in
            if case .inbox(let url) = job.source { url } else { nil }
        })
        let new = SharedInbox.pending().filter { !queued.contains($0) }
        guard !new.isEmpty else { return }
        jobs.append(contentsOf: new.map { Job(source: .inbox($0)) })
        start(context: context)
    }

    /// Screenshots in the range that were never scanned and aren't queued right now.
    func newScreenshotIDs(from start: Date, to end: Date = .distantFuture, context: ModelContext) -> [String] {
        unhandled(ScreenshotLibrary.assetIDs(from: start, to: end), context: context)
    }

    /// The Photos screenshots that aren't queued, waiting for review, or handled before
    /// (imported or skipped).
    func unhandled(_ ids: [String], context: ModelContext) -> [String] {
        let queued = Set(jobs.compactMap { job -> String? in
            if case .asset(let id) = job.source { id } else { nil }
        })
        let scanned = Set(((try? context.fetch(FetchDescriptor<ScannedImage>())) ?? []).map(\.key))
        let pending = Set(pendingReview)
        return ids.filter { !queued.contains($0) && !pending.contains($0) && !scanned.contains("asset:\($0)") }
    }

    func importScreenshots(ids: [String], context: ModelContext) {
        guard !ids.isEmpty else { return }
        jobs.append(contentsOf: ids.map { Job(source: .asset($0)) })
        start(context: context)
    }

    /// Starts or stops watching the Screenshots album to match Settings, and catches up on
    /// anything taken since watching began (e.g. while the app was closed).
    func refreshWatching(context: ModelContext) {
        guard AppSettings.watchScreenshots, ScreenshotLibrary.canRead else {
            watcher.stop()
            return
        }
        watcher.onChange = { [weak self] in self?.scanWatched(context: context) }
        watcher.start()
        scanWatched(context: context)
    }

    private func scanWatched(context: ModelContext) {
        let new = newScreenshotIDs(from: AppSettings.watchSince, context: context)
        guard !new.isEmpty else { return }
        if AppSettings.askBeforeImportingWatched {
            uiLog.info("\(new.count) new screenshot(s) waiting for review")
            pendingReview.append(contentsOf: new)
        } else {
            importScreenshots(ids: new, context: context)
        }
    }

    /// Imports the reviewed screenshots the user picked.
    func approve(_ ids: [String], context: ModelContext) {
        pendingReview.removeAll { ids.contains($0) }
        uiLog.info("Importing \(ids.count) reviewed screenshot(s)")
        importScreenshots(ids: ids, context: context)
    }

    /// Skips reviewed screenshots for good: they're marked as handled, so watching doesn't
    /// offer them again.
    func skip(_ ids: [String], context: ModelContext) {
        pendingReview.removeAll { ids.contains($0) }
        uiLog.info("Skipping \(ids.count) screenshot(s)")
        for id in ids { context.insert(ScannedImage(key: "asset:\(id)")) }
        try? context.save()
    }

    /// Picks up screenshots left waiting when a background run was stopped.
    func resume(context: ModelContext) {
        if jobs.contains(where: { $0.state == .waiting }) { start(context: context) }
    }

    /// Sends a screenshot where nothing was found to the AI again.
    func readAgain(_ id: Job.ID, context: ModelContext) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        uiLog.info("Reading a screenshot again after nothing was found")
        jobs[index].forceRead = true
        jobs[index].state = .waiting
        start(context: context)
    }

    func retryFailed(context: ModelContext) {
        for i in jobs.indices where jobs[i].isFailed { jobs[i].state = .waiting }
        start(context: context)
    }

    private func start(context: ModelContext) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await run(context: context)
            isRunning = false
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state != .waiting && $0.state != .working }
    }

    private func run(context: ModelContext) async {
        let isTest = testProcess != nil
        if !isTest { background.begin(total: jobs.filter { $0.state == .waiting }.count) }
        defer { if !isTest { background.end() } }
        // Stopping (by iOS or from the progress indicator) leaves the rest waiting for next time.
        // Jobs are found again by ID after every await: "Clear finished" can remove rows while
        // the AI is reading, which moves every row after them up.
        while !background.isCancelled, let next = jobs.first(where: { $0.state == .waiting }) {
            updateJob(next.id) { $0.state = .working }
            let state = if let testProcess { await testProcess(next, context) } else { await process(next, context: context) }
            updateJob(next.id) { $0.state = state }
            background.progress(remaining: jobs.filter { $0.state == .waiting }.count)
            switch Self.cleanup(after: state, of: next.source) {
            case .keep: break
            case .removeSharedFile(let url): SharedInbox.remove(url)
            case .markScanned(let key): markScanned(key, context: context)
            }
        }
        guard !isTest else { return }
        await covers.find(context: context)
        Backup.autoBackup(context: context)
        if AppSettings.deleteOriginalsAfterImport { await deleteOriginals() }
    }

    enum Cleanup: Equatable {
        case keep, removeSharedFile(URL), markScanned(String)
    }

    /// What happens to a screenshot's source once it's processed. A failed one is kept and not
    /// marked as handled, so it's tried again later: a shared file stays in the inbox, and a
    /// screenshot from Photos is offered again. Picked photos stay in Photos either way.
    nonisolated static func cleanup(after state: Job.State, of source: Job.Source) -> Cleanup {
        if case .failed = state { return .keep }
        return switch source {
        case .inbox(let url): .removeSharedFile(url)
        case .asset(let id): .markScanned("asset:\(id)")
        case .picker: .keep
        }
    }

    /// Sends a bookmark's stored screenshot to the AI again with the current instructions and
    /// replaces its details with what's found, for imports that were read wrong. Takes the
    /// item of the same category if the screenshot shows several.
    func reread(_ bookmark: Bookmark, context: ModelContext) async throws {
        guard let screenshot = bookmark.screenshot,
              let jpeg = await Task.detached(priority: .userInitiated, operation: { PreparedImage(screenshot)?.upload }).value else {
            throw AIError.badResponse("this bookmark has no screenshot")
        }
        let items = try await AppSettings.client.extract(jpeg: jpeg)
        guard let item = ImportMerge.rereadItem(for: bookmark, from: items) else {
            throw AIError.badResponse("nothing recognisable was found on the screenshot")
        }
        uiLog.info("Re-read “\(bookmark.title, privacy: .private(mask: .hash))” as “\(item.title, privacy: .private(mask: .hash))”")
        ImportMerge.applyReread(item, to: bookmark)
        try context.save()
        await covers.find(context: context)
    }

    private func markScanned(_ key: String, context: ModelContext) {
        context.insert(ScannedImage(key: key))
        try? context.save()
    }

    private func loadData(_ job: Job) async throws -> Data? {
        if let data = job.imageData { return data }
        return switch job.source {
        case .picker(let item): try await item.loadTransferable(type: Data.self)
        case .inbox(let url): try Data(contentsOf: url)
        case .asset(let id): try await ScreenshotLibrary.imageData(for: id)
        }
    }

    /// Changes the job with this ID, if it's still in the list.
    private func updateJob(_ id: Job.ID, _ change: (inout Job) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
    }

    /// `job` is a copy taken before the work starts; changes go back through `updateJob`.
    private func process(_ job: Job, context: ModelContext) async -> Job.State {
        do {
            importLog.debug("Loading image")
            guard let data = try await loadData(job),
                  let prepared = await Task.detached(priority: .userInitiated, operation: { PreparedImage(data) }).value else {
                return .failed("Couldn't load the image")
            }
            let preview = prepared.preview
            updateJob(job.id) {
                $0.thumbnail = prepared.thumbnail
                $0.previewData = preview
            }

            let hash = prepared.hash
            let isAutomatic = if case .asset = job.source { true } else { false }
            if ImportMerge.canSkip(hash: hash, isAutomatic: isAutomatic, forceRead: job.forceRead, context: context) {
                return .skipped
            }

            guard let upload = prepared.upload else { return .failed("Couldn't encode the image") }
            importLog.info("Sending \(upload.count / 1024) KB to \(AppSettings.provider.rawValue, privacy: .public)")
            let started = Date.now
            let items = try await AppSettings.client.extract(jpeg: upload)
            importLog.info("Got \(items.count) items in \(Int(Date.now.timeIntervalSince(started)))s")

            let result = try ImportMerge.merge(items, hash: hash, screenshot: preview, assetID: job.assetID,
                                               context: context)
            context.insert(ScannedImage(key: "hash:\(hash)"))
            try context.save()
            if result.added == 0 && result.notes.isEmpty {
                importLog.info("Nothing found (the AI returned \(items.count) item(s))")
                updateJob(job.id) { $0.imageData = data }
                return .nothingFound
            }
            return .done(added: result.added, notes: result.notes)
        } catch {
            importLog.error("Import failed: \(error, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}

/// Everything an import needs from a screenshot, made away from the main thread. ImageIO
/// decodes only the sizes needed, never the full image.
struct PreparedImage: @unchecked Sendable {
    /// SHA-256 of the original file, used to skip screenshots read before.
    let hash: String
    let thumbnail: UIImage?
    /// Medium-size JPEG for the preview in Imports, and what bookmarks keep.
    let preview: Data?
    /// What's sent to the AI. Vision models downscale anything larger anyway.
    let upload: Data?

    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        func scaled(_ maxSide: Int) -> UIImage? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }
        guard let upload = scaled(1568) else { return nil }
        hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.upload = upload.jpegData(compressionQuality: 0.8)
        preview = scaled(1200)?.jpegData(compressionQuality: 0.7)
        thumbnail = scaled(200)
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
