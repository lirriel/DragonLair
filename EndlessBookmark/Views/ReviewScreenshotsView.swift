import SwiftData
import SwiftUI

/// New screenshots found by watching: the user picks which are worth importing. Picked ones
/// are read by the AI; skipped ones are never offered again.
struct ReviewScreenshotsView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var previewing: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                Text("Tap the screenshots worth saving. Only those are sent to your AI provider; the rest are skipped and won't be offered again.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(importQueue.pendingReview, id: \.self) { id in
                        ReviewTile(id: id, isSelected: selected.contains(id))
                            .onTapGesture {
                                if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                            }
                            .onLongPressGesture { previewing = id }
                    }
                }
                .padding()
            }
            .overlay {
                if importQueue.pendingReview.isEmpty {
                    ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                                           description: Text("New screenshots show up here while watching is on."))
                }
            }
            .navigationTitle("New screenshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(selected.count == importQueue.pendingReview.count ? "Select none" : "Select all") {
                        selected = selected.count == importQueue.pendingReview.count ? [] : Set(importQueue.pendingReview)
                    }
                    .disabled(importQueue.pendingReview.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Skip \(selected.isEmpty ? "all" : "others")", role: .destructive) {
                        importQueue.skip(importQueue.pendingReview.filter { !selected.contains($0) }, context: context)
                        if selected.isEmpty { dismiss() }
                    }
                    .disabled(importQueue.pendingReview.isEmpty || selected.count == importQueue.pendingReview.count)
                    Spacer()
                    Button("Import \(selected.count)") {
                        let picked = importQueue.pendingReview.filter { selected.contains($0) }
                        // Importing what's picked settles the review; the rest is skipped.
                        importQueue.skip(importQueue.pendingReview.filter { !selected.contains($0) }, context: context)
                        importQueue.approve(picked, context: context)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
                }
            }
            .fullScreenCover(item: Binding(get: { previewing.map(PreviewID.init) }, set: { previewing = $0?.id })) { item in
                ReviewPreview(id: item.id)
            }
        }
    }
}

private struct PreviewID: Identifiable { let id: String }

private struct ReviewTile: View {
    let id: String
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(9 / 19.5, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary).overlay(ProgressView()) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white))
                    .background(Circle().fill(isSelected ? .white : .black.opacity(0.3)))
                    .padding(6)
            }
            .opacity(isSelected ? 1 : 0.85)
            .contentShape(Rectangle())
            .task { image = await ScreenshotLibrary.thumbnail(for: id) }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Long-press a tile to see the screenshot full size.
private struct ReviewPreview: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView().padding(.top, 80) }
            }
            .background(.black)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { image = await ScreenshotLibrary.thumbnail(for: id, side: 1200) }
    }
}
