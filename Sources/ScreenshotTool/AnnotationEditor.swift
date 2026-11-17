import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - Editor Window Controller
final class AnnotationEditorWindowController: NSWindowController, NSWindowDelegate {
    /// Called with the flattened image when the user clicks Done.
    var onSave: ((NSImage) -> Void)?
    /// Called whenever the window closes, after Done or not.
    var onClose: (() -> Void)?

    // Callers don't hold on to editors, so keep each one alive until its window closes
    private static var openEditors: [AnnotationEditorWindowController] = []

    private let canvas: AnnotationCanvasView
    private var toolControl: NSSegmentedControl!
    private var colorWell: NSColorWell!
    private var swatches: [ColorSwatchButton] = []
    private let toolbarHeight: CGFloat = 52
    private let lineWidths: [(String, CGFloat)] = [("Thin", 2), ("Medium", 3), ("Thick", 5), ("Heavy", 8)]
    private let presetColors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .black, .white]
    private static let minWidth: CGFloat = 900

    init(image: NSImage) {
        canvas = AnnotationCanvasView(image: image)

        // Size the window to the image, capped at 80% of the screen
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxCanvas = NSSize(width: visible.width * 0.8, height: visible.height * 0.8 - toolbarHeight)
        let scale = min(1, maxCanvas.width / image.size.width, maxCanvas.height / image.size.height)
        let contentSize = NSSize(
            width: max(image.size.width * scale + 64, Self.minWidth),
            height: max(image.size.height * scale + 64, 260) + toolbarHeight
        )

        // Toolbar lives in the title bar, next to the traffic lights
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Annotate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title bar 52pt tall so the traffic
        // lights line up with our controls
        window.toolbar = NSToolbar(identifier: "AnnotationEditor")
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: Self.minWidth, height: 320)
        super.init(window: window)
        window.delegate = self

        setupContent()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        if !Self.openEditors.contains(where: { $0 === self }) {
            Self.openEditors.append(self)
        }
        super.showWindow(sender)
        window?.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        colorWell.deactivate()
        onClose?()
        Self.openEditors.removeAll { $0 === self }
    }

    // MARK: - Layout

    private func setupContent() {
        guard let contentView = window?.contentView else { return }
        let bounds = contentView.bounds

        // Title bar strip with a translucent background, holding all controls
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: bounds.height - toolbarHeight,
                                                   width: bounds.width, height: toolbarHeight))
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.autoresizingMask = [.width, .minYMargin]

        let toolbar = NSStackView(frame: bar.bounds)
        toolbar.autoresizingMask = [.width, .height]
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        // Leave room for the traffic lights
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 84, bottom: 0, right: 12)

        // Tools
        let tools = AnnotationToolType.allCases
        toolControl = NSSegmentedControl(labels: tools.map { _ in "" }, trackingMode: .selectOne,
                                         target: self, action: #selector(toolChanged(_:)))
        toolControl.segmentStyle = .separated
        let toolSymbol = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        for (i, tool) in tools.enumerated() {
            if let img = NSImage(systemSymbolName: tool.systemImage, accessibilityDescription: tool.rawValue)?
                .withSymbolConfiguration(toolSymbol) {
                toolControl.setImage(img, forSegment: i)
            } else {
                toolControl.setLabel(String(tool.rawValue.prefix(2)), forSegment: i)
            }
            toolControl.setWidth(30, forSegment: i)
            toolControl.setToolTip("\(tool.rawValue) (\(tool.keyEquivalent.uppercased()))", forSegment: i)
        }
        toolControl.selectedSegment = tools.firstIndex(of: canvas.tool) ?? 0
        canvas.onToolChange = { [weak self] tool in
            self?.toolControl.selectedSegment = AnnotationToolType.allCases.firstIndex(of: tool) ?? 0
        }

        // Color: preset swatches + a well for anything else
        let colorStack = NSStackView()
        colorStack.spacing = 5
        for color in presetColors {
            let swatch = ColorSwatchButton(color: color, target: self, action: #selector(swatchClicked(_:)))
            swatches.append(swatch)
            colorStack.addArrangedSubview(swatch)
        }
        colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 26, height: 20))
        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Custom color"
        colorWell.widthAnchor.constraint(equalToConstant: 26).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 20).isActive = true
        colorStack.addArrangedSubview(colorWell)
        updateSwatchSelection()

        // Line width as dots of increasing size
        let widthControl = NSSegmentedControl(labels: lineWidths.map { _ in "" }, trackingMode: .selectOne,
                                              target: self, action: #selector(widthChanged(_:)))
        widthControl.segmentStyle = .separated
        for (i, (name, _)) in lineWidths.enumerated() {
            let dot = NSImage.SymbolConfiguration(pointSize: CGFloat(5 + i * 3), weight: .regular)
            widthControl.setImage(NSImage(systemSymbolName: "circle.fill", accessibilityDescription: name)?
                .withSymbolConfiguration(dot), forSegment: i)
            widthControl.setWidth(26, forSegment: i)
            widthControl.setToolTip(name, forSegment: i)
        }
        widthControl.selectedSegment = lineWidths.firstIndex { $0.1 == canvas.lineWidth } ?? 1

        // Undo / redo
        let undoButton = iconButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(undoClicked))
        let redoButton = iconButton("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redoClicked))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Output
        let copyButton = iconButton("doc.on.doc", "Copy (⌘C)", #selector(copy(_:)))
        let saveButton = iconButton("square.and.arrow.down", "Save As… (⌘S)", #selector(saveDocument(_:)))
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        [toolControl, divider(), colorStack, divider(), widthControl, divider(), undoButton, redoButton,
         spacer, copyButton, saveButton, doneButton]
            .forEach { toolbar.addArrangedSubview($0) }
        bar.addSubview(toolbar)

        canvas.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - toolbarHeight)
        canvas.autoresizingMask = [.width, .height]
        contentView.addSubview(canvas)
        contentView.addSubview(bar)
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }

    private func updateSwatchSelection() {
        for swatch in swatches {
            swatch.isSelected = swatch.color.usingColorSpace(.sRGB) == canvas.color.usingColorSpace(.sRGB)
        }
    }

    // MARK: - Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        canvas.tool = AnnotationToolType.allCases[sender.selectedSegment]
        window?.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        setColor(sender.color)
    }

    @objc private func swatchClicked(_ sender: ColorSwatchButton) {
        colorWell.color = sender.color
        setColor(sender.color)
    }

    private func setColor(_ color: NSColor) {
        canvas.color = color
        Preferences.shared.annotationColor = color
        updateSwatchSelection()
        window?.makeFirstResponder(canvas)
    }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        canvas.lineWidth = lineWidths[sender.selectedSegment].1
        Preferences.shared.annotationLineWidth = canvas.lineWidth
        window?.makeFirstResponder(canvas)
    }

    @objc private func undoClicked() { canvas.undo(nil) }
    @objc private func redoClicked() { canvas.redo(nil) }

    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([canvas.renderedImage()])
    }

    // ⌘S
    @objc func saveDocument(_ sender: Any?) {
        guard let window = window else { return }
        let image = canvas.renderedImage()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Preferences.shared.generateFilename(for: .png)
        panel.directoryURL = Preferences.shared.saveDirectory
        panel.allowedContentTypes = [.png, .jpeg]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            ImageExporter.shared.writeImage(image, to: url)
        }
    }

    @objc private func done(_ sender: Any?) {
        onSave?(canvas.renderedImage())
        close()
    }
}

