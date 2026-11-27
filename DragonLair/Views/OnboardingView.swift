import SafariServices
import SwiftData
import SwiftUI

/// First-run screens: welcome, an AI key, and the ways screenshots get in. Shown while the
/// library is empty and no provider has a key, until finished or skipped once.
struct OnboardingView: View {
    enum Step: String { case welcome, key, ready, restore }
    /// Where the library goes once onboarding closes.
    enum Exit { case library, pick, review }

    /// Saved so a relaunch (say, after copying a key elsewhere) comes back to the same step.
    @SceneStorage("onboarding.step") private var step: Step = .welcome
    @State private var cameFromRestore = false
    /// The library's "Add AI key" opens straight on the key step.
    var startAt: Step = .welcome
    let finish: (Exit) -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome:
                    WelcomeStep(start: { go(.key) }, restore: { go(.restore) })
                case .key:
                    KeyStep(restored: cameFromRestore, done: { go(.ready) })
                case .ready:
                    ReadyStep(finish: close)
                case .restore:
                    RestoreStep(addKey: { cameFromRestore = true; go(.key) }, later: { close(.library) })
                }
            }
            .toolbar {
                if step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { back() } label: { Image(systemName: "chevron.backward") }
                            .accessibilityLabel("Back")
                    }
                }
                if step == .key {
                    ToolbarItem(placement: .topBarTrailing) { Button("Skip") { close(.library) } }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .background(Color("Parchment").ignoresSafeArea())
        }
        .onAppear { if startAt != .welcome { step = startAt } }
    }

    private func go(_ next: Step) { withAnimation { step = next } }

    private func back() {
        switch step {
        case .key: go(cameFromRestore ? .restore : .welcome)
        case .ready: go(.key)
        default: go(.welcome)
        }
    }

    private func close(_ exit: Exit) {
        AppSettings.onboardingDone = true
        step = .welcome
        finish(exit)
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let start: () -> Void
    let restore: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("Icon")
                    .resizable().scaledToFill()
                    .frame(width: 128, height: 128)
                    .clipShape(.rect(cornerRadius: 29))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                    .accessibilityHidden(true)
                Text("Screenshot it, and it's saved.")
                    .font(.largeTitle.bold()).fontDesign(.serif)
                    .multilineTextAlignment(.center)
                Text("Dragon Lair keeps a hoard of the things you screenshot to read, watch, visit or buy, and turns each one into a bookmark.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 18) {
                    Point(icon: "photo", title: "Screenshots in",
                          text: "Pick them, share them from any app, or let the app watch your Screenshots album.")
                    Point(icon: "sparkles", title: "Bookmarks out",
                          text: "AI reads each one: title, author, year, tags, and an official cover.")
                    Point(icon: "lock", title: "No account, no server",
                          text: "Your hoard stays on this phone. You bring your own AI key.")
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 28).padding(.top, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                PrimaryButton("Get started", action: start)
                Button("Restore from a backup", action: restore).frame(minHeight: 44)
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
            .background(Color("Parchment"))
        }
    }
}

private struct Point: View {
    let icon: String, title: String, text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Key

private struct KeyStep: View {
    let restored: Bool
    let done: () -> Void

    enum Status: Equatable { case empty, badFormat, checking, checked(KeyCheck) }

    @State private var provider: AIProviderKind = .gemini
    @State private var showOthers = false
    @State private var key = ""
    @State private var status: Status = .empty
    @State private var showConsole = false
    @State private var keyNotSaved = false
    /// Continue is hidden while typing, so it never sits over the key field and its message.
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add your \(provider.shortName) key").font(.title.bold()).fontDesign(.serif)
                Text(restored ? "Your bookmarks are back. Backups don't include the key, so add it again to keep importing."
                              : "The AI reads your screenshots. The key stays in this phone's Keychain.")
                    .foregroundStyle(.secondary)

