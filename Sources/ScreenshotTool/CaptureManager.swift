import AppKit
import CoreGraphics
import Foundation

// MARK: - Delegate
protocol CaptureManagerDelegate: AnyObject {
    func captureManager(_ manager: CaptureManager, didCapture result: CaptureResult)
}

// MARK: - CaptureManager
final class CaptureManager: NSObject {
    weak var delegate: CaptureManagerDelegate?
    private var selectionOverlays: [SelectionOverlayWindow] = []
    private var previousApp: NSRunningApplication?
    /// Set by the ⌃ shortcut variants; applies to the capture in progress
    private var clipboardOnly = false

    private lazy var shutterSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    // MARK: - Area Capture
    func startAreaCapture(toClipboard: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.clipboardOnly = toClipboard
            self?.showSelectionOverlay(mode: .area)
        }
    }

    // MARK: - Window Capture
    func startWindowCapture() {
        DispatchQueue.main.async { [weak self] in
            self?.showSelectionOverlay(mode: .window)
        }
    }

    // MARK: - Freeze Screen
    // Snapshots every display first, then you select on the frozen image —
    // for hover states, tooltips and menus that vanish on click
    func startFreezeCapture() {
        DispatchQueue.main.async { [weak self] in
            self?.showSelectionOverlay(mode: .freeze)
        }
    }

    // MARK: - OCR
    func startTextCapture() {
        DispatchQueue.main.async { [weak self] in
            self?.showSelectionOverlay(mode: .ocr)
        }
    }

    // MARK: - Fullscreen
    func captureFullscreen(toClipboard: Bool = false) {
        // Small delay so menu closes first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.clipboardOnly = toClipboard
            self?.performFullscreenCapture()
        }
    }

    func capturePreviousArea() {
        guard let rect = Preferences.shared.lastCaptureRect else {
            startAreaCapture()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.captureRect(rect, mode: .previousArea)
        }
    }

    // MARK: - Internal capture implementations

    private func showSelectionOverlay(mode: CaptureMode) {
        guard selectionOverlays.isEmpty else { return } // already selecting
        // Kept across a Space-bar mode switch, when we're frontmost ourselves
        if previousApp == nil { previousApp = NSWorkspace.shared.frontmostApplication }

        // Read the window list before our overlays exist so they aren't in it
        let windows = mode == .window ? CaptureManager.visibleWindows() : []

        // One overlay per display — a single window can't span screens when
        // "Displays have separate Spaces" is on
        selectionOverlays = NSScreen.screens.map { screen in
            let overlay = SelectionOverlayWindow(captureMode: mode, screen: screen, windows: windows)
            overlay.onSelection = { [weak self, weak overlay] rect, windowID in
                guard let self = self else { return }
                // Frozen captures come from the snapshot, so grab it before the overlay goes away
                let frozen = mode == .freeze ? overlay?.frozenImage(in: rect) : nil
                self.dismissSelectionOverlays()
                if let frozen = frozen {
                    Preferences.shared.lastCaptureRect = rect
                    self.deliver(CaptureResult(image: frozen, rect: rect, mode: .area))
                    return
                }
                // Brief pause so overlay windows disappear before capture
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if mode == .window, let wid = windowID {
                        self.captureWindow(windowID: wid, frame: rect)
                    } else {
                        if mode != .ocr { Preferences.shared.lastCaptureRect = rect }
                        self.captureRect(rect, mode: mode)
                    }
                }
            }
            overlay.onCancel = { [weak self] in
                self?.clipboardOnly = false
                self?.dismissSelectionOverlays()
            }
            // Space toggles area ↔ window, like the macOS tool
            overlay.onToggleWindowMode = { [weak self] in
                guard let self = self else { return }
                self.dismissSelectionOverlays(restoreFocus: false)
                self.showSelectionOverlay(mode: mode == .window ? .area : .window)
            }
            return overlay
        }

        NSApp.activate(ignoringOtherApps: true)
        selectionOverlays.forEach { $0.orderFrontRegardless() }
        // Key window goes to the screen under the cursor so Esc works there
        let mouse = NSEvent.mouseLocation
        let keyOverlay = selectionOverlays.first { NSMouseInRect(mouse, $0.frame, false) } ?? selectionOverlays.first
        keyOverlay?.makeKey()
    }

    private func dismissSelectionOverlays(restoreFocus: Bool = true) {
        selectionOverlays.forEach { $0.close() }
        selectionOverlays = []
        guard restoreFocus else { return }
        // Give focus back to whatever the user was working in
        previousApp?.activate(options: [])
        previousApp = nil
    }

    /// Plays the shutter and hands the capture to the delegate.
    private func deliver(_ result: CaptureResult) {
        var result = result
        result.copyOnly = clipboardOnly
        clipboardOnly = false
        if result.mode != .ocr { shutterSound?.play() }
        delegate?.captureManager(self, didCapture: result)
    }

    /// `rect` is in Cocoa screen coordinates (bottom-left origin, points).
    func captureRect(_ rect: CGRect, mode: CaptureMode) {
        guard let cgImage = CGWindowListCreateImage(
            CaptureManager.flip(rect),
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) else {
            print("Failed to capture rect")
            return
        }
        let image = NSImage(cgImage: cgImage, size: rect.size)
        let result = CaptureResult(image: image, rect: rect, mode: mode)
        deliver(result)
    }

    private func captureWindow(windowID: CGWindowID, frame: CGRect) {
        var options: CGWindowImageOption = [.bestResolution]
        if !Preferences.shared.includeWindowShadow {
            options.insert(.boundsIgnoreFraming)
        }
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, options) else {
            print("Failed to capture window \(windowID)")
            return
        }
        // Image is in pixels; size the NSImage in points for the window's display
        let scale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
        let size = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        let image = NSImage(cgImage: cgImage, size: size)
        let result = CaptureResult(image: image, rect: frame, mode: .window, windowID: windowID)
        deliver(result)
    }

    private func performFullscreenCapture() {
        // Capture the display the cursor is on
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        captureRect(screen.frame, mode: .fullscreen)
    }

    // MARK: - Coordinates

    /// Converts between Cocoa screen coordinates (bottom-left origin) and
    /// CoreGraphics global coordinates (top-left origin). Both are anchored to
    /// the primary display, so the same flip works in either direction.
    static func flip(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Window Listing

    /// Front-to-back list of normal app windows, with frames in Cocoa screen coordinates.
    static func visibleWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return list.compactMap { dict -> WindowInfo? in
            guard
                let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                let layer = dict[kCGWindowLayer as String] as? Int, layer == 0, // skip menu bar, Dock, etc.
                let pid = dict[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
                let x = boundsDict["X"], let y = boundsDict["Y"],
                let w = boundsDict["Width"], let h = boundsDict["Height"],
                w > 1, h > 1
            else { return nil }

            let appName = dict[kCGWindowOwnerName as String] as? String ?? ""
            let title   = dict[kCGWindowName as String] as? String ?? appName
            let frame   = flip(CGRect(x: x, y: y, width: w, height: h))

            return WindowInfo(windowID: windowID, title: title, appName: appName, frame: frame, image: nil)
        }
    }
}
