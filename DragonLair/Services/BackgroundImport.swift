import BackgroundTasks
import os
import UIKit

/// Keeps an import running while the user is in other apps. On iOS 26+ each run is a
/// continued processing task, which iOS shows with a progress indicator and lets run
/// until it's done. Older versions only get the short regular background time.
@MainActor
final class BackgroundImport {
    static let identifierPrefix = "\(AppID.base).import"

    /// Set when iOS (or the user, from the progress indicator) stops the task.
    private(set) var isCancelled = false
    private var task: BGTask?
    private var isRunning = false
    private var fallback = UIBackgroundTaskIdentifier.invalid
    private var done = 0
    private var total = 0
    private let title: String
    /// What's being counted in the progress line ("3 of 10 screenshots").
    private let noun: String

    init(title: String = "Reading screenshots", noun: String = "screenshots") {
        self.title = title
        self.noun = noun
    }

    func begin(total: Int) {
        isCancelled = false
        isRunning = true
        done = 0
        self.total = total
        if #available(iOS 26.0, *), submitContinuedTask() { return }
        fallback = UIApplication.shared.beginBackgroundTask(withName: "Import") { [weak self] in
            MainActor.assumeIsolated { self?.endFallback() }
        }
    }

    /// Call when a screenshot finishes; `remaining` includes ones queued during the run.
    func progress(remaining: Int) {
        done += 1
        total = done + remaining
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(total)
        task.progress.completedUnitCount = Int64(done)
        task.updateTitle(title, subtitle: "\(done) of \(total) \(noun)")
    }

    func end() {
        isRunning = false
        task?.setTaskCompleted(success: !isCancelled)
        task = nil
        endFallback()
    }

    @available(iOS 26.0, *)
    private func submitContinuedTask() -> Bool {
        // Each run needs its own identifier: a handler can only be registered once per identifier.
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { self.started(task) }
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: title, subtitle: "\(total) \(noun)")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            importLog.info("Continued task submitted")
            return true
        } catch {
            importLog.notice("Continued import task not available: \(error, privacy: .public)")
            return false
        }
    }

    @available(iOS 26.0, *)
    private func started(_ task: BGTask) {
        // The run can finish before iOS gets round to starting the task.
        guard isRunning else { return task.setTaskCompleted(success: true) }
        self.task = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.isCancelled = true }
        }
        if let task = task as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(total)
            task.progress.completedUnitCount = Int64(done)
        }
    }

    private func endFallback() {
        guard fallback != .invalid else { return }
        UIApplication.shared.endBackgroundTask(fallback)
        fallback = .invalid
    }
}
