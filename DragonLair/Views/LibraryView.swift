import PhotosUI
import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]

    @State private var category: BookmarkCategory?
    @State private var search = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var showSettings = false
    @State private var showImports = false
    @State private var showPicker = false
    @State private var showFolder = false
    @State private var showBackup = false
    @State private var showReview = false
    @State private var path = NavigationPath()
    @State private var quickActions = QuickActions()

    private enum Route: Hashable { case archive, originals }
    /// Saved screenshots still in Photos; offered for clean-up when there are any.
    @State private var originalsLeft = 0

    /// Archived bookmarks live in the Archive screen, not the main list.
    private var active: [Bookmark] { bookmarks.filter { !$0.status.isArchived } }

    private var filtered: [Bookmark] {
        active.filter { b in
            (category == nil || b.category == category) && (search.isEmpty || b.matches(search))
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    CategoryChips(selection: $category, counts: counts)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if !importQueue.pendingReview.isEmpty {
                    Section {
                        Button { showReview = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "photo.badge.plus").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    let count = importQueue.pendingReview.count
                                    Text("\(count) new screenshot\(count == 1 ? "" : "s") to review")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Choose which to save").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !importQueue.jobs.isEmpty {
                    Section { ImportBanner { showImports = true } }
                }
                if let progress = importQueue.covers.progress, progress.total > 3 {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Finding covers… \(progress.done) of \(progress.total)")
                                    .font(.subheadline.weight(.semibold))
                                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            }
                        }
                    }
                }
                if originalsLeft > 0 && !importQueue.isBusy {
                    Section {
                        Button { path.append(Route.originals) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "photo.stack").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(originalsLeft) saved screenshot\(originalsLeft == 1 ? " is" : "s are") still in Photos")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Tap to review and delete them").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(filtered) { bookmark in
                    NavigationLink(value: bookmark) { BookmarkRow(bookmark: bookmark) }
                        .trackerSwipeActions(bookmark)
                        .quickActions(bookmark)
                }
            }
            .scrollDisabled(quickActions.isActive)
            .overlay {
                if bookmarks.isEmpty { emptyState }
                else if filtered.isEmpty && !search.isEmpty { ContentUnavailableView.search(text: search) }
                else if filtered.isEmpty {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.seal",
                                           description: Text("Things you've started or changed your mind about are in the Archive."))
                }
            }
            .navigationTitle(category?.title ?? "Dragon Lair")
            .navigationDestination(for: Bookmark.self) { BookmarkDetailView(bookmark: $0) }
            .searchable(text: $search, prompt: "Titles, authors, tags…")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path.append(Route.archive) } label: { Image(systemName: "archivebox") }
                }
                ToolbarItem(placement: .topBarTrailing) { addButton }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .archive: ArchiveView()
                case .originals: OriginalsView()
                }
            }
            // Recounted whenever the list or an import changes, and when coming back to it.
            .task(id: "\(bookmarks.count)-\(importQueue.isBusy)-\(path.count)-\(scenePhase == .active)") {
                originalsLeft = ScreenshotLibrary.existing(Array(Set(bookmarks.map(\.sourceAssetID).filter { !$0.isEmpty }))).count
            }
            .onChange(of: path.count) { old, new in
                lastNavigationRequest = .now
                uiLog.info("Navigation \(old > new ? "back" : "push", privacy: .public): depth \(old) → \(new)")
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                importQueue.enqueue(items, context: context)
                picked = []
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    importQueue.importInbox(context: context)
                    importQueue.refreshWatching(context: context)
                    importQueue.resume(context: context)
                    Task { await importQueue.deleteOriginalsIfPending() }
                    Task { await importQueue.covers.find(context: context) }
                case .background:
                    // Catches edits and tracker changes made since the last import.
                    Backup.autoBackup(context: context)
                default: break
                }
            }
            // Using the shared library gives picked items their Photos identifiers,
            // which "delete originals" needs.
            .photosPicker(isPresented: $showPicker, selection: $picked, maxSelectionCount: 50,
                          matching: .screenshots, photoLibrary: .shared())
            .sheet(isPresented: $showSettings, onDismiss: {
                Task { await importQueue.covers.find(context: context) }
            }) { SettingsView() }
            .sheet(isPresented: $showImports) { ImportListView() }
            .sheet(isPresented: $showReview) { ReviewScreenshotsView() }
            .sheet(isPresented: $showFolder) { ScreenshotFolderView() }
            .sheet(isPresented: $showBackup) { NavigationStack { BackupView() } }
        }
        .overlay { QuickActionsOverlay().ignoresSafeArea() }
        .environment(quickActions)
    }

    private var addButton: some View {
        Menu {
            Button { showPicker = true } label: { Label("Choose screenshots…", systemImage: "photo.badge.plus") }
            Button { showFolder = true } label: {
                Label("Screenshots folder…", systemImage: "photo.on.rectangle.angled")
            }
        } label: {
            Image(systemName: "plus.viewfinder")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No bookmarks yet", systemImage: "photo.stack")
        } description: {
            Text("Pick screenshots of books, manhwa, movies, sites or places. AI sorts them into your collection.")
        } actions: {
            Button("Connect Screenshots folder") { showFolder = true }
                .buttonStyle(.borderedProminent)
            Button("Choose screenshots") { showPicker = true }
            Button("Restore from backup") { showBackup = true }
        }
    }

    private var counts: [BookmarkCategory?: Int] {
        var result: [BookmarkCategory?: Int] = [nil: active.count]
        for b in active { result[b.category, default: 0] += 1 }
        return result
    }
}

