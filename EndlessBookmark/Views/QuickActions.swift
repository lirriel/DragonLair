import OSLog
import SwiftUI
import UIKit

/// Filter Console.app by subsystem "com.lirriel.endlessbookmark" to follow these.
let uiLog = Logger(subsystem: "com.lirriel.endlessbookmark", category: "ui")

/// When the last navigation was requested, so the opened screen can log how long it took.
@MainActor var lastNavigationRequest = Date.now

/// Long-press a bookmark, slide onto one of the icons that fan out above it, and let go to
/// apply it (like Instagram's share wheel). Letting go anywhere else cancels.
@MainActor
@Observable
final class QuickActions {
    struct Action: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let tint: Color
        let run: (Bookmark) -> Void
    }

    private(set) var bookmark: Bookmark?
    private(set) var rowFrame: CGRect = .zero
    private(set) var actions: [Action] = []
    private(set) var hovered: Action.ID?
    private(set) var positions: [Action.ID: CGPoint] = [:]

    var isActive: Bool { bookmark != nil }

    func begin(_ bookmark: Bookmark, rowFrame: CGRect, screen: CGSize) {
        self.bookmark = bookmark
        self.rowFrame = rowFrame
        actions = Self.actions(for: bookmark)
        positions = Self.layout(actions.map(\.id), around: rowFrame, in: screen)
        hovered = nil
        uiLog.info("Quick actions opened for “\(bookmark.title, privacy: .private(mask: .hash))”")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func move(to point: CGPoint) {
        let nearest = positions.min { $0.value.distance(to: point) < $1.value.distance(to: point) }
        let next = nearest.flatMap { $0.value.distance(to: point) < 44 ? $0.key : nil }
        if next != hovered, let next {
            uiLog.debug("Quick actions hovering \(next, privacy: .public)")
            UISelectionFeedbackGenerator().selectionChanged()
        }
        hovered = next
    }

    /// Applies the hovered action, if any. `cancelled` is for when iOS took the touch away
    /// (e.g. a system gesture), which never applies anything.
    func end(cancelled: Bool = false) {
        if !cancelled, let bookmark, let action = actions.first(where: { $0.id == hovered }) {
            uiLog.info("Quick action \(action.id, privacy: .public) on “\(bookmark.title, privacy: .private(mask: .hash))”")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { action.run(bookmark) }
        } else if bookmark != nil {
            uiLog.info("Quick actions dismissed (\(cancelled ? "cancelled by system" : "released away from icons", privacy: .public))")
        }
        bookmark = nil
        hovered = nil
    }

    private static func actions(for bookmark: Bookmark) -> [Action] {
        let statuses: [Action] = BookmarkStatus.allCases.filter { $0 != bookmark.status }.map { status in
            let tint: Color = switch status {
            case .saved: .blue
            case .started: .green
            case .dropped: .orange
            }
            return Action(id: status.rawValue,
                          title: status == .saved ? "Bring back" : status.label(for: bookmark.category),
                          symbol: status == .saved ? "arrow.uturn.backward" : status.symbol,
                          tint: tint, run: { $0.status = status })
        }
        return statuses + [Action(id: "delete", title: "Delete", symbol: "trash", tint: .red, run: { $0.delete() })]
    }

    /// A shallow arc centred above the row, or below it when the row is near the top.
    private static func layout(_ ids: [Action.ID], around row: CGRect, in screen: CGSize) -> [Action.ID: CGPoint] {
        let spacing: CGFloat = 70
        let above = row.minY > 230
        let baseY = above ? row.minY - 50 : row.maxY + 50
        let middle = CGFloat(ids.count - 1) / 2
        var result: [Action.ID: CGPoint] = [:]
        for (i, id) in ids.enumerated() {
            let offset = CGFloat(i) - middle
            let lift = (middle * middle - offset * offset) * 8 // middle icons sit further from the row
            result[id] = CGPoint(x: screen.width / 2 + offset * spacing, y: above ? baseY - lift : baseY + lift)
        }
        return result
    }
}

/// Draws the dimmed backdrop and the icons. Placed over the whole navigation stack, ignoring
/// safe areas, so its coordinates match the global ones the gesture reports.
struct QuickActionsOverlay: View {
    @Environment(QuickActions.self) private var quick

    var body: some View {
        if quick.isActive {
            ZStack {
                Color.black.opacity(0.3)
                // Keeps the pressed row visible above the dimming.
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.8), lineWidth: 2)
                    .frame(width: quick.rowFrame.width, height: quick.rowFrame.height)
                    .position(x: quick.rowFrame.midX, y: quick.rowFrame.midY)
                ForEach(quick.actions) { action in
                    if let point = quick.positions[action.id] {
                        let isHovered = quick.hovered == action.id
                        VStack(spacing: 6) {
                            Image(systemName: action.symbol)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(isHovered ? .white : action.tint)
                                .frame(width: 52, height: 52)
                                .background {
                                    // Fading a solid circle over the material animates cleanly,
                                    // unlike switching between the two styles.
                                    Circle().fill(.regularMaterial)
                                    Circle().fill(action.tint).opacity(isHovered ? 1 : 0)
                                }
                                .shadow(radius: 4, y: 2)
                                .scaleEffect(isHovered ? 1.25 : 1)
                        }
                        .position(point)
                    }
                }
                if let action = quick.actions.first(where: { $0.id == quick.hovered }),
                   let point = quick.positions[action.id] {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: point.x, y: point.y - 56)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
            .animation(.spring(duration: 0.2), value: quick.hovered)
            .transition(.opacity)
        }
    }
}

extension View {
    /// Adds the long-press-and-slide actions to a bookmark row.
    func quickActions(_ bookmark: Bookmark) -> some View {
        modifier(QuickActionsGesture(bookmark: bookmark))
    }
}

/// Uses UIKit's long-press recognizer rather than a SwiftUI gesture: it leaves ordinary taps
/// alone (so rows open on the first tap), fails as soon as the finger starts scrolling, and
/// keeps reporting the finger's position after the press is recognised, for the slide.
private struct QuickActionsGesture: ViewModifier {
    let bookmark: Bookmark
    @Environment(QuickActions.self) private var quick
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .gesture(LongPressRecognizer { state, location in
                switch state {
                case .began:
                    let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.size
                        ?? CGSize(width: 400, height: 800)
                    withAnimation(.easeOut(duration: 0.15)) {
                        quick.begin(bookmark, rowFrame: frame, screen: screen)
                    }
                    quick.move(to: location)
                case .changed:
                    quick.move(to: location)
                case .ended:
                    withAnimation(.easeOut(duration: 0.15)) { quick.end() }
                case .cancelled, .failed:
                    withAnimation(.easeOut(duration: 0.15)) { quick.end(cancelled: true) }
                default:
                    break
                }
            })
    }
}

private struct LongPressRecognizer: UIGestureRecognizerRepresentable {
    let onChange: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.35
        // Don't hold back the row's own tap while deciding whether this is a long press.
        recognizer.delaysTouchesBegan = false
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        onChange(recognizer.state, context.converter.location(in: .global))
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
