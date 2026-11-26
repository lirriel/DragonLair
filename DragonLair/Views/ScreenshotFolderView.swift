import Photos
import SwiftData
import SwiftUI

struct ScreenshotFolderView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var status = ScreenshotLibrary.status
    @State private var watching = AppSettings.watchScreenshots
    @State private var askFirst = AppSettings.askBeforeImportingWatched
    @State private var deleteOriginals = AppSettings.deleteOriginalsAfterImport
    @State private var period: Period = .week
    @State private var customFrom = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customTo = Date.now
    @State private var total = 0
    @State private var newIDs: [String] = []
    @State private var confirmLargeImport = false
    @Query private var bookmarks: [Bookmark]
    @State private var importedInPhotos: [String] = []
    @State private var cleanupError: String?

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today", week = "Last 7 days", month = "Last 30 days",
             threeMonths = "Last 3 months", year = "Last year", custom = "Custom dates"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                if status == .authorized || status == .limited {
                    watchSection
                    periodSection
                    Section {
                        Toggle("Delete originals after import", isOn: $deleteOriginals)
                            .onChange(of: deleteOriginals) { _, on in
                                AppSettings.deleteOriginalsAfterImport = on
                                // Imports that finish in the background ask with a notification.
                                if on { Task { await ImportNotifier.requestAuthorization() } }
                            }
                    } footer: {
                        Text("After each import, screenshots that added a bookmark (or matched one you already have) are moved to Recently Deleted in Photos, where they stay for 30 days. iOS asks you to confirm each time; if the import finishes while you're in another app, a notification asks first. Each bookmark keeps its own copy of the screenshot. Screenshots where nothing was found are kept.")
                    }
                    cleanupSection
                    if status == .limited {
                        Section {
                            Button("Allow access to all photos") { openSettings() }
                        } footer: {
                            Text("You've shared only some photos with the app, so it can't see every screenshot.")
                        }
                    }
                } else {
                    accessSection
                }
            }
            .navigationTitle("Screenshots folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: rangeKey) { recount() }
            .confirmationDialog("Import \(newIDs.count) screenshots?", isPresented: $confirmLargeImport,
                                titleVisibility: .visible) {
                Button("Import \(newIDs.count)") { startImport() }
            } message: {
                Text("Each screenshot is sent to \(AppSettings.provider.title), which charges per image.")
            }
        }
    }

    /// Screenshots already turned into bookmarks that are still sitting in Photos.
    private var cleanupSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await cleanUp() }
            } label: {
                Text(importedInPhotos.isEmpty ? "No imported screenshots left in Photos"
                     : "Delete \(importedInPhotos.count) imported screenshot\(importedInPhotos.count == 1 ? "" : "s")")
            }
            .disabled(importedInPhotos.isEmpty)
            if let cleanupError {
                Label(cleanupError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
        } footer: {
            Text("Moves screenshots you've already saved as bookmarks to Recently Deleted in Photos. Each bookmark keeps its own copy. Screenshots shared from other apps aren't tracked, so they aren't included.")
        }
        .task(id: bookmarks.count) { recountImported() }
    }

    private func recountImported() {
        importedInPhotos = ScreenshotLibrary.existing(Array(Set(bookmarks.map(\.sourceAssetID).filter { !$0.isEmpty })))
    }

    private func cleanUp() async {
        do {
            cleanupError = try await ScreenshotLibrary.delete(importedInPhotos).problem
        } catch {
            cleanupError = error.localizedDescription
        }
        recountImported()
        recount()
    }

    private var accessSection: some View {
        Section {
            Label("Connect your Screenshots album", systemImage: "photo.on.rectangle.angled")
                .font(.headline)
            Text("Let Dragon Lair read your screenshots to import them by date, or pick up new ones automatically.")
                .foregroundStyle(.secondary)
            if status == .notDetermined {
                Button("Allow access") {
                    Task {
                        status = await ScreenshotLibrary.requestAccess()
                        recount()
                    }
                }
            } else {
                Button("Open Settings to allow access") { openSettings() }
            }
        }
    }

    private var watchSection: some View {
        Section {
            Toggle("Watch for new screenshots", isOn: $watching)
                .onChange(of: watching) { _, on in
                    if on { AppSettings.watchSince = .now }
                    AppSettings.watchScreenshots = on
                    importQueue.refreshWatching(context: context)
                }
            if watching {
                Toggle("Ask before importing", isOn: $askFirst)
                    .onChange(of: askFirst) { _, on in AppSettings.askBeforeImportingWatched = on }
                LabeledContent("Watching since",
                               value: AppSettings.watchSince.formatted(date: .abbreviated, time: .shortened))
            }
        } footer: {
            Text(askFirst
                 ? "New screenshots are collected whenever you open the app, and you choose which to save; only those are sent to your AI provider. iOS doesn't let apps run when a screenshot is taken, so nothing is collected while the app is closed."
                 : "New screenshots are read whenever you open the app. iOS doesn't let apps run when a screenshot is taken, so nothing is read while the app is closed. Every screenshot is sent to your AI provider, so turn this on only if most of your screenshots are worth keeping.")
        }
    }

    private var periodSection: some View {
        Section {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            if period == .custom {
                DatePicker("From", selection: $customFrom, in: ...customTo, displayedComponents: .date)
                DatePicker("To", selection: $customTo, in: customFrom..., displayedComponents: .date)
            }
            LabeledContent("Screenshots in period", value: "\(total)")
            LabeledContent("Not imported yet", value: "\(newIDs.count)")
            Button {
                if newIDs.count > 25 { confirmLargeImport = true } else { startImport() }
            } label: {
                Text(newIDs.isEmpty ? "Nothing new to import" : "Import \(newIDs.count) screenshot\(newIDs.count == 1 ? "" : "s")")
            }
            .disabled(newIDs.isEmpty)
        } header: {
            Text("Import by period")
        } footer: {
            Text("Screenshots already read are skipped, even if nothing worth saving was found on them.")
        }
    }

    private var range: (Date, Date) {
        let cal = Calendar.current
        let now = Date.now
        func ago(_ c: Calendar.Component, _ n: Int) -> Date { cal.date(byAdding: c, value: -n, to: now) ?? now }
        return switch period {
        case .today: (cal.startOfDay(for: now), now)
        case .week: (ago(.day, 7), now)
        case .month: (ago(.day, 30), now)
        case .threeMonths: (ago(.month, 3), now)
        case .year: (ago(.year, 1), now)
        case .custom: (cal.startOfDay(for: customFrom),
                       cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customTo)) ?? customTo)
        }
    }

    private var rangeKey: String {
        "\(status.rawValue)-\(period.rawValue)-\(customFrom.timeIntervalSince1970)-\(customTo.timeIntervalSince1970)"
    }

    private func recount() {
        let (start, end) = range
        total = ScreenshotLibrary.assetIDs(from: start, to: end).count
        newIDs = importQueue.newScreenshotIDs(from: start, to: end, context: context)
    }

    private func startImport() {
        importQueue.importScreenshots(ids: newIDs, context: context)
        dismiss()
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
