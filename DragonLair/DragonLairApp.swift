import SwiftData
import SwiftUI

@main
struct DragonLairApp: App {
    @State private var importQueue: ImportQueue
    private let container: ModelContainer
    private let notifier = ImportNotifier()

    init() {
        let queue = ImportQueue()
        _importQueue = State(initialValue: queue)
        notifier.register(queue: queue)
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
