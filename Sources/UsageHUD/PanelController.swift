import AppKit
import HUDKit
import SwiftUI

/// Hosts usage readings on the family's glass backdrop without taking focus on hover.
@MainActor
final class PanelController {
    static let size = CGSize(width: 340, height: 392)

    let model: AppModel
    let window: HUDPanelWindow
    private let glass = HUDGlassView(style: .panel)
    private let host: NSHostingView<PanelView>
    /// MacHUD's placement clears the entire dock, including both arms at a corner.
    private var assignedFrame: CGRect?
    /// Whether the panel is meant to be on screen (`isVisible` stays true during a fade-out).
    private(set) var isShown = false
    /// Called when visibility changes (for `state` events).
    var onStateChange: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        window = HUDPanelWindow(contentRect: CGRect(origin: .zero, size: Self.size))
        window.title = "UsageHUD"
        host = NSHostingView(rootView: PanelView(model: model))
        glass.frame = CGRect(origin: .zero, size: Self.size)
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        window.contentView = glass
        center()
    }

    /// MacHUD assigns the destination before showing. The button anchor is a fallback for
    /// callers that send only a transition; it cannot describe the whole dock's geometry.
    func show(_ transition: HUDPanelTransition = HUDPanelTransition()) {
        if !isShown { model.panelOpened() }
        isShown = true
        if let from = transition.from {
            let frame = assignedFrame ?? transition.panelFrame(size: window.frame.size) ?? window.frame
            HUDAnimation.slide(in: window, from: from, to: frame)
        } else {
            HUDAnimation.fadeIn(window)
        }
        onStateChange?()
    }

    /// Hides the panel, sliding toward `to=` (the dock) when given.
    func hide(_ transition: HUDPanelTransition = HUDPanelTransition()) {
        guard isShown else { return }
        isShown = false
        if let to = transition.to {
            HUDAnimation.slideOut(window, toward: to)
        } else {
            HUDAnimation.fadeOut(window)
        }
        onStateChange?()
    }

    func toggle() { isShown ? hide() : show() }

    func setFrame(_ frame: CGRect) {
        assignedFrame = frame
        window.setFrame(frame, display: true)
    }

    private func center() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(CGPoint(x: screen.midX - Self.size.width / 2, y: screen.midY - Self.size.height / 2))
    }

    /// `--snapshot <png>`: renders the panel's content over a dark stand-in for the glass (the
    /// real backdrop needs Screen Recording to capture), for docs and UI checks.
    func writeSnapshot(to url: URL) throws {
        let view: NSView = host
        let size = view.bounds.size
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rect = CGRect(origin: .zero, size: size)
        let radius = HUDGlassView.Style.panel.cornerRadius
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
