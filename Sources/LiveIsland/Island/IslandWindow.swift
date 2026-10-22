import AppKit
import SwiftUI

/// Where the notch is, and how big the island gets.
struct IslandLayout: Equatable {
    /// The notch, in global screen coordinates (bottom-left origin).
    var notch: CGRect
    var hasNotch: Bool
    var screenTop: CGFloat

    static let wingWidth: CGFloat = 72
    static let expandedSize = CGSize(width: 640, height: 300)
    /// The window is always this big; everything outside the island is transparent and click-through.
    static let canvas = CGSize(width: 760, height: 370)

    init(screen: NSScreen) {
        screenTop = screen.frame.maxY
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notch = CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                           width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        } else {
            // No notch: a small pill under the top edge, just as tall as the menu bar.
            hasNotch = false
            let height = NSStatusBar.system.thickness
            notch = CGRect(x: screen.frame.midX - 100, y: screen.frame.maxY - height, width: 200, height: height)
        }
    }

    func size(expanded: Bool, active: Bool) -> CGSize {
        if expanded {
            return CGSize(width: max(Self.expandedSize.width, notch.width + 420), height: Self.expandedSize.height)
        }
        if active { return CGSize(width: notch.width + 2 * Self.wingWidth, height: notch.height) }
        // Idle: exactly the notch, so it disappears into it. Without a notch, nothing at all.
        return hasNotch ? notch.size : CGSize(width: notch.width, height: 0)
    }

    /// The window frame: the canvas, centred under the notch.
    var windowFrame: CGRect {
        CGRect(x: notch.midX - Self.canvas.width / 2, y: screenTop - Self.canvas.height,
               width: Self.canvas.width, height: Self.canvas.height)
    }

    /// Where the island is on screen, for hover and click-through.
    func islandFrame(expanded: Bool, active: Bool) -> CGRect {
        let size = size(expanded: expanded, active: active)
        // Without a notch, an idle island still answers to the mouse along the top edge.
        let height = max(size.height, hasNotch ? 0 : 6)
        return CGRect(x: notch.midX - size.width / 2, y: screenTop - height, width: size.width, height: height)
    }
}

/// A borderless panel above the menu bar that never takes focus away from the user's app.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel: places it on the notch screen, follows display changes, and makes it
/// respond to the mouse only where the island is.
@MainActor
final class IslandController {
    private let model: IslandModel
    private let panel = IslandPanel()
    private var layout: IslandLayout?
    private var host: NSHostingView<AnyView>?
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    init(model: IslandModel) {
        self.model = model
    }

    func show() {
        place()
        panel.orderFrontRegardless()
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            handler(event)
            return event
        } as Any)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    /// Puts the island on the screen with a notch, or the main screen.
    private func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let next = IslandLayout(screen: screen)
        guard next != layout else { return }
        layout = next
        let view = AnyView(IslandView(layout: next).environmentObject(model))
        if let host {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: IslandLayout.canvas)
            panel.contentView = host
            self.host = host
        }
        panel.setFrame(next.windowFrame, display: true)
    }

    private func trackMouse() {
        guard let layout else { return }
        let point = NSEvent.mouseLocation
        // Most moves are nowhere near the notch: skip working out the island's size for those.
        guard model.isHovering || layout.windowFrame.contains(point) else { return }
        let active = model.primary != nil
        let inside = layout.islandFrame(expanded: model.isExpanded, active: active).insetBy(dx: -6, dy: -6).contains(point)
        // Outside the island, clicks go straight through to the menu bar and apps below.
        panel.ignoresMouseEvents = !inside
        model.setHovering(inside)
    }
}
