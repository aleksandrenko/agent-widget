import AppKit
import SwiftUI

/// One floating tooltip window shared by the whole panel. It lives in its own window so it can
/// reach past the panel's edges, and shows at once (the system tooltip waits a second).
@MainActor
final class Tooltip {
    static let shared = Tooltip()

    private let window: NSPanel
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    private init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = .statusBar  // above the panel even when it is pinned (.floating)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = host
    }

    func show(title: String, detail: String? = nil) {
        host.rootView = AnyView(
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .semibold))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11))
                }
            }
            .foregroundStyle(Color(white: 0.94))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
        )
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x - 10, y: mouse.y - 22 - size.height)
        origin.x = min(origin.x, screen.maxX - size.width - 4)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

extension View {
    /// Shows a tooltip while hovered. The text may depend on where the cursor is (x, width).
    func hoverTip(_ text: @escaping (_ x: CGFloat, _ width: CGFloat) -> (String, String?)) -> some View {
        overlay(GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let (title, detail) = text(point.x, geo.size.width)
                        Tooltip.shared.show(title: title, detail: detail)
                    case .ended:
                        Tooltip.shared.hide()
                    }
                }
        })
    }

    func hoverTip(_ title: String, _ detail: String? = nil) -> some View {
        onHover { inside in
            if inside {
                Tooltip.shared.show(title: title, detail: detail)
            } else {
                Tooltip.shared.hide()
            }
        }
    }
}
