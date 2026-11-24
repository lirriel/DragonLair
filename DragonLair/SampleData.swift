#if DEBUG
import SwiftData
import SwiftUI

/// Launch with `-seedSamples` to fill an empty library with a few bookmarks for UI testing and
/// README screenshots. The items are made up and their covers are drawn here, so seeding needs
/// no network and shows no real artwork.
struct SampleData: ViewModifier {
    @Environment(\.modelContext) private var context

    private struct Sample {
        var category: BookmarkCategory
        var title: String
        var creator = ""
        var year = ""
        var summary: String
        var url = ""
        var location = ""
        var tags: [String]
        var symbol: String
        var colors: [Color]
    }

    private let samples: [Sample] = [
        Sample(category: .book, title: "The Lantern Keeper", creator: "Mira Okafor", year: "2024",
               summary: "A lighthouse keeper finds letters from the future washed ashore.",
               tags: ["fantasy", "mystery"], symbol: "light.beacon.max",
               colors: [Color(red: 0.06, green: 0.12, blue: 0.30), Color(red: 0.93, green: 0.62, blue: 0.24)]),
        Sample(category: .manhwa, title: "Ashen Crown", creator: "Han Seo-yeon", year: "2022",
               summary: "A disgraced knight returns to reclaim a burned kingdom.",
               tags: ["action", "fantasy"], symbol: "crown.fill",
               colors: [Color(red: 0.20, green: 0.05, blue: 0.25), Color(red: 0.85, green: 0.20, blue: 0.25)]),
        Sample(category: .movie, title: "Salt & Static", creator: "Jonas Velde", year: "2025",
               summary: "Two radio operators on opposite coasts share one frequency.",
               tags: ["drama"], symbol: "antenna.radiowaves.left.and.right",
               colors: [Color(red: 0.02, green: 0.35, blue: 0.40), Color(red: 0.98, green: 0.55, blue: 0.35)]),
        Sample(category: .place, title: "Moss & Kettle", summary: "Tea house with a tiny moss garden.",
               location: "Kyoto, Japan", tags: ["tea"], symbol: "leaf.fill",
               colors: [Color(red: 0.12, green: 0.30, blue: 0.18), Color(red: 0.62, green: 0.78, blue: 0.45)]),
        Sample(category: .product, title: "Pour-Over Set", creator: "Hearth & Clay",
               summary: "Stoneware dripper and carafe.", tags: ["coffee"], symbol: "cup.and.saucer.fill",
               colors: [Color(red: 0.36, green: 0.22, blue: 0.14), Color(red: 0.90, green: 0.80, blue: 0.66)]),
        Sample(category: .site, title: "Pixel Garden", summary: "Draw tiny pixel-art plants and share them.",
               url: "pixelgarden.example", tags: ["art", "tool"], symbol: "square.grid.3x3.fill",
               colors: [Color(red: 0.25, green: 0.20, blue: 0.55), Color(red: 0.40, green: 0.85, blue: 0.70)]),
    ]

    func body(content: Content) -> some View {
        content.task {
            guard ProcessInfo.processInfo.arguments.contains("-seedSamples"),
                  (try? context.fetchCount(FetchDescriptor<Bookmark>())) == 0 else { return }
            // A fresh install would otherwise run the cover upgrades meant for older libraries,
            // which clear some covers and search again.
            AppSettings.coverSourcesVersion = CoverArt.sourcesVersion
            for (index, sample) in samples.enumerated() {
                let bookmark = Bookmark(category: sample.category, title: sample.title, creator: sample.creator,
                                        year: sample.year, summary: sample.summary, url: sample.url,
                                        location: sample.location, tags: sample.tags)
                bookmark.cover = Self.cover(for: sample)
                // Nothing to look up: the cover is drawn and the titles are already English.
                bookmark.coverLookedUp = true
                bookmark.englishChecked = true
                bookmark.englishVerified = true
                // Newest first in the library, in the order listed above.
                bookmark.createdAt = .now.addingTimeInterval(-Double(index) * 3600)
                context.insert(bookmark)
            }
        }
    }

    @MainActor
    private static func cover(for sample: Sample) -> Data? {
        let renderer = ImageRenderer(content: SampleCover(sample: sample))
        renderer.scale = 3
        return renderer.uiImage?.jpegData(compressionQuality: 0.85)
    }

    private struct SampleCover: View {
        let sample: Sample

        var body: some View {
            ZStack {
                LinearGradient(colors: sample.colors, startPoint: .top, endPoint: .bottom)
                Image(systemName: sample.symbol)
                    .font(.system(size: 150))
                    .foregroundStyle(.white.opacity(0.22))
                    .offset(y: -30)
                VStack(spacing: 8) {
                    Spacer()
                    Text(sample.title.uppercased())
                        .font(.system(size: 30, weight: .heavy, design: .serif))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                    if !sample.creator.isEmpty {
                        Text(sample.creator)
                            .font(.system(size: 15, weight: .medium, design: .serif))
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(24)
                .padding(.bottom, 16)
            }
            .frame(width: 240, height: 360)
        }
    }
}
#endif