                if showOthers {
                    Picker("AI provider", selection: $provider) {
                        ForEach([AIProviderKind.gemini, .claude, .openai]) { Text($0.shortName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 0) {
                    StepRow(number: 1, text: provider.setupStep1)
                    Divider().padding(.leading, 36)
                    StepRow(number: 2, text: "\(provider.setupStep2) Then tap Done and Paste.")
                }
                .padding(.horizontal, 16)
                .background(.background, in: .rect(cornerRadius: 14))

                Button { showConsole = true } label: {
                    Label("Open \(provider.consoleName)", systemImage: "safari")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .background(.background, in: .rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(provider.shortName) API key").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        SecureField(provider.keyHint, text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($typing)
                            .submitLabel(.done)
                        PasteButton(payloadType: String.self) { strings in
                            key = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        }
                        .labelStyle(.titleOnly).buttonBorderShape(.capsule)
                    }
                    .padding(.leading, 16).padding(.trailing, 6).frame(minHeight: 52)
                    .background(.background, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(borderColor, lineWidth: 2))
                    statusLine
                }

                Label(provider.setupNote, systemImage: "info.circle")
                    .font(.footnote)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))

                if !showOthers {
                    Button("Use Claude or ChatGPT instead") { withAnimation { showOthers = true } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if !typing {
            VStack(spacing: 4) {
                PrimaryButton("Continue", action: save).disabled(!canContinue)
                if case .checked(.unknown) = status {
                    Text("Couldn't test the key right now. You can continue and it'll be used anyway.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Color("Parchment"))
            }
        }
        .sheet(isPresented: $showConsole) { SafariView(url: provider.keyURL).ignoresSafeArea() }
        .onChange(of: provider) { key = ""; status = .empty }
        .task(id: key) { await check() }
        // A key that works needs nothing more typed: show Continue.
        .onChange(of: status) { _, new in if new == .checked(.works) { typing = false } }
        .alert("Couldn't save the API key", isPresented: $keyNotSaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The phone's Keychain refused it. Try again, or restart the phone if it keeps happening.")
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .empty: EmptyView()
        case .badFormat:
            Label {
                Text("That doesn't look like a \(provider.shortName) key. They start with \(Text(provider.keyPrefix).monospaced()). Copy the whole key and paste again.")
            } icon: { Image(systemName: "exclamationmark.circle") }
                .font(.subheadline).foregroundStyle(.red)
        case .checking:
            Label { Text("Checking the key…") } icon: { ProgressView() }
                .font(.subheadline).foregroundStyle(.secondary)
        case .checked(.works):
            Label("Key works. \(provider.shortName) answered.", systemImage: "checkmark.circle")
                .font(.subheadline).foregroundStyle(.green)
        case .checked(.rejected):
            Label("\(provider.shortName) turned this key down. Check you copied all of it\(provider == .gemini ? "" : " and that billing is set up").",
                  systemImage: "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(.red)
        case .checked(.unknown(let why)):
            Label(why, systemImage: "wifi.exclamationmark").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var borderColor: Color {
        switch status {
        case .badFormat, .checked(.rejected): .red
        case .checked(.works): .green
        default: .clear
        }
    }

    private var canContinue: Bool {
        switch status {
        case .checked(.works), .checked(.unknown): true
        default: false
        }
    }

    private func check() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = .empty; return }
        guard provider.keyLooksValid(trimmed) else { status = .badFormat; return }
        status = .checking
        // Typing a key by hand: wait for a pause before asking the provider.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let result = await AIClient(provider: provider, apiKey: trimmed, model: provider.setupModel).checkKey()
        guard !Task.isCancelled else { return }
        status = .checked(result)
    }

    private func save() {
        guard AppSettings.setAPIKey(key, for: provider) else {
            keyNotSaved = true
            return
        }
        AppSettings.provider = provider
        // Only when nothing was chosen before; empty means the default.
        if AppSettings.model(for: provider) == provider.defaultModel {
            AppSettings.setModel(provider.setupModel == provider.defaultModel ? "" : provider.setupModel, for: provider)
        }
        done()
    }
}

private struct StepRow: View {
    let number: Int, text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold())
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15), in: .circle)
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Ready

private struct ReadyStep: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    let finish: (OnboardingView.Exit) -> Void

    @State private var access = ScreenshotLibrary.status
    @State private var watching = AppSettings.watchScreenshots && ScreenshotLibrary.canRead
    @State private var recent: [String] = []
    @State private var deleting = AppSettings.deleteOriginalsAfterImport && ScreenshotLibrary.canRead

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image("Icon").resizable().scaledToFill()
                        .frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 15))
                        .accessibilityHidden(true)
                    Text("Your lair is ready. Bring it treasure.").font(.title.bold()).fontDesign(.serif)
                }
                Text("Ways to add screenshots, and to tidy up after. Use any of them, any time.").foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        WayIcon("photo.on.rectangle.angled")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Watch my Screenshots album").font(.headline)
                            Text(watching ? "On. New screenshots wait for your review when you open the app."
                                          : "New screenshots wait for your review. iOS asks for photo access when you tap Turn on.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if watching {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("On")
                        } else if access == .denied || access == .restricted {
                            Button("Settings") { openSettings() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        } else {
                            Button("Turn on") { Task { await turnOnWatching() } }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.vertical, 12)
                    if access == .limited {
                        Button("Allow access to all photos") { openSettings() }
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 44).padding(.bottom, 10)
                    }
                    Divider().padding(.leading, 44)
                    HStack(spacing: 12) {
                        WayIcon("trash")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tidy up after import").font(.headline)
                            Text(deleting ? "On. Bookmarked screenshots go to Recently Deleted; you confirm each time."
                                          : "Delete originals once they're bookmarked. You confirm each time, with a notification if you're in another app.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if deleting {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("On")
                        } else if access == .denied || access == .restricted {
                            Button("Settings") { openSettings() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        } else {
                            Button("Turn on") { Task { await turnOnDeleting() } }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.vertical, 12)
                    Divider().padding(.leading, 44)
                    HStack(alignment: .top, spacing: 12) {
                        WayIcon("square.and.arrow.up")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share from any app").font(.headline)
                            Text("Tap a screenshot's preview, then Share › Dragon Lair. Not in the row? Swipe to More and add it to Favorites.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                    Divider().padding(.leading, 44)
                    HStack(spacing: 12) {
                        WayIcon("plus.viewfinder")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pick them yourself").font(.headline)
                            Text("Up to 50 at a time, from the + button.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 16)
                .background(.background, in: .rect(cornerRadius: 14))

                if watching && !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(recent.count == 1 ? "**Try it now:** read your latest screenshot. You'll choose whether to keep it first."
                                               : "**Try it now:** read your \(recent.count) latest screenshots. You'll pick which to keep first.")
                            .font(.subheadline)
                        Button {
                            importQueue.pendingReview.append(contentsOf: recent)
                            finish(.review)
                        } label: {
                            Text("Review \(recent.count) screenshot\(recent.count == 1 ? "" : "s")")
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .background(.background, in: .rect(cornerRadius: 12))
                    }
                    .padding(14)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                PrimaryButton("Choose screenshots") { finish(.pick) }
                Button("Not now, go to my library") { finish(.library) }.frame(minHeight: 44)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Color("Parchment"))
        }
        .onAppear { if watching { loadRecent() } }
    }

    /// Looked up once, not on every redraw: it reads the whole Screenshots album. Kept small so a
    /// first import doesn't run into a free tier's rate limit.
    private func loadRecent() {
        recent = Array(importQueue.unhandled(ScreenshotLibrary.assetIDs(from: .distantPast), context: context).suffix(5))
    }

    private func turnOnWatching() async {
        access = await ScreenshotLibrary.requestAccess()
        guard ScreenshotLibrary.canRead else { return }
        AppSettings.watchSince = .now
        AppSettings.watchScreenshots = true
        AppSettings.askBeforeImportingWatched = true
        watching = true
        importQueue.refreshWatching(context: context)
        loadRecent()
    }

    /// Needs photo access to delete, and notifications to ask when an import ends in the background.
    private func turnOnDeleting() async {
        access = await ScreenshotLibrary.requestAccess()
        guard ScreenshotLibrary.canRead else { return }
        AppSettings.deleteOriginalsAfterImport = true
        deleting = true
        await ImportNotifier.requestAuthorization()
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

private struct WayIcon: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name).font(.title3).foregroundStyle(.tint).frame(width: 32).accessibilityHidden(true)
    }
}

// MARK: - Restore

private struct RestoreStep: View {
    @Query private var bookmarks: [Bookmark]
    let addKey: () -> Void
    let later: () -> Void

    var body: some View {
        BackupView()
            .safeAreaInset(edge: .bottom) {
                if !bookmarks.isEmpty {
                    VStack(spacing: 6) {
                        Text("\(bookmarks.count) bookmark\(bookmarks.count == 1 ? " is" : "s are") back. Backups don't include your AI key.")
                            .font(.subheadline).multilineTextAlignment(.center)
                        PrimaryButton("Add AI key", action: addKey)
                        Button("Later, show my library", action: later).frame(minHeight: 44)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(.bar)
                }
            }
    }
}

// MARK: - Shared pieces

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}

/// The provider's key page, inside the app so getting back is one tap.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private extension AIProviderKind {
    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .openai: "ChatGPT"
        case .gemini: "Gemini"
        }
    }

    var consoleName: String {
        switch self {
        case .claude: "Claude Console"
        case .openai: "OpenAI Platform"
        case .gemini: "Google AI Studio"
        }
    }

    var setupStep1: String {
        switch self {
        case .claude: "Sign in and add a few dollars of credit under Billing."
        case .openai: "Sign in and add a payment method under Billing."
        case .gemini: "Sign in with your Google account. No card needed."
        }
    }

    var setupStep2: String {
        switch self {
        case .claude: "Tap Create Key and copy it."
        case .openai: "Tap Create new secret key and copy it."
        case .gemini: "Tap Create API key and copy it."
        }
    }

    var setupNote: String {
        switch self {
        case .claude:
            "Paid per screenshot; a Claude subscription doesn't cover it. Setup picks a lower-cost model that reads screenshots well. You can change it in Settings."
        case .openai:
            "Paid per screenshot; ChatGPT Plus doesn't cover it. Setup picks a lower-cost model. You can change it in Settings."
        case .gemini:
            "Free to start. On the free tier, Google may use what you send to improve its products, and that includes your screenshots. A paid plan, Claude or ChatGPT avoids that."
        }
    }
}
