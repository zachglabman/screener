import AppKit
import CoreGraphics

// MARK: - Selection Overlay Window (one per display)
final class SelectionOverlayWindow: NSWindow {
    var onSelection: ((CGRect, CGWindowID?) -> Void)?
    var onCancel: (() -> Void)?
    var onToggleWindowMode: (() -> Void)?
    private var overlayView: SelectionOverlayView!

    init(captureMode: CaptureMode, screen: NSScreen, windows: [WindowInfo]) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isMovable = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        overlayView = SelectionOverlayView(captureMode: captureMode, screenFrame: screen.frame, windows: windows)
        overlayView.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.onSelection = { [weak self] rect, windowID in
            self?.onSelection?(rect, windowID)
        }
        overlayView.onCancel = { [weak self] in
            self?.onCancel?()
        }
        overlayView.onToggleWindowMode = { [weak self] in
            self?.onToggleWindowMode?()
        }
        contentView = overlayView
        setFrame(screen.frame, display: false)
    }

    /// The selected region cropped from the frozen snapshot (freeze mode only).
    func frozenImage(in screenRect: CGRect) -> NSImage? {
        overlayView.snapshotImage(in: convertFromScreen(screenRect))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay View
// Area: crosshair cursor + coordinates, then a dimmed surround with a
// size readout while dragging. Window: blue tint over the hovered window.
final class SelectionOverlayView: NSView {
    var onSelection: ((CGRect, CGWindowID?) -> Void)?
    var onCancel: (() -> Void)?
    var onToggleWindowMode: (() -> Void)?
    private let captureMode: CaptureMode

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var isSelecting = false
    private var hoveredWindowInfo: WindowInfo?
    private let windowList: [WindowInfo]

    // Cursor + snapshot (for the loupe and freeze mode)
    private var cursorPoint: NSPoint?
    private var screenSnapshot: CGImage?

    private let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    init(captureMode: CaptureMode, screenFrame: CGRect, windows: [WindowInfo]) {
        self.captureMode = captureMode
        self.windowList = windows
        super.init(frame: .zero)
        wantsLayer = true

        if captureMode == .freeze || (captureMode != .window && Preferences.shared.showMagnifier) {
            // Snapshot of this display, taken before the overlay is visible. Feeds the
            // loupe, and in freeze mode it's what gets drawn and captured.
            screenSnapshot = CGWindowListCreateImage(CaptureManager.flip(screenFrame),
                                                     .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
        }

        // Start with the coordinate readout under the cursor if it's on this screen
        let mouse = NSEvent.mouseLocation
        if screenFrame.contains(mouse) {
            cursorPoint = NSPoint(x: mouse.x - screenFrame.minX, y: mouse.y - screenFrame.minY)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: captureMode == .window ? .pointingHand : .crosshair)
    }

    // MARK: - Drawing

    private var isFrozen: Bool { captureMode == .freeze && screenSnapshot != nil }

    override func draw(_ dirtyRect: NSRect) {
        // Frozen screen underneath everything
        if isFrozen, let snapshot = screenSnapshot {
            NSGraphicsContext.current?.cgContext.draw(snapshot, in: bounds)
        }

        if captureMode == .window {
            drawWindowHighlight()
        } else {
            drawAreaSelection()
        }

        drawHint()
    }

    private func drawAreaSelection() {
        if isSelecting, let start = startPoint, let current = currentPoint {
            let selectionRect = rectFrom(start: start, end: current)

            // Dim only outside the selection
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: selectionRect))
            dim.windingRule = .evenOdd
            NSColor(white: 0, alpha: 0.4).setFill()
            dim.fill()

            // Hairline border
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()

            // Size readout just past the cursor
            drawPill("\(Int(selectionRect.width)) × \(Int(selectionRect.height))", near: current)
        } else {
            // A light tint so frozen mode reads as frozen
            if isFrozen {
                NSColor(white: 0, alpha: 0.12).setFill()
                bounds.fill()
            }
            if let point = cursorPoint {
                drawPill("\(Int(point.x)), \(Int(bounds.height - point.y))", near: point)
            }
        }

        if Preferences.shared.showMagnifier, let point = cursorPoint {
            drawMagnifier(at: point)
        }
    }

    private func drawWindowHighlight() {
        NSColor(white: 0, alpha: 0.2).setFill()
        bounds.fill()

        guard let info = hoveredWindowInfo, let window = window else { return }
        let viewFrame = window.convertFromScreen(info.frame)
        let shape = NSBezierPath(roundedRect: viewFrame, xRadius: 10, yRadius: 10)

        // Punch out the dim, then tint the window blue
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.systemBlue.withAlphaComponent(0.22).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.systemBlue.setStroke()
        shape.lineWidth = 2
        shape.stroke()

        // App name + size, centered
        let label = "\(info.appName)  \(Int(info.frame.width)) × \(Int(info.frame.height))"
        drawPill(label, centeredIn: viewFrame)
    }

    private func drawMagnifier(at point: NSPoint) {
        let size: CGFloat = 120
        let zoom: CGFloat = 6
        let gap: CGFloat  = 28

        // Offset so it doesn't cover the cursor; flip sides near screen edges
        var magRect = NSRect(x: point.x + gap, y: point.y - size - gap, width: size, height: size)
        if magRect.maxX > bounds.maxX { magRect.origin.x = point.x - size - gap }
        if magRect.minY < bounds.minY { magRect.origin.y = point.y + gap }

        let clipPath = NSBezierPath(ovalIn: magRect)
        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()
        NSColor.black.setFill()
        clipPath.fill()

        // Zoomed region of the snapshot (top-left origin, pixels)
        if let snapshot = screenSnapshot, let ctx = NSGraphicsContext.current?.cgContext {
            let scale = CGFloat(snapshot.width) / bounds.width
            let source = size / zoom
            let cropRect = CGRect(
                x: (point.x - source/2) * scale,
                y: (bounds.height - point.y - source/2) * scale,
                width: source * scale,
                height: source * scale
            ).integral
            if let region = snapshot.cropping(to: cropRect) {
                ctx.interpolationQuality = .none
                ctx.draw(region, in: magRect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setStroke()
        clipPath.lineWidth = 2
        clipPath.stroke()
    }

    /// Short instruction for the modes that need one.
    private func drawHint() {
        let text: String
        switch captureMode {
        case .freeze: text = "Screen frozen — drag to capture"
        case .ocr:    text = "Drag over text to copy it"
        case .window: text = "Click a window  •  Space for area"
        default:      return
        }
        guard !isSelecting else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attrs)
        let bg = NSRect(x: bounds.midX - textSize.width / 2 - 14, y: bounds.maxY - 72,
                        width: textSize.width + 28, height: textSize.height + 14)
        NSColor(white: 0.08, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: bg, xRadius: bg.height / 2, yRadius: bg.height / 2).fill()
        text.draw(at: NSPoint(x: bg.minX + 14, y: bg.minY + 7), withAttributes: attrs)
    }

    // MARK: - Pills

    private func pillRect(for text: String) -> (NSRect, [NSAttributedString.Key: Any]) {
        let attrs: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        return (NSRect(x: 0, y: 0, width: size.width + 14, height: size.height + 6), attrs)
    }

    private func drawPill(_ text: String, in rect: NSRect, attrs: [NSAttributedString.Key: Any]) {
        NSColor(white: 0.08, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: rect.minX + 7, y: rect.minY + 3), withAttributes: attrs)
    }

    /// Below-right of the point, flipped to stay on screen.
    private func drawPill(_ text: String, near point: NSPoint) {
        var (rect, attrs) = pillRect(for: text)
        rect.origin = NSPoint(x: point.x + 14, y: point.y - rect.height - 14)
        if rect.maxX > bounds.maxX - 4 { rect.origin.x = point.x - rect.width - 14 }
        if rect.minY < bounds.minY + 4 { rect.origin.y = point.y + 14 }
        drawPill(text, in: rect, attrs: attrs)
    }

    private func drawPill(_ text: String, centeredIn frame: NSRect) {
        var (rect, attrs) = pillRect(for: text)
        rect.origin = NSPoint(x: frame.midX - rect.width / 2, y: frame.midY - rect.height / 2)
        drawPill(text, in: rect, attrs: attrs)
    }

    // MARK: - Mouse Events

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let loc = convert(event.locationInWindow, from: nil)
        if captureMode == .window {
            // Find which window was clicked (list is front-to-back)
            let screenPoint = convertToScreen(loc)
            if let info = windowList.first(where: { $0.frame.contains(screenPoint) }) {
                onSelection?(info.frame, info.windowID)
            } else {
                onCancel?()
            }
            return
        }
        startPoint = loc
        currentPoint = loc
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        currentPoint = loc
        cursorPoint = loc
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelecting, let start = startPoint, let current = currentPoint else { return }
        isSelecting = false
        let selectionRect = rectFrom(start: start, end: current).intersection(bounds)
        if selectionRect.width < 5 || selectionRect.height < 5 {
            needsDisplay = true // a stray click just resets, like CleanShot
            return
        }
        guard let window = window else { return }
        onSelection?(window.convertToScreen(selectionRect), nil)
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if captureMode == .window {
            let screenPoint = convertToScreen(loc)
            let newHovered = windowList.first { $0.frame.contains(screenPoint) }
            if newHovered?.windowID != hoveredWindowInfo?.windowID {
                hoveredWindowInfo = newHovered
                needsDisplay = true
            }
        } else {
            cursorPoint = loc
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        // Cursor moved to another display — drop the readout here
        cursorPoint = nil
        hoveredWindowInfo = nil
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onCancel?()
        case 49 where !isSelecting && (captureMode == .area || captureMode == .window): // Space
            onToggleWindowMode?()
        default:
            break
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Helpers

    /// Crops the snapshot to a rect in view coordinates.
    func snapshotImage(in viewRect: CGRect) -> NSImage? {
        guard let snapshot = screenSnapshot else { return nil }
        let scale = CGFloat(snapshot.width) / bounds.width
        // CGImage cropping uses a top-left origin in pixels
        let pixelRect = CGRect(x: viewRect.minX * scale, y: (bounds.height - viewRect.maxY) * scale,
                               width: viewRect.width * scale, height: viewRect.height * scale).integral
        guard let cropped = snapshot.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped, size: CGSize(width: CGFloat(cropped.width) / scale,
                                                       height: CGFloat(cropped.height) / scale))
    }

    private func rectFrom(start: NSPoint, end: NSPoint) -> NSRect {
        NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func convertToScreen(_ viewPoint: NSPoint) -> NSPoint {
        guard let window = window else { return viewPoint }
        let windowPoint = convert(viewPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }
}
