import AppKit
import Vision

// MARK: - OCR (on-device, Vision framework)
enum TextRecognizer {
    /// Reads QR/barcodes first, then text. Calls back on the main thread with
    /// nil if nothing was found.
    static func recognize(_ image: NSImage, completion: @escaping (String?) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let barcodes = VNDetectBarcodesRequest()
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            if #available(macOS 13.0, *) {
                text.automaticallyDetectsLanguage = true
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([barcodes, text])

            let result: String?
            let payloads = (barcodes.results ?? []).compactMap { $0.payloadStringValue }
            if !payloads.isEmpty {
                result = payloads.joined(separator: "\n")
            } else {
                result = readingOrder(text.results ?? [])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Joins lines top-to-bottom, left-to-right. Vision's bounding boxes are
    /// normalized with a bottom-left origin.
    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> String? {
        let lines = observations
            .sorted { a, b in
                // Treat boxes whose vertical centers are close as the same line
                if abs(a.boundingBox.midY - b.boundingBox.midY) > min(a.boundingBox.height, b.boundingBox.height) / 2 {
                    return a.boundingBox.midY > b.boundingBox.midY
                }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - Toast
/// Small HUD that confirms an action (e.g. "Copied 42 characters") and fades out.
final class Toast {
    private static var current: NSPanel?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        current?.close()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (message as NSString).size(withAttributes: attrs)
        let size = NSSize(width: textSize.width + 56, height: 40)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor

        let icon = NSImageView(frame: NSRect(x: 14, y: 11, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .white
        content.addSubview(icon)

        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: message, attributes: attrs))
        label.frame = NSRect(x: 40, y: (size.height - textSize.height) / 2, width: textSize.width + 4, height: textSize.height)
        content.addSubview(label)
        panel.contentView = content

        // Top-center of the screen under the cursor
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 24))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        current = panel
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: {
                panel.close()
                if current === panel { current = nil }
            })
        }
    }
}
