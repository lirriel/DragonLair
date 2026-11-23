import SwiftData
import SwiftUI

struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var folderName = Backup.folderDisplayName
    @State private var lastBackup = AppSettings.lastBackupAt
    @State private var lastError = AppSettings.lastBackupError
    @State private var choosingFolder = false
    @State private var working = false
    @State private var pendingRestore: BackupFile?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder", value: folderName ?? "Not set")
                Button(folderName == nil ? "Choose folder…" : "Change folder…") { choosingFolder = true }
            } header: {
                Text("Backup folder")
            } footer: {
                Text("Pick or create a folder in iCloud Drive, e.g. “Dragon Lair”. The backup then syncs to iCloud and survives deleting the app. API keys aren't included.")
            }

            if folderName != nil {
                Section {
                    LabeledContent("Last backup",
                                   value: lastBackup?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    if let lastError {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.footnote)
                    }
                    Button("Back up now") { run { try Backup.write(context: context); message = "Backup saved." } }
                    Button("Restore from backup…") { run { pendingRestore = try Backup.read() } }
                } footer: {
                    Text("Backs up automatically after each import and whenever you leave the app.")
                }
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .overlay { if working { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            run {
                try Backup.setFolder(url)
                folderName = Backup.folderDisplayName
                // A backup already in the folder (e.g. after reinstalling) is offered for restore
                // before anything overwrites it.
                if let existing = try? Backup.read() {
                    pendingRestore = existing
                } else {
                    try Backup.write(context: context)
                    message = "Backup saved to “\(folderName ?? url.lastPathComponent)”."
                }
            }
        }
        .alert("Restore from backup?", isPresented: restoreBinding, presenting: pendingRestore) { backup in
            Button("Restore") { run { restore(backup) } }
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text("Backup from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) with \(backup.bookmarks.count) bookmarks. Bookmarks you already have stay as they are; missing ones are added.")
        }
        .alert(message ?? "", isPresented: messageBinding) { Button("OK") {} }
    }

    private func restore(_ backup: BackupFile) {
        do {
            let (added, kept) = try Backup.restore(backup, context: context)
            message = "Added \(added) bookmark\(added == 1 ? "" : "s")" + (kept > 0 ? ", kept \(kept) you already had." : ".")
            try Backup.write(context: context)
        } catch {
            message = error.localizedDescription
        }
    }

    private func run(_ action: () throws -> Void) {
        working = true
        defer {
            working = false
            lastBackup = AppSettings.lastBackupAt
            lastError = AppSettings.lastBackupError
        }
        do {
            try action()
        } catch {
            AppSettings.lastBackupError = error.localizedDescription
        }
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }
}
