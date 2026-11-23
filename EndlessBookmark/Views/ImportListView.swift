import SwiftData
import SwiftUI

struct ImportListView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var fullScreen: FullScreenImage?

    private struct FullScreenImage: Identifiable {
        let id = UUID()
        let data: Data
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = importQueue.deleteError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                ForEach(importQueue.jobs) { job in
                    HStack(alignment: .top, spacing: 12) {
                        Group {
                            if let thumb = job.thumbnail { Image(uiImage: thumb).resizable().scaledToFill() }
                            else { Rectangle().fill(.quaternary) }
                        }
                        .frame(width: 40, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 6) {
                            status(job)
                            if job.originalDeleted {
                                Label("Original moved to Recently Deleted", systemImage: "trash")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    // Long-press to see what the screenshot actually shows.
                    .contextMenu {
                        if let data = job.previewData {
                            Button { fullScreen = FullScreenImage(data: data) } label: {
                                Label("View full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                        }
                        if job.isFailed || job.state == .nothingFound {
                            Button { importQueue.readAgain(job.id, context: context) } label: {
                                Label("Read again", systemImage: "arrow.clockwise")
                            }
                        }
                    } preview: {
                        if let data = job.previewData, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: 360, maxHeight: 640)
                        } else if let thumb = job.thumbnail {
                            Image(uiImage: thumb).resizable().scaledToFit()
                        }
                    }
                }
            }
            .fullScreenCover(item: $fullScreen) { item in
                NavigationStack {
                    ScrollView {
                        if let image = UIImage(data: item.data) { Image(uiImage: image).resizable().scaledToFit() }
                    }
                    .background(.black)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { fullScreen = nil } } }
                }
            }
            .navigationTitle("Imports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear finished") { importQueue.clearFinished() }
                        .disabled(importQueue.finishedCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if importQueue.failedCount > 0 {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Retry \(importQueue.failedCount) failed") { importQueue.retryFailed(context: context) }
                    }
                }
                if importQueue.deletableCount > 0 && !importQueue.isBusy {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete \(importQueue.deletableCount) original\(importQueue.deletableCount == 1 ? "" : "s")",
                               role: .destructive) {
                            Task { await importQueue.deleteOriginals() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func status(_ job: ImportQueue.Job) -> some View {
        switch job.state {
        case .waiting:
            Label("Waiting", systemImage: "clock").foregroundStyle(.secondary)
        case .working:
            HStack { ProgressView(); Text("Reading…") }
        case .done(let added, let notes):
            if added > 0 {
                Label("Added \(added) bookmark\(added == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if notes.isEmpty {
                Label("Nothing to save found", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "clock.arrow.circlepath")
                    .font(.footnote).foregroundStyle(.orange)
            }
        case .nothingFound:
            Label("Nothing found on this screenshot", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Button("Read again") { importQueue.readAgain(job.id, context: context) }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
        case .skipped:
            Label("Screenshot already imported", systemImage: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.footnote).lineLimit(4)
        }
    }
}
