import SwiftData
import SwiftUI

@main
struct EndlessBookmarkApp: App {
    @State private var importQueue = ImportQueue()
    private let container: ModelContainer

    init() {
        do {
            container = try .library()
        } catch {
            // Nothing works without the library; the error says which migration is missing.
            fatalError("Couldn't open the library: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(importQueue)
                #if DEBUG
                .modifier(SampleData())
                #endif
        }
        .modelContainer(container)
    }
}
