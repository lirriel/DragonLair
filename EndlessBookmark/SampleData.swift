#if DEBUG
import SwiftData
import SwiftUI

/// Launch with `-seedSamples` to fill an empty library with a few bookmarks for UI testing.
struct SampleData: ViewModifier {
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.task {
            guard ProcessInfo.processInfo.arguments.contains("-seedSamples"),
                  (try? context.fetchCount(FetchDescriptor<Bookmark>())) == 0 else { return }
            let samples = [
                Bookmark(category: .manhwa, title: "Solo Leveling", creator: "Chugong", year: "2018",
                         summary: "A weak hunter gains the power to level up.", tags: ["action", "fantasy"]),
                Bookmark(category: .book, title: "Project Hail Mary", creator: "Andy Weir", year: "2021",
                         summary: "A lone astronaut must save Earth.", tags: ["sci-fi"]),
                Bookmark(category: .movie, title: "Past Lives", creator: "Celine Song", year: "2023",
                         summary: "Childhood friends reconnect decades later.", tags: ["drama"]),
                Bookmark(category: .place, title: "Café Kitsuné",
                         summary: "Coffee shop by the Palais-Royal gardens.", location: "Paris, France", tags: ["coffee"]),
                Bookmark(category: .site, title: "Excalidraw",
                         summary: "Hand-drawn style whiteboard.", url: "excalidraw.com", tags: ["tool"]),
            ]
            samples.forEach(context.insert)
        }
    }
}
#endif
