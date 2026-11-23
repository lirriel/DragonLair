import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = AppSettings.provider
    @State private var apiKey = ""
    @State private var model = ""
    @State private var keyNotSaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $provider) {
                        ForEach(AIProviderKind.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Screenshots are sent only to the selected provider, to be read. Cover searches send titles, never screenshots.")
                }

                Section {
                    Link(destination: provider.keyURL) {
                        Label("Get a \(provider.title) key", systemImage: "arrow.up.forward.app")
                    }
                    HStack {
                        SecureField(provider.keyHint, text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        PasteButton(payloadType: String.self) { strings in
                            apiKey = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                    }
                } header: {
                    Text("API key")
                } footer: {
                    Text(provider.keySteps + " Come back here and tap paste.")
                }

                Section {
                    TextField(provider.defaultModel, text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Model")
                } footer: {
                    Text("Leave empty to use \(provider.defaultModel).")
                }

                Section {
                    NavigationLink {
                        CoverSourcesView()
                    } label: {
                        LabeledContent("Cover sources", value: "\(CoverService.allCases.filter { !AppSettings.coverKey($0).isEmpty }.count) of \(CoverService.allCases.count) on")
                    }
                } footer: {
                    Text("Optional free keys that find covers for indie books and new movies.")
                }

                Section {
                    NavigationLink {
                        BackupView()
                    } label: {
                        LabeledContent("Backup", value: AppSettings.lastBackupAt.map {
                            "Last: \($0.formatted(date: .abbreviated, time: .shortened))"
                        } ?? "Off")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: load)
            .onChange(of: provider) { load() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .alert("Couldn't save the API key", isPresented: $keyNotSaved) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The phone's Keychain refused it. Try again, or restart the phone if it keeps happening.")
            }
        }
    }

    private func load() {
        apiKey = AppSettings.apiKey(for: provider)
        let saved = AppSettings.model(for: provider)
        model = saved == provider.defaultModel ? "" : saved
    }

    private func save() {
        AppSettings.provider = provider
        AppSettings.setModel(model, for: provider)
        guard AppSettings.setAPIKey(apiKey, for: provider) else {
            keyNotSaved = true
            return
        }
        dismiss()
    }
}
