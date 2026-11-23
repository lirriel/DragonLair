import Photos
import SwiftData
import SwiftUI

/// Screenshots that are already saved as bookmarks but still sit in Photos, to clear out in
/// one go or a few at a time. Each bookmark keeps its own copy, so nothing is lost.
struct OriginalsView: View {
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]
    @State private var inPhotos: Set<String> = []
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var message: String?
    @State private var deleting = false

    /// One row per screenshot; a screenshot that gave several bookmarks lists all their titles.
    private var rows: [(id: String, titles: [String], image: Data?)] {
        var seen: [String: Int] = [:]
        var result: [(id: String, titles: [String], image: Data?)] = []
        for bookmark in bookmarks where inPhotos.contains(bookmark.sourceAssetID) {
            if let index = seen[bookmark.sourceAssetID] {
                result[index].titles.append(bookmark.title)
            } else {
                seen[bookmark.sourceAssetID] = result.count
                result.append((bookmark.sourceAssetID, [bookmark.title], bookmark.screenshot))
            }
        }
        return result
    }

    var body: some View {
        List(selection: $selection) {
            if let message {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            Section {
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: 12) {
                        Thumbnail(data: row.image)
                            .frame(width: 44, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.titles.first ?? "").font(.subheadline.weight(.semibold)).lineLimit(2)
                            if row.titles.count > 1 {
                                Text("and \(row.titles.count - 1) more").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await delete([row.id]) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text(ScreenshotLibrary.status == .limited
                     ? "Only screenshots Dragon Lair can see are listed. For all of them, allow Full Access in Settings → Dragon Lair → Photos."
                     : "Deleting moves them to Recently Deleted in Photos for 30 days. Each bookmark keeps its own copy.")
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("All cleaned up", systemImage: "checkmark.circle",
                                       description: Text("No saved screenshots are left in Photos."))
            }
        }
        .navigationTitle("Screenshots in Photos")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !rows.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Select") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        selection = []
                    }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if !rows.isEmpty {
                    let ids = editMode.isEditing ? Array(selection) : rows.map(\.id)
                    Button(role: .destructive) { Task { await delete(ids) } } label: {
                        if deleting { ProgressView() }
                        else {
                            Text(editMode.isEditing ? "Delete \(ids.count) selected" : "Delete all \(ids.count)")
                        }
                    }
                    .disabled(ids.isEmpty || deleting)
                }
            }
        }
        .task(id: bookmarks.count) { refresh() }
    }

    private func refresh() {
        inPhotos = Set(ScreenshotLibrary.existing(Array(Set(bookmarks.map(\.sourceAssetID).filter { !$0.isEmpty }))))
        selection.formIntersection(inPhotos)
    }

    private func delete(_ ids: [String]) async {
        deleting = true
        do {
            message = try await ScreenshotLibrary.delete(ids).problem
        } catch {
            message = "Couldn't delete: \(error.localizedDescription)"
        }
        deleting = false
        refresh()
        if rows.isEmpty { editMode = .inactive }
    }
}