// MARK: - Color Swatch
final class ColorSwatchButton: NSButton {
    let color: NSColor
    var isSelected = false { didSet { needsDisplay = true } }

    init(color: NSColor, target: AnyObject, action: Selector) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        toolTip = color.accessibilityName.capitalized
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        color.setFill()
        dot.fill()
        // Thin outline so white/black stay visible on any background
        NSColor(white: 0.5, alpha: 0.5).setStroke()
        dot.lineWidth = 0.5
        dot.stroke()
        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}

// MARK: - Canvas
// Annotations are stored as vector objects in image coordinates (points, bottom-left
// origin) and only flattened on export.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    var tool: AnnotationToolType = .arrow {
        didSet {
            commitText()
            selected = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            onToolChange?(tool)
        }
    }
    var color: NSColor = Preferences.shared.annotationColor
    var lineWidth: CGFloat = Preferences.shared.annotationLineWidth
    var onToolChange: ((AnnotationToolType) -> Void)?

    private struct EditorState {
        let annotations: [AnnotationObject]
        let cropRect: CGRect?
    }

    private let image: NSImage
    private let baseImage: CGImage?
    private lazy var pixelatedImage: CGImage? = makePixelatedImage()

    private var annotations: [AnnotationObject] = []
    private var cropRect: CGRect?
    private var cropPreview: CGRect?
    private var cropDragStart: CGPoint?
    private var current: AnnotationObject?
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []

    // Moving existing annotations
    private var selected: AnnotationObject?
    private var moving: AnnotationObject?
    private var moveLastPoint: CGPoint = .zero
    private var moveStarted = false

    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var textColor: NSColor = .systemRed
    private var textLineWidth: CGFloat = 3
    private var textUndoPushed = false

    init(image: NSImage) {
        self.image = image
        self.baseImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(imageFrame, cursor: tool.cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // Open hand over anything that can be dragged
    override func mouseMoved(with event: NSEvent) {
        guard textField == nil, tool != .crop else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard imageFrame.contains(viewPoint) else { return }
        (annotation(at: toImage(viewPoint)) != nil ? NSCursor.openHand : tool.cursor).set()
    }

    // MARK: - Geometry

    /// Where the image sits in the view: aspect-fit, never upscaled.
    private var imageFrame: CGRect {
        let area = bounds.insetBy(dx: 32, dy: 32)
        let s = min(1, area.width / image.size.width, area.height / image.size.height)
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private var viewScale: CGFloat { imageFrame.width / image.size.width }

    private func toImage(_ viewPoint: CGPoint) -> CGPoint {
        let f = imageFrame
        let s = viewScale
        return CGPoint(x: ((viewPoint.x - f.minX) / s).clamped(to: 0...image.size.width),
                       y: ((viewPoint.y - f.minY) / s).clamped(to: 0...image.size.height))
    }

    private func toView(_ imageRect: CGRect) -> CGRect {
        let f = imageFrame
        let s = viewScale
        return CGRect(x: f.minX + imageRect.minX * s, y: f.minY + imageRect.minY * s,
                      width: imageRect.width * s, height: imageRect.height * s)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let f = imageFrame
        // Soft drop shadow so the screenshot reads as a card
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: NSColor(white: 0, alpha: 0.35).cgColor)
        NSColor.white.setFill()
        f.fill()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: f.minX, y: f.minY)
        ctx.scaleBy(x: viewScale, y: viewScale)
        renderContent(in: ctx)
        ctx.restoreGState()

        // Dashed outline around the selected annotation (on screen only, never exported)
        if let s = selected, annotations.contains(where: { $0 === s }) {
            let outline = NSBezierPath(roundedRect: toView(frame(of: s)).insetBy(dx: -4, dy: -4), xRadius: 3, yRadius: 3)
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.lineWidth = 1
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }

        // Dim everything outside the crop
        if let crop = cropPreview ?? cropRect {
            let cropView = toView(crop)
            let dim = NSBezierPath(rect: f)
            dim.append(NSBezierPath(rect: cropView))
            dim.windingRule = .evenOdd
            NSColor(white: 0, alpha: 0.55).setFill()
            dim.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: cropView.insetBy(dx: 0.5, dy: 0.5))
            border.setLineDash([4, 3], count: 2, phase: 0)
            border.stroke()
        }
    }

    /// Draws the image and all annotations in image coordinates.
    /// Expects `NSGraphicsContext.current` to wrap `ctx` (needed for text).
    private func renderContent(in ctx: CGContext) {
        let imageRect = CGRect(origin: .zero, size: image.size)
        if let base = baseImage {
            ctx.draw(base, in: imageRect)
        } else {
            image.draw(in: imageRect)
        }

        var all = annotations
        if let current = current { all.append(current) }

        // Blurs first so they only obscure the screenshot, not other annotations
        for a in all where a.tool == .blur { drawAnnotation(a, in: ctx) }
        for a in all where a.tool != .blur { drawAnnotation(a, in: ctx) }
    }

    private func drawAnnotation(_ a: AnnotationObject, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.tool {
        case .arrow:
            drawArrow(from: a.startPoint, to: a.endPoint, width: a.lineWidth, in: ctx)
        case .rectangle:
            ctx.stroke(a.boundingRect)
        case .filled:
            ctx.fill(a.boundingRect)
        case .ellipse:
            ctx.strokeEllipse(in: a.boundingRect)
        case .line:
            ctx.move(to: a.startPoint)
            ctx.addLine(to: a.endPoint)
            ctx.strokePath()
        case .pencil, .highlighter:
            guard let first = a.path.first else { return }
            if a.tool == .highlighter {
                ctx.setStrokeColor(a.color.withAlphaComponent(0.35).cgColor)
                ctx.setLineWidth(a.lineWidth * 5)
                ctx.setLineCap(.butt)
                ctx.setBlendMode(.multiply)
            }
            ctx.move(to: first)
            a.path.dropFirst().forEach { ctx.addLine(to: $0) }
            ctx.strokePath()
        case .text:
            (a.text as NSString).draw(at: a.startPoint, withAttributes: textAttributes(color: a.color, lineWidth: a.lineWidth))
        case .blur:
            guard let pixelated = pixelatedImage else { return }
            ctx.clip(to: a.boundingRect)
            ctx.draw(pixelated, in: CGRect(origin: .zero, size: image.size))
        case .crop:
            break
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, in ctx: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(14, width * 4)
        let headAngle = CGFloat.pi / 7
        // Stop the shaft inside the head so the tip stays sharp
        let shaftEnd = CGPoint(x: end.x - cos(angle) * headLength * 0.7,
                               y: end.y - sin(angle) * headLength * 0.7)
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: end.x - headLength * cos(angle - headAngle),
                                y: end.y - headLength * sin(angle - headAngle)))
        ctx.addLine(to: CGPoint(x: end.x - headLength * cos(angle + headAngle),
                                y: end.y - headLength * sin(angle + headAngle)))
        ctx.closePath()
        ctx.fillPath()
    }

    private func textAttributes(color: NSColor, lineWidth: CGFloat, scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        return [
            .font: NSFont.systemFont(ofSize: lineWidth * 6 * scale, weight: .bold),
            .foregroundColor: color,
            .shadow: shadow
        ]
    }

    private func makePixelatedImage() -> CGImage? {
        guard let base = baseImage, let filter = CIFilter(name: "CIPixellate") else { return nil }
        let input = CIImage(cgImage: base)
        let pixelScale = CGFloat(base.width) / image.size.width
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(12 * pixelScale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    // MARK: - Hit Testing

    /// Area an annotation covers, in image coordinates.
    private func frame(of a: AnnotationObject) -> CGRect {
        switch a.tool {
        case .text:
            let size = (a.text as NSString).size(withAttributes: textAttributes(color: a.color, lineWidth: a.lineWidth))
            return CGRect(origin: a.startPoint, size: size)
        case .pencil, .highlighter:
            let xs = a.path.map(\.x), ys = a.path.map(\.y)
            let pad = (a.tool == .highlighter ? a.lineWidth * 5 : a.lineWidth) / 2
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
                .insetBy(dx: -pad, dy: -pad)
        default:
            return a.boundingRect.insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        }
    }

    /// Topmost annotation under the point. Outlines and lines are hit near their
    /// stroke; text, filled shapes and blurs anywhere inside.
    private func annotation(at p: CGPoint) -> AnnotationObject? {
        let tolerance = 6 / viewScale
        return annotations.reversed().first { a in
            let slop = tolerance + a.lineWidth / 2
            switch a.tool {
            case .text, .filled, .blur:
                return frame(of: a).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
            case .rectangle, .ellipse:
                let r = a.boundingRect
                return r.insetBy(dx: -slop, dy: -slop).contains(p) && !r.insetBy(dx: slop, dy: slop).contains(p)
            case .arrow, .line:
                return distance(from: p, toSegment: a.startPoint, a.endPoint) <= slop
            case .pencil, .highlighter:
                let reach = a.tool == .highlighter ? a.lineWidth * 2.5 + tolerance : slop
                return zip(a.path, a.path.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= reach }
            case .crop:
                return false
            }
        }
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared).clamped(to: 0...1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Undo snapshots share annotation objects, so a move works on a copy.
    private func duplicate(_ a: AnnotationObject) -> AnnotationObject {
        let copy = AnnotationObject(tool: a.tool, color: a.color, lineWidth: a.lineWidth)
        copy.startPoint = a.startPoint
        copy.endPoint = a.endPoint
        copy.text = a.text
        copy.path = a.path
        copy.blurRadius = a.blurRadius
        copy.opacity = a.opacity
        return copy
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = toImage(viewPoint)

        // Clicking an existing annotation selects it for dragging (any tool but crop);
        // double-clicking text edits it
        if tool != .crop, let hit = annotation(at: p) {
            if event.clickCount == 2, hit.tool == .text {
                pushUndo()
                annotations.removeAll { $0 === hit }
                selected = nil
                beginText(at: hit.startPoint, editing: hit)
            } else {
                selected = hit
                moving = hit
                moveLastPoint = p
                moveStarted = false
                NSCursor.closedHand.set()
            }
            needsDisplay = true
            return
        }
        selected = nil

        switch tool {
        case .text:
            beginText(at: p)
        case .crop:
            cropDragStart = p
            cropPreview = nil
        default:
            let a = AnnotationObject(tool: tool, color: color, lineWidth: lineWidth)
            a.startPoint = p
            a.endPoint = p
            a.path = [p]
            current = a
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        if let target = moving {
            if !moveStarted {
                pushUndo()
                let copy = duplicate(target)
                if let index = annotations.firstIndex(where: { $0 === target }) { annotations[index] = copy }
                moving = copy
                selected = copy
                moveStarted = true
            }
            guard let a = moving else { return }
            let dx = p.x - moveLastPoint.x, dy = p.y - moveLastPoint.y
            a.startPoint = CGPoint(x: a.startPoint.x + dx, y: a.startPoint.y + dy)
            a.endPoint = CGPoint(x: a.endPoint.x + dx, y: a.endPoint.y + dy)
            a.path = a.path.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            moveLastPoint = p
            needsDisplay = true
            return
        }
        if tool == .crop, let start = cropDragStart {
            cropPreview = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                 width: abs(p.x - start.x), height: abs(p.y - start.y))
        } else if let a = current {
            a.endPoint = p
            if a.tool == .pencil || a.tool == .highlighter { a.path.append(p) }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if moving != nil {
            moving = nil
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        if tool == .crop {
            if let preview = cropPreview, preview.width > 4, preview.height > 4 {
                pushUndo()
                cropRect = preview
            }
            cropPreview = nil
            cropDragStart = nil
        } else if let a = current {
            current = nil
            let moved = hypot(a.endPoint.x - a.startPoint.x, a.endPoint.y - a.startPoint.y) > 2
            if moved || a.path.count > 2 {
                pushUndo()
                annotations.append(a)
            }
        }
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let chars = event.charactersIgnoringModifiers?.lowercased(),
           let match = AnnotationToolType.allCases.first(where: { $0.keyEquivalent == chars }) {
            tool = match
            return
        }
        switch event.keyCode {
        case 51, 117: // Delete / Forward Delete removes the selected annotation, or the last one
            guard !annotations.isEmpty else { NSSound.beep(); return }
            pushUndo()
            if let s = selected, let index = annotations.firstIndex(where: { $0 === s }) {
                annotations.remove(at: index)
            } else {
                annotations.removeLast()
            }
            selected = nil
            needsDisplay = true
        case 53: // Esc clears the crop
            if cropRect != nil {
                pushUndo()
                cropRect = nil
                needsDisplay = true
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Text

    /// Pass `editing` to reopen an existing label with its text and style
    /// (its removal has already been pushed to the undo stack).
    private func beginText(at p: CGPoint, editing existing: AnnotationObject? = nil) {
        textColor = existing?.color ?? color
        textLineWidth = existing?.lineWidth ?? lineWidth
        textUndoPushed = existing != nil

        let s = viewScale
        let attrs = textAttributes(color: textColor, lineWidth: textLineWidth, scale: s)
        let font = attrs[.font] as? NSFont ?? NSFont.boldSystemFont(ofSize: 18)
        let origin = toView(CGRect(origin: p, size: .zero)).origin

        let field = NSTextField(frame: NSRect(x: origin.x - 2, y: origin.y - 2,
                                              width: 300, height: font.boundingRectForFont.height + 4))
        field.font = font
        field.textColor = textColor
        field.stringValue = existing?.text ?? ""
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: 1, alpha: 0.25)
        field.focusRingType = .none
        field.placeholderString = "Type, then press Return"
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = p
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }

        let a = AnnotationObject(tool: .text, color: textColor, lineWidth: textLineWidth)
        a.startPoint = textOrigin
        a.text = text
        if !textUndoPushed { pushUndo() }
        annotations.append(a)
        selected = a
        needsDisplay = true
    }

    // MARK: - Undo / Redo

    private var state: EditorState { EditorState(annotations: annotations, cropRect: cropRect) }

    private func pushUndo() {
        undoStack.append(state)
        redoStack.removeAll()
    }

    private func restore(_ s: EditorState) {
        annotations = s.annotations
        cropRect = s.cropRect
        selected = nil
        needsDisplay = true
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        guard let previous = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(state)
        restore(previous)
    }

    @objc func redo(_ sender: Any?) {
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(state)
        restore(next)
    }

    // MARK: - Export

    /// Flattens annotations onto the image at full pixel resolution and applies the crop.
    func renderedImage() -> NSImage {
        commitText()
        guard let base = baseImage else { return image }
        let scale = CGFloat(base.width) / image.size.width
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? srgb
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        renderContent(in: ctx)
        NSGraphicsContext.restoreGraphicsState()

        guard var output = ctx.makeImage() else { return image }
        var size = image.size
        if let crop = cropRect {
            // CGImage cropping uses a top-left origin in pixels
            let pixelCrop = CGRect(x: crop.minX * scale, y: (image.size.height - crop.maxY) * scale,
                                   width: crop.width * scale, height: crop.height * scale).integral
            if let cropped = output.cropping(to: pixelCrop) {
                output = cropped
                size = CGSize(width: CGFloat(cropped.width) / scale, height: CGFloat(cropped.height) / scale)
            }
        }
        return NSImage(cgImage: output, size: size)
    }
}
