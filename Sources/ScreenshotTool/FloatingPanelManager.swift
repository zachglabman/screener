import AppKit
import Foundation

final class FloatingPanelManager: NSObject {
    private(set) var panels: [FloatingPanel] = []
    private var allHidden = false

    // MARK: - Pin

    func pinImage(_ image: NSImage, from sourceFrame: NSRect) {
        let panel = FloatingPanel(image: image, sourceFrame: sourceFrame)

        panel.onClose = { [weak self] closedPanel in
            self?.panels.removeAll { $0.panelID == closedPanel.panelID }
        }

        panel.onEdit = { [weak self] targetPanel in
            self?.editPanel(targetPanel)
        }

        panels.append(panel)
        if allHidden { showAllPanels() }

        // Animate in
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = CGFloat(Preferences.shared.floatingWindowDefaultOpacity)
        }
    }

    // MARK: - Edit

    private func editPanel(_ panel: FloatingPanel) {
        let editor = AnnotationEditorWindowController(image: panel.image)
        // The pin updates in place with the annotated version
        editor.onSave = { [weak panel] annotatedImage in
            panel?.updateImage(annotatedImage)
        }
        editor.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Visibility

    func hideAllPanels() {
        panels.forEach { $0.orderOut(nil) }
        allHidden = true
    }

    func showAllPanels() {
        panels.forEach { $0.orderFrontRegardless() }
        allHidden = false
    }

    func toggleAllPanels() {
        if allHidden { showAllPanels() } else { hideAllPanels() }
    }

    func closeAllPanels() {
        let toClose = panels
        panels.removeAll()
        toClose.forEach { $0.close() }
    }

    func unlockAllPanels() {
        panels.filter { $0.isClickThrough }.forEach { $0.setLocked(false) }
    }

    // MARK: - Menu items for panel list

    func makePanelMenuItems() -> [NSMenuItem] {
        return panels.enumerated().map { i, panel in
            let lock = panel.isClickThrough ? " — locked" : ""
            let item = NSMenuItem(
                title: "Pin \(i + 1) (\(Int(panel.frame.width))×\(Int(panel.frame.height)))\(lock)",
                action: #selector(focusPanel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = panel
            return item
        }
    }

    // Brings a pin forward (unlocking it, so you can interact with it again)
    @objc private func focusPanel(_ sender: NSMenuItem) {
        guard let panel = sender.representedObject as? FloatingPanel else { return }
        if allHidden { showAllPanels() }
        panel.setLocked(false)
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}
