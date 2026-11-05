import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Receives images from the Share sheet and drops them into the shared inbox.
/// The AI reading happens in the main app, which has no memory or time limits.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        Task { await model.save(providers) }
    }
}

@MainActor
@Observable
final class ShareModel {
    enum State { case saving, saved(Int), failed(String) }
    var state: State = .saving

    func save(_ providers: [NSItemProvider]) async {
        var saved = 0
        for provider in providers {
            if let data = try? await provider.loadImageData() {
                do {
                    try SharedInbox.add(data)
                    saved += 1
                } catch {
                    state = .failed("Couldn't save to the app. \(error.localizedDescription)")
                    return
                }
            }
        }
        state = saved > 0 ? .saved(saved) : .failed("No images found to save.")
    }
}

private extension NSItemProvider {
    func loadImageData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: .image) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}

private struct ShareView: View {
    let model: ShareModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .saving:
                ProgressView()
                Text("Saving…").font(.headline)
            case .saved(let count):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52)).foregroundStyle(.green)
                Text("Saved \(count) screenshot\(count == 1 ? "" : "s")").font(.headline)
                Text("Open Dragon Lair and they'll be sorted into your collection.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52)).foregroundStyle(.orange)
                Text(message).font(.subheadline).multilineTextAlignment(.center)
            }
            if case .saving = model.state {} else {
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task(id: stateKey) {
            // Close on its own shortly after a successful save.
            if case .saved = model.state {
                try? await Task.sleep(for: .seconds(1.5))
                done()
            }
        }
    }

    private var stateKey: String {
        switch model.state {
        case .saving: "saving"
        case .saved: "saved"
        case .failed: "failed"
        }
    }
}