extension Bookmark {
    /// Search: ignores case, accents and full-width letters, so "cafe" finds "Café".
    func matches(_ q: String) -> Bool {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, creator, englishTitle, englishCreator, originalTitle, originalCreator,
                summary, location, notes, tags.joined(separator: " ")]
            .contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
    }
}

extension View {
    /// Swipe right: started it. Swipe left: changed my mind. On archived rows: bring back.
    func trackerSwipeActions(_ bookmark: Bookmark) -> some View {
        self
            // Reveal only, tap to apply: a full swipe archived things by accident while scrolling.
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if bookmark.status.isArchived {
                    Button { withAnimation { bookmark.status = .saved } } label: {
                        Label("Bring back", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                } else {
                    Button { withAnimation { bookmark.status = .started } } label: {
                        Label(bookmark.category.startedLabel, systemImage: BookmarkStatus.started.symbol)
                    }
                    .tint(.green)
                }
            }
            // No full swipe, so a long swipe can't delete by accident.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    withAnimation { bookmark.delete() }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                if !bookmark.status.isArchived {
                    Button { withAnimation { bookmark.status = .dropped } } label: {
                        Label("Changed my mind", systemImage: BookmarkStatus.dropped.symbol)
                    }
                    .tint(.orange)
                }
            }
    }
}

private struct CategoryChips: View {
    @Binding var selection: BookmarkCategory?
    let counts: [BookmarkCategory?: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, title: "All", symbol: "square.stack")
                ForEach(BookmarkCategory.allCases) { c in
                    if (counts[c] ?? 0) > 0 || c != .other { chip(c, title: c.title, symbol: c.symbol) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func chip(_ c: BookmarkCategory?, title: String, symbol: String) -> some View {
        let selected = selection == c
        return Button {
            withAnimation(.snappy) { selection = c }
        } label: {
            Label("\(title) \(counts[c] ?? 0)", systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct ImportBanner: View {
    @Environment(ImportQueue.self) private var importQueue
    let onTap: () -> Void

    private var title: String {
        if importQueue.isBusy { return "Reading screenshots…" }
        if importQueue.failedCount > 0 { return "\(importQueue.failedCount) screenshot\(importQueue.failedCount == 1 ? "" : "s") couldn't be read" }
        if importQueue.nothingFoundCount > 0 {
            return "Nothing found on \(importQueue.nothingFoundCount) screenshot\(importQueue.nothingFoundCount == 1 ? "" : "s")"
        }
        return "Import finished"
    }

    private var detail: String {
        var parts = ["\(importQueue.finishedCount) of \(importQueue.jobs.count) processed"]
        if !importQueue.isBusy && (importQueue.failedCount > 0 || importQueue.nothingFoundCount > 0) {
            parts.append("tap to retry")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if importQueue.isBusy { ProgressView() }
                else if importQueue.failedCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else if importQueue.nothingFoundCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    // Spell out what went wrong, so a failure isn't just a number.
                    if let error = importQueue.lastError ?? importQueue.deleteError {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct BookmarkRow: View {
    let bookmark: Bookmark
    var showsStatus = true

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(data: bookmark.image)
                .frame(width: 52, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(bookmark.title).font(.headline).lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Label(bookmark.category.title, systemImage: bookmark.category.symbol)
                    if showsStatus && bookmark.status != .saved {
                        Text("· \(bookmark.status.label(for: bookmark.category))")
                    }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        [bookmark.creator, bookmark.year, bookmark.category == .place ? bookmark.location : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct Thumbnail: View {
    let data: Data?

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}
