import SwiftData
import SwiftUI

@main
struct EndlessBookmarkApp: App {
    @State private var importQueue = ImportQueue()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(importQueue)
                #if DEBUG
                .modifier(SampleData())
                #endif
        }
        .modelContainer(for: [Bookmark.self, ScannedImage.self])
    }
}
