import SwiftUI

/// Free personal keys for catalogues that find covers the keyless sources miss.
struct CoverSourcesView: View {
    @State private var keys: [CoverService: String] = [:]

    var body: some View {
        Form {
            ForEach(CoverService.allCases) { service in
                Section {
                    Link(destination: service.keyURL) {
                        Label("Get a \(service.title) key", systemImage: "arrow.up.forward.app")
                    }
                    HStack {
                        SecureField(service.keyHint, text: binding(for: service))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        PasteButton(payloadType: String.self) { strings in
                            keys[service] = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                    }
                } header: {
                    Text(service.title)
                } footer: {
                    Text("\(service.purpose) \(service.keySteps)")
                }
            }

            Section {
                Text("Keys stay in your phone's Keychain and are only sent to their own service. Without a key, that source is skipped.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            // Required by TMDB's terms for apps that use its API.
            Section("Credits") {
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                Link("themoviedb.org", destination: URL(string: "https://www.themoviedb.org")!)
            }
        }
        .navigationTitle("Cover sources")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for service in CoverService.allCases { keys[service] = AppSettings.coverKey(service) }
        }
        .onDisappear {
            for service in CoverService.allCases { AppSettings.setCoverKey(keys[service] ?? "", for: service) }
        }
    }

    private func binding(for service: CoverService) -> Binding<String> {
        Binding(get: { keys[service] ?? "" }, set: { keys[service] = $0 })
    }
}
