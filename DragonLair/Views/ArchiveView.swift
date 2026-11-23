import SwiftData
import SwiftUI

/// Everything marked as started or "changed my mind". Nothing here is deleted,
/// so later screenshots of the same thing are recognised.
struct ArchiveView: View {
    @Query(sort: \Bookmark.archivedAt, order: .reverse) private var bookmarks: [Bookmark]
    @State private var filter: BookmarkStatus?
    @State private var search = ""
    @Environment(QuickActions.self) private var quickActions

    private var archived: [Bookmark] {
        bookmarks.filter { b in
            b.status.isArchived && (filter == nil || b.status == filter) && (search.isEmpty || b.matches(search))
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    Text("All").tag(BookmarkStatus?.none)
                    Text("Started").tag(BookmarkStatus?.some(.started))
                    Text("Dropped").tag(BookmarkStatus?.some(.dropped))
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            ForEach(archived) { bookmark in
                NavigationLink(value: bookmark) {
                    VStack(alignment: .leading, spacing: 4) {
                        BookmarkRow(bookmark: bookmark, showsStatus: false)
                        if let date = bookmark.archivedAt {
                            Label("\(bookmark.status.label(for: bookmark.category)) · \(date.formatted(date: .abbreviated, time: .omitted))",
                                  systemImage: bookmark.status.symbol)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .trackerSwipeActions(bookmark)
                .quickActions(bookmark)
            }
        }
        .scrollDisabled(quickActions.isActive)
        .overlay {
            if archived.isEmpty {
                ContentUnavailableView("Archive is empty", systemImage: "archivebox",
                                       description: Text("Swipe right on a bookmark when you start it, or left when you change your mind."))
            }
        }
        .searchable(text: $search, prompt: "Search archive")
        .navigationTitle("Archive")
    }
}
