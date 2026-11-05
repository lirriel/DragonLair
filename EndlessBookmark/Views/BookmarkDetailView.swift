import SwiftData
import SwiftUI

struct BookmarkDetailView: View {
    @Bindable var bookmark: Bookmark
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var originalInPhotos = false
    @State private var showScreenshot = false
    @State private var newTag = ""
    @State private var findingCover = false
    @State private var rereading = false
    @State private var rereadError: String?
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.modelContext) private var context
    @FocusState private var focus: Field?
    /// Title and author when editing started, to tell whether the cover should be looked up again.
    @State private var namesAtFocus = ""
    @State private var showSaved = false

    private enum Field: Hashable {
        case title, creator, originalTitle, originalCreator, englishTitle, englishCreator
        case year, url, location, summary, tag, notes
    }

    var body: some View {
        Form {
            Section {
                coverHeader
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            Section {
                TextField("Title", text: $bookmark.title, axis: .vertical).font(.title3.weight(.semibold)).focused($focus, equals: .title)
                Picker("Category", selection: $bookmark.categoryRaw) {
                    ForEach(BookmarkCategory.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
            }

            Section {
                ForEach(BookmarkStatus.allCases) { status in
                    Button { withAnimation { bookmark.status = status } } label: {
                        HStack {
                            Label(status == .saved && bookmark.status.isArchived ? "Bring back to my list"
                                    : status.label(for: bookmark.category),
                                  systemImage: status.symbol)
                            Spacer()
                            if bookmark.status == status { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Tracker")
            } footer: {
                Text(history)
            }

            if bookmark.link != nil || bookmark.category == .place || !bookmark.location.isEmpty {
                Section {
                    if let link = bookmark.link {
                        Button { openURL(link) } label: { Label("Open website", systemImage: "safari") }
                    }
                    if bookmark.category == .place || !bookmark.location.isEmpty, let maps = bookmark.mapsLink {
                        Button { openURL(maps) } label: { Label("Open in Maps", systemImage: "map") }
                    }
                }
            }

            Section("Details") {
                LabeledContent(creatorLabel) { TextField("", text: $bookmark.creator).multilineTextAlignment(.trailing).focused($focus, equals: .creator) }
                if !bookmark.originalTitle.isEmpty {
                    LabeledContent("Original title") {
                        TextField("", text: $bookmark.originalTitle).multilineTextAlignment(.trailing).focused($focus, equals: .originalTitle)
                    }
                    LabeledContent("Original \(creatorLabel.lowercased())") {
                        TextField("", text: $bookmark.originalCreator).multilineTextAlignment(.trailing).focused($focus, equals: .originalCreator)
                    }
                } else if bookmark.needsEnglishNames || !bookmark.englishTitle.isEmpty {
                    LabeledContent("English title") {
                        TextField("", text: $bookmark.englishTitle).multilineTextAlignment(.trailing).focused($focus, equals: .englishTitle)
                    }
                    LabeledContent("English \(creatorLabel.lowercased())") {
                        TextField("", text: $bookmark.englishCreator).multilineTextAlignment(.trailing).focused($focus, equals: .englishCreator)
                    }
                }
                LabeledContent("Year") { TextField("", text: $bookmark.year).multilineTextAlignment(.trailing).focused($focus, equals: .year) }
                LabeledContent("Link") {
                    TextField("", text: $bookmark.url)
                        .focused($focus, equals: .url)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                }
                LabeledContent("Location") { TextField("", text: $bookmark.location).multilineTextAlignment(.trailing).focused($focus, equals: .location) }
            }

            Section("Summary") {
                TextField("What is it?", text: $bookmark.summary, axis: .vertical).focused($focus, equals: .summary)
            }

            Section("Tags") {
                if !bookmark.tags.isEmpty {
                    ForEach(bookmark.tags, id: \.self) { Text("#\($0)") }
                        .onDelete { bookmark.tags.remove(atOffsets: $0) }
                }
                TextField("Add tag", text: $newTag).focused($focus, equals: .tag)
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        let tag = newTag.trimmingCharacters(in: .whitespaces).lowercased()
                        if !tag.isEmpty && !bookmark.tags.contains(tag) { bookmark.tags.append(tag) }
                        newTag = ""
                    }
            }

            Section("My notes") {
                TextField("Why did I save this?", text: $bookmark.notes, axis: .vertical).focused($focus, equals: .notes)
            }

            Section {
                Button("Delete bookmark", role: .destructive) { confirmDelete = true }
                    .confirmationDialog("Delete “\(bookmark.title)”?", isPresented: $confirmDelete,
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            dismiss()
                            bookmark.delete()
                        }
                    } message: {
                        Text("It's removed for good. The screenshot it came from won't be imported again.")
                    }
            } footer: {
                Text("For wrong imports. To keep it out of your list but still recognise it later, use the tracker above instead.")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if focus != nil {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { focus = nil } }
            }
        }
        .onChange(of: focus) { old, new in
            if old != nil { finishEditing() }
            // Snapshot only when editing starts, so title → author still counts as a change.
            if old == nil, new != nil { namesAtFocus = bookmark.title + "|" + bookmark.creator }
        }
        // Leaving the page while typing still saves.
        .onDisappear { if focus != nil { try? context.save() } }
        .overlay(alignment: .bottom) {
            if showSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4, y: 2)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            let ms = Int(Date.now.timeIntervalSince(lastNavigationRequest) * 1000)
            uiLog.info("Opened “\(bookmark.title, privacy: .public)” \(ms) ms after navigation was requested")
        }
        .task { originalInPhotos = !ScreenshotLibrary.existing([bookmark.sourceAssetID].filter { !$0.isEmpty }).isEmpty }
        .fullScreenCover(isPresented: $showScreenshot) { ScreenshotViewer(data: bookmark.screenshot) }
    }

    /// The cover (or screenshot) with everything about it in a menu on its corner, so nothing
    /// cover-related is buried further down the page.
    private var coverHeader: some View {
        VStack(spacing: 8) {
            Group {
                if let cover = bookmark.cover, let image = UIImage(data: cover) {
                    // Full width, keeping the cover's shape; the cap only stops an unusually
                    // tall image from taking over the page.
                    Image(uiImage: image).resizable()
                        .aspectRatio(image.size, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 620)
                } else if let shot = bookmark.screenshot, let image = UIImage(data: shot) {
                    // A phone screenshot at full width would be taller than the screen: show its
                    // top, where the title usually is. Tapping opens the whole thing.
                    Color.clear
                        .frame(maxWidth: .infinity).frame(height: 360)
                        .overlay(alignment: .top) { Image(uiImage: image).resizable().scaledToFill() }
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        .frame(height: 180)
                        .overlay(Image(systemName: bookmark.category.symbol).font(.largeTitle).foregroundStyle(.secondary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if findingCover || rereading {
                    RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.35))
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text(rereading ? "Reading screenshot…" : "Finding cover…")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    }
                }
            }
            // On the image itself, so the button sits on the cover's corner.
            .overlay(alignment: .bottomTrailing) { coverMenu.padding(10) }
            .onTapGesture { if bookmark.screenshot != nil { showScreenshot = true } }

            if let status = coverStatus {
                Text(status.text)
                    .font(.footnote)
                    .foregroundStyle(status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var coverMenu: some View {
        Menu {
            Button { Task { await findCover() } } label: { Label("Find cover again", systemImage: "arrow.clockwise") }
            if bookmark.screenshot != nil {
                Button { Task { await reread() } } label: { Label("Read screenshot again", systemImage: "text.viewfinder") }
                Button { showScreenshot = true } label: { Label("View screenshot", systemImage: "photo") }
            }
            if bookmark.cover != nil {
                Button { bookmark.cover = nil } label: { Label("Use screenshot instead", systemImage: "photo.badge.checkmark") }
            }
            if originalInPhotos {
                Divider()
                Button(role: .destructive) { Task { await deleteOriginal() } } label: {
                    Label("Delete original from Photos", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .shadow(radius: 3, y: 1)
        }
        .disabled(findingCover || rereading)
        .accessibilityLabel("Cover options")
    }

    private var coverStatus: (text: String, isError: Bool)? {
        if let rereadError { return (rereadError, true) }
        if findingCover || rereading { return nil }
        if bookmark.cover == nil && bookmark.coverLookedUp {
            return ("No cover found online, so the screenshot is shown. Fix the title and tap ⋯ → Find cover again.", false)
        }
        if originalInPhotos { return ("The original screenshot is still in Photos.", false) }
        return nil
    }

    /// Saves as soon as a field is left (or Done is tapped) and says so. A changed title or
    /// author also looks the cover up again under the corrected name.
    private func finishEditing() {
        bookmark.title = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try context.save()
            uiLog.info("Saved edits to “\(bookmark.title, privacy: .public)”")
        } catch {
            uiLog.error("Saving edits failed: \(String(describing: error), privacy: .public)")
            rereadError = "Couldn't save: \(error.localizedDescription)"
            return
        }
        withAnimation(.spring(duration: 0.3)) { showSaved = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { showSaved = false }
        }
        // Once editing ends: wait while the user is still on the title or author.
        let names = bookmark.title + "|" + bookmark.creator
        if names != namesAtFocus, !bookmark.title.isEmpty, focus == nil || ![.title, .creator].contains(focus) {
            namesAtFocus = names
            Task { await findCover() }
        }
    }

    private func findCover() async {
        findingCover = true
        rereadError = nil
        bookmark.apply(await CoverArt.find(bookmark.coverQuery))
        findingCover = false
    }

    private func reread() async {
        rereading = true
        do {
            try await importQueue.reread(bookmark, context: context)
            rereadError = nil
        } catch {
            uiLog.error("Re-read of “\(bookmark.title, privacy: .public)” failed: \(String(describing: error), privacy: .public)")
            print("Re-read failed: \(error)")
            rereadError = error.localizedDescription
        }
        rereading = false
    }

    private func deleteOriginal() async {
        do {
            rereadError = try await ScreenshotLibrary.delete([bookmark.sourceAssetID]).problem
        } catch {
            rereadError = "Couldn't delete the original: \(error.localizedDescription)"
        }
        originalInPhotos = !ScreenshotLibrary.existing([bookmark.sourceAssetID]).isEmpty
    }

    private var history: String {
        var lines = ["Saved \(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))."]
        if bookmark.status.isArchived, let date = bookmark.archivedAt {
            lines.append("Archived \(date.formatted(date: .abbreviated, time: .omitted)) because \(bookmark.status.reason(for: bookmark.category)).")
        }
        lines.append("Archived bookmarks are kept so the app recognises them if you screenshot them again.")
        return lines.joined(separator: "\n")
    }

    private var creatorLabel: String {
        switch bookmark.category {
        case .book, .manhwa: "Author"
        case .movie: "Director / studio"
        case .place: "Area"
        case .product: "Brand"
        default: "By"
        }
    }
}

private struct ScreenshotViewer: View {
    let data: Data?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
