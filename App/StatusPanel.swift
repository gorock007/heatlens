import AppKit
import SwiftUI

/// The menu-bar thermometer and the panel it opens. The panel opens under the icon and closes
/// when the user clicks elsewhere; once dragged it's detached and floats until closed. Escape,
/// or the icon, closes it. Holds no timers: everything here runs from a click, a key or a resize.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: StatusPanel
    private var isDetached = false
    /// Where the panel's top edge sits: under the icon, or wherever the user dropped it.
    private var anchorTop: CGFloat = 0

    init(@ViewBuilder content: () -> some View) {
        panel = StatusPanel(content: PanelChrome(content: content()))
        super.init()
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "HeatLens")
            button.target = self
            button.action = #selector(toggle)
        }
    }

    /// Opens the panel under the icon, as a click on it would.
    func show() {
        open()
    }

    @objc private func toggle() {
        if panel.isVisible { close() } else { open() }
    }

    private func open() {
        isDetached = false
        panel.level = .statusBar
        panel.layoutIfNeeded()
        positionUnderIcon()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel.orderOut(nil)
        isDetached = false
    }

    /// Only a user drag sends this; the moves made here to place or resize the panel don't.
    func windowWillMove(_ notification: Notification) {
        isDetached = true
        panel.level = .floating
    }

    func windowDidMove(_ notification: Notification) {
        guard isDetached else { return }
        anchorTop = panel.frame.maxY
    }

    private func positionUnderIcon() {
        guard let buttonWindow = statusItem.button?.window else { return }
        let icon = buttonWindow.frame
        anchorTop = icon.minY - 4
        var frame = panel.frame
        frame.origin.x = icon.midX - frame.width / 2
        frame.origin.y = anchorTop - frame.height
        panel.setFrame(clamped(frame, to: buttonWindow.screen), display: true)
    }

    /// Keeps the top edge where it was as the content grows or shrinks, inside the visible screen.
    private func keepOnScreen() {
        var frame = panel.frame
        frame.origin.y = anchorTop - frame.height
        let fitted = clamped(frame, to: panel.screen)
        if fitted != panel.frame { panel.setFrame(fitted, display: true) }
    }

    private func clamped(_ frame: NSRect, to screen: NSScreen?) -> NSRect {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return frame }
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - frame.width - 4)
        frame.origin.y = min(max(frame.minY, visible.minY + 4), visible.maxY - frame.height)
        return frame
    }

    func windowDidResize(_ notification: Notification) {
        if isDetached { keepOnScreen() } else { positionUnderIcon() }
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isDetached else { return }
        // A sheet opening takes key before it's attached, so look once the click has settled:
        // only a click outside HeatLens closes an attached panel.
        Task { @MainActor in
            guard !isDetached, panel.isVisible, !panel.isKeyWindow, panel.attachedSheet == nil,
                  NSApp.keyWindow?.sheetParent !== panel else { return }
            close()
        }
    }
}

/// Borderless and non-activating, so opening it doesn't pull focus from the app the user is
/// looking at, but it still takes key for Escape and text fields.
private final class StatusPanel: NSPanel {
    var onEscape: () -> Void = {}

    init(content: some View) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        contentViewController = host
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes the panel from anywhere in it, ahead of buttons and text fields. A sheet is
    /// its own window, so Escape there never reaches this.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onEscape()
            return
        }
        super.sendEvent(event)
    }

}

/// Rounded, translucent backing for the popover content; its background is the drag handle.
private struct PanelChrome<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .background(DragBackground())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

private struct DragBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> DragEffectView {
        let view = DragEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: DragEffectView, context: Context) {}
}

private final class DragEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
