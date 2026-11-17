import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Floating Panel (Pinned Screenshot)
final class FloatingPanel: NSPanel {
    let panelID = UUID()
    var onClose: ((FloatingPanel) -> Void)?
    var onEdit: ((FloatingPanel) -> Void)?

    private(set) var image: NSImage
    private(set) var isClickThrough = false
    private var imageView: DraggableImageView!
    private var lockMenuItem: NSMenuItem!
    private var isClosing = false

    init(image: NSImage, sourceFrame: NSRect) {
        self.image = image
        let size = FloatingPanel.initialSize(for: image.size, sourceFrame: sourceFrame)
        // Keep the top-left corner where the source was
        let origin = NSPoint(x: sourceFrame.minX, y: sourceFrame.maxY - size.height)

        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = Preferences.shared.floatingWindowAlwaysOnTop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
            : .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        alphaValue = CGFloat(Preferences.shared.floatingWindowDefaultOpacity)

        setupContent()
    }

    private static func initialSize(for imageSize: CGSize, sourceFrame: CGRect) -> CGSize {
        // Pinning an area capture keeps it pixel-for-pixel where it was taken
        if abs(sourceFrame.width - imageSize.width) < 1 && abs(sourceFrame.height - imageSize.height) < 1 {
            return imageSize
        }
        // Otherwise start at 1:1, scaled down to fit 600pt
        let scale = min(1, 600 / max(imageSize.width, imageSize.height, 1))
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func setupContent() {
        // Container view with rounded corners and subtle border
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(white: 0.5, alpha: 0.4).cgColor
        container.autoresizingMask = [.width, .height]
        contentView = container

        imageView = DraggableImageView(frame: container.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.onDoubleClick = { [weak self] in self?.openEditor() }
        container.addSubview(imageView)

        setupContextMenu()
    }

    // MARK: - Context Menu

    private func setupContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Edit…", action: #selector(openEditor), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copyImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Save…", action: #selector(saveImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        lockMenuItem = NSMenuItem(title: "Lock (Click-through)", action: #selector(toggleLock), keyEquivalent: "")
        menu.addItem(lockMenuItem)
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            opacityMenu.addItem(item)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Close", action: #selector(closePanel), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        imageView.menu = menu
    }

    @objc func openEditor() {
        onEdit?(self)
    }

    @objc func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    // ⌘C while the pin is focused
    @objc func copy(_ sender: Any?) {
        copyImage()
    }

    @objc func saveImage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Preferences.shared.generateFilename(for: .png)
        panel.directoryURL = Preferences.shared.saveDirectory
        panel.allowedContentTypes = [.png, .jpeg]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            ImageExporter.shared.writeImage(self.image, to: url)
        }
    }

    @objc func toggleLock() {
        setLocked(!isClickThrough)
    }

    // Unlocking is done from the menu bar, since a locked pin can't receive clicks
    func setLocked(_ locked: Bool) {
        isClickThrough = locked
        ignoresMouseEvents = locked
        alphaValue = locked ? 0.5 : CGFloat(Preferences.shared.floatingWindowDefaultOpacity)
        lockMenuItem.state = locked ? .on : .off
        if locked { resignKey() }
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        alphaValue = CGFloat(sender.tag) / 100
    }

    @objc func closePanel() {
        guard !isClosing else { return }
        isClosing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.onClose?(self)
            self.close()
        })
    }

    // ⌘W — borderless windows have no close button, so performClose would just beep
    override func performClose(_ sender: Any?) {
        closePanel()
    }

    // Middle-click to close
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { closePanel() } else { super.otherMouseDown(with: event) }
    }

    // MARK: - Scroll to adjust opacity
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.005 : 0.05)
        alphaValue = (alphaValue - CGFloat(delta)).clamped(to: 0.2...1.0)
    }

    // MARK: - Arrow key nudging
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var origin = frame.origin
        switch event.keyCode {
        case 123: origin.x -= step  // left
        case 124: origin.x += step  // right
        case 125: origin.y -= step  // down
        case 126: origin.y += step  // up
        case 53:  closePanel(); return  // Esc
        default: super.keyDown(with: event); return
        }
        setFrameOrigin(origin)
    }

    // MARK: - Update image (after editing)
    func updateImage(_ newImage: NSImage) {
        let oldAspect = image.size.width / max(image.size.height, 1)
        let newAspect = newImage.size.width / max(newImage.size.height, 1)
        self.image = newImage
        imageView.image = newImage
        // A crop changes the aspect ratio — reshape the window, keeping width and top-left
        if abs(oldAspect - newAspect) > 0.01 {
            let height = frame.width / newAspect
            setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
        }
    }

    override var canBecomeKey: Bool { !isClickThrough }
    override var canBecomeMain: Bool { false }
}

// MARK: - Draggable Image View
// Drag moves the window, ⌥-drag drags the image out to other apps,
// bottom-right corner resizes (⇧ for free aspect), double-click edits.
final class DraggableImageView: NSImageView {
    var onDoubleClick: (() -> Void)?
    private var dragOutPending = false
    private let resizeHandleSize: CGFloat = 18

    private var resizeHandleRect: NSRect {
        NSRect(x: bounds.maxX - resizeHandleSize, y: bounds.minY, width: resizeHandleSize, height: resizeHandleSize)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.makeKey()
        let loc = convert(event.locationInWindow, from: nil)
        if resizeHandleRect.contains(loc) {
            trackResize(from: event)
        } else if event.modifierFlags.contains(.option) {
            dragOutPending = true
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragOutPending, let img = image else { return }
        dragOutPending = false
        let item = NSDraggingItem(pasteboardWriter: img)
        item.setDraggingFrame(bounds, contents: img)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOutPending = false
    }

    private func trackResize(from event: NSEvent) {
        guard let window = window else { return }
        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        let aspect = startFrame.width / max(startFrame.height, 1)

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              next.type != .leftMouseUp {
            let mouse = NSEvent.mouseLocation
            let width = max(80, startFrame.width + (mouse.x - startMouse.x))
            let height = next.modifierFlags.contains(.shift)
                ? max(60, startFrame.height - (mouse.y - startMouse.y))
                : width / aspect
            // Top-left stays put
            window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height),
                            display: true)
        }
    }

    // Small grip so the resize corner is discoverable
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let r = resizeHandleRect.insetBy(dx: 4, dy: 4)
        let grip = NSBezierPath()
        for i in 0..<3 {
            let o = CGFloat(i) * 4
            grip.move(to: NSPoint(x: r.maxX - 10 + o, y: r.minY))
            grip.line(to: NSPoint(x: r.maxX, y: r.minY + 10 - o))
        }
        grip.lineWidth = 1
        NSColor(white: 1, alpha: 0.6).setStroke()
        grip.stroke()
    }
}

extension DraggableImageView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : []
    }
}

// MARK: - CGFloat clamped helper
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
