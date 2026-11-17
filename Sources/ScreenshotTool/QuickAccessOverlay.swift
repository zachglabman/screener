import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Quick Access Overlay Manager
// Thumbnails stack in the corner (newest nearest the corner) and stay until
// dismissed. Nothing is written to disk unless you Save or drag one out.
final class QuickAccessOverlay {
    private static var activeOverlays: [QuickAccessOverlayWindow] = []
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 16

    static func show(with image: NSImage, pinFrame: CGRect, floatingPanelManager: FloatingPanelManager) {
        let overlay = QuickAccessOverlayWindow(
            image: image,
            pinFrame: pinFrame,
            floatingPanelManager: floatingPanelManager
        )
        overlay.onDismiss = {
            activeOverlays.removeAll { $0 === overlay }
            layout(animated: true)
        }
        activeOverlays.append(overlay)
        layout(animated: true, appearing: overlay)
        overlay.show()
    }

    static func dismissAll() {
        activeOverlays.forEach { $0.dismiss() }
    }

    /// Positions every overlay in its screen's configured corner.
    static func layout(animated: Bool, appearing: QuickAccessOverlayWindow? = nil) {
        let pos = Preferences.shared.overlayPosition
        var stackOffset: [ObjectIdentifier: CGFloat] = [:] // per screen

        for overlay in activeOverlays.reversed() {
            let screen = overlay.homeScreen
            let key = ObjectIdentifier(screen)
            let offset = stackOffset[key, default: 0]
            let frame = screen.visibleFrame
            let size = overlay.frame.size
            stackOffset[key] = offset + size.height + spacing

            let origin: NSPoint
            switch pos {
            case .bottomRight: origin = NSPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin + offset)
            case .bottomLeft:  origin = NSPoint(x: frame.minX + margin, y: frame.minY + margin + offset)
            case .topRight:    origin = NSPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin - offset)
            case .topLeft:     origin = NSPoint(x: frame.minX + margin, y: frame.maxY - size.height - margin - offset)
            }

            if animated && overlay !== appearing {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    overlay.animator().setFrameOrigin(origin)
                }
            } else {
                overlay.setFrameOrigin(origin)
            }
        }
    }
}

// MARK: - Overlay Window
// Non-activating so it never steals focus from the app you're working in
final class QuickAccessOverlayWindow: NSPanel {
    var onDismiss: (() -> Void)?
    let homeScreen: NSScreen
    private var image: NSImage
    private var pinFrame: CGRect
    private weak var floatingPanelManager: FloatingPanelManager?
    private var dismissTimer: Timer?
    private var isDismissing = false
    private var isEditing = false
    private var overlayView: OverlayContentView!

    /// Slide direction: thumbnails come in from (and leave toward) the nearest edge.
    private var slideDirection: CGFloat {
        switch Preferences.shared.overlayPosition {
        case .bottomRight, .topRight: return 1
        case .bottomLeft, .topLeft:   return -1
        }
    }

    init(image: NSImage, pinFrame: CGRect, floatingPanelManager: FloatingPanelManager) {
        self.image = image
        self.pinFrame = pinFrame
        self.floatingPanelManager = floatingPanelManager
        let mouse = NSEvent.mouseLocation
        self.homeScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]

        let size = OverlayContentView.size(for: image.size)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        overlayView = OverlayContentView(image: image)
        overlayView.frame = NSRect(origin: .zero, size: size)
        overlayView.onCopy = { [weak self] in self?.copyToClipboard() }
        overlayView.onSave = { [weak self] in self?.saveToDisk() }
        overlayView.onPin  = { [weak self] in self?.pinAsFloat() }
        overlayView.onEdit = { [weak self] in self?.openEditor() }
        overlayView.onDismiss = { [weak self] in self?.dismiss() }
        overlayView.onDragCompleted = { [weak self] in self?.dismiss() }
        overlayView.onHoverChanged = { [weak self] hovering in
            // Don't auto-dismiss while the user is pointing at it
            if hovering { self?.cancelDismissTimer() } else { self?.scheduleDismiss() }
        }
        contentView = overlayView
    }

    func show() {
        // Slide in from the edge
        let target = frame.origin
        setFrameOrigin(NSPoint(x: target.x + 40 * slideDirection, y: target.y))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            animator().setFrameOrigin(target)
            animator().alphaValue = 1
        }
        scheduleDismiss()
    }

    // Only if the user turned auto-close on — by default thumbnails stay
    private func scheduleDismiss() {
        cancelDismissTimer()
        guard Preferences.shared.overlayAutoDismissEnabled, !isEditing else { return }
        let delay = Preferences.shared.overlayAutoDismissSeconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func cancelDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        cancelDismissTimer()
        // Slide out toward the edge
        let target = NSPoint(x: frame.minX + 60 * slideDirection, y: frame.minY)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrameOrigin(target)
            animator().alphaValue = 0
        }, completionHandler: {
            self.close()
            self.onDismiss?()
        })
    }

    // MARK: - Actions

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        Toast.show("Copied to clipboard")
        // Hold Option to copy without dismissing
        if !NSEvent.modifierFlags.contains(.option) { dismiss() }
    }

    private func saveToDisk() {
        // Hold Option for "Save As…"
        if NSEvent.modifierFlags.contains(.option) {
            cancelDismissTimer()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = Preferences.shared.generateFilename(for: .png)
            panel.directoryURL = Preferences.shared.saveDirectory
            panel.allowedContentTypes = [.png, .jpeg]
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                ImageExporter.shared.writeImage(image, to: url)
                dismiss()
            } else {
                scheduleDismiss()
            }
            return
        }
        if let url = ImageExporter.shared.exportToSaveDirectory(image) {
            Toast.show("Saved \(url.lastPathComponent)")
        }
        dismiss()
    }

    private func pinAsFloat() {
        floatingPanelManager?.pinImage(image, from: pinFrame.isEmpty ? frame : pinFrame)
        dismiss()
    }

    /// Hides the thumbnail while editing; Done updates it in place, and closing
    /// the editor without Done brings back the original.
    private func openEditor() {
        guard !isEditing else { return }
        isEditing = true
        cancelDismissTimer()
        orderOut(nil)

        let editor = AnnotationEditorWindowController(image: image)
        editor.onSave = { [weak self] annotated in
            guard let self = self else { return }
            self.image = annotated
            self.overlayView.updateImage(annotated)
            // A crop changes the shape — resize the card and restack
            self.setContentSize(OverlayContentView.size(for: annotated.size))
            QuickAccessOverlay.layout(animated: false)
            // Crops change the size, so it no longer lines up with where it was captured
            self.pinFrame = .zero
        }
        editor.onClose = { [weak self] in
            guard let self = self, !self.isDismissing else { return }
            self.isEditing = false
            self.show()
        }
        editor.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Overlay Content View
// The card is just the screenshot. Hovering dims it and reveals Copy / Save in
// the middle with close, edit and pin in the corners.
final class OverlayContentView: NSView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onDragCompleted: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var image: NSImage
    private var imageView: NSImageView!
    private var controls: NSView!
    private var mouseDownEvent: NSEvent?

    private static let maxSize = CGSize(width: 240, height: 170)
    private static let minSize = CGSize(width: 150, height: 96)

    /// Card size: the image's aspect ratio, fit inside 240×170, never so small the buttons don't fit.
    static func size(for imageSize: CGSize) -> CGSize {
        let scale = min(maxSize.width / max(imageSize.width, 1), maxSize.height / max(imageSize.height, 1))
        return CGSize(width: max(minSize.width, (imageSize.width * scale).rounded()),
                      height: max(minSize.height, (imageSize.height * scale).rounded()))
    }

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        setupUI()
    }

    required init?(coder: NSCoder) { nil }

    func updateImage(_ newImage: NSImage) {
        image = newImage
        imageView.image = newImage
    }

    private func setupUI() {
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor

        imageView = NSImageView(frame: bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        // Hover layer: dim + buttons, hidden until the pointer is over the card
        controls = NSView(frame: bounds)
        controls.autoresizingMask = [.width, .height]
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        controls.alphaValue = 0
        addSubview(controls)

        let copy = pillButton("Copy", #selector(didCopy))
        let save = pillButton("Save", #selector(didSave))
        let center = NSStackView(views: [copy, save])
        center.orientation = .vertical
        center.spacing = 6
        center.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(center)

        let close = cornerButton("xmark", "Close", #selector(didDismiss))
        let edit  = cornerButton("pencil", "Annotate", #selector(didEdit))
        let pin   = cornerButton("pin.fill", "Pin to screen", #selector(didPin))
        [close, edit, pin].forEach { controls.addSubview($0) }

        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            close.topAnchor.constraint(equalTo: controls.topAnchor, constant: 6),
            close.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 6),
            edit.topAnchor.constraint(equalTo: controls.topAnchor, constant: 6),
            edit.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -6),
            pin.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -6),
            pin.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -6)
        ])
    }

    private func pillButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor
        button.layer?.cornerRadius = 13
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(white: 0.1, alpha: 1)
        ])
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 84),
            button.heightAnchor.constraint(equalToConstant: 26)
        ])
        return button
    }

    private func cornerButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = tip
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        button.layer?.cornerRadius = 11
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent)  { setHover(false) }

    private func setHover(_ hovering: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            controls.animator().alphaValue = hovering ? 1 : 0
        }
        onHoverChanged?(hovering)
    }

    @objc private func didCopy()    { onCopy?() }
    @objc private func didSave()    { onSave?() }
    @objc private func didPin()     { onPin?() }
    @objc private func didEdit()    { onEdit?() }
    @objc private func didDismiss() { onDismiss?() }

    // MARK: - Click to edit / drag out to apps

    // Anything that isn't a button belongs to the card itself
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : (hit == nil ? nil : self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        if hypot(dx, dy) > 4 {
            mouseDownEvent = nil
            beginDrag(event: down)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // A click without dragging opens the editor
        if mouseDownEvent != nil { onEdit?() }
        mouseDownEvent = nil
    }

    private func beginDrag(event: NSEvent) {
        // Apps like Slack, Mail and Finder want a file, so hand them a temp PNG
        // (wiped on quit); fall back to raw image data
        let writer: NSPasteboardWriting = ImageExporter.shared.temporaryFile(for: image).map { $0 as NSURL } ?? image
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

extension OverlayContentView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        if !operation.isEmpty { onDragCompleted?() }
    }
}
