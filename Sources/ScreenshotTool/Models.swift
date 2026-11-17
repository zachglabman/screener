import Foundation
import CoreGraphics
import AppKit

// MARK: - Capture Modes
enum CaptureMode: String, Codable {
    case area
    case window
    case fullscreen
    case previousArea
    case freeze
    case ocr
}

// MARK: - Capture Result (in-memory)
struct CaptureResult {
    let image: NSImage
    let rect: CGRect
    let mode: CaptureMode
    let windowID: CGWindowID?
    /// ⌃ variants of the shortcuts: straight to the clipboard, no thumbnail
    var copyOnly = false

    init(image: NSImage, rect: CGRect, mode: CaptureMode, windowID: CGWindowID? = nil) {
        self.image = image
        self.rect = rect
        self.mode = mode
        self.windowID = windowID
    }
}

// MARK: - Annotation Tool Types
enum AnnotationToolType: String, CaseIterable {
    case arrow        = "Arrow"
    case rectangle    = "Rectangle"
    case filled       = "Filled Rect"
    case ellipse      = "Ellipse"
    case line         = "Line"
    case pencil       = "Pencil"
    case highlighter  = "Highlighter"
    case text         = "Text"
    case blur         = "Blur"
    case crop         = "Crop"

    var keyEquivalent: String {
        switch self {
        case .arrow:       return "a"
        case .rectangle:   return "r"
        case .filled:      return "f"
        case .ellipse:     return "e"
        case .line:        return "l"
        case .pencil:      return "p"
        case .highlighter: return "h"
        case .text:        return "t"
        case .blur:        return "b"
        case .crop:        return "c"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow:       return "arrow.up.right"
        case .rectangle:   return "rectangle"
        case .filled:      return "rectangle.fill"
        case .ellipse:     return "oval"
        case .line:        return "line.diagonal"
        case .pencil:      return "pencil"
        case .highlighter: return "highlighter"
        case .text:        return "textformat"
        case .blur:        return "aqi.medium"
        case .crop:        return "crop"
        }
    }

    var cursor: NSCursor {
        switch self {
        case .text: return .iBeam
        case .crop: return .crosshair
        default:    return .crosshair
        }
    }
}

// MARK: - Annotation Objects
class AnnotationObject: NSObject {
    var id = UUID()
    var tool: AnnotationToolType
    var startPoint: CGPoint = .zero
    var endPoint: CGPoint   = .zero
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""
    var path: [CGPoint] = []   // freehand / highlighter
    var blurRadius: CGFloat = 12.0
    var opacity: CGFloat = 1.0

    init(tool: AnnotationToolType,
         color: NSColor = .systemRed,
         lineWidth: CGFloat = 3.0) {
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
    }

    var boundingRect: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }
}

// MARK: - Window Info for window picker
struct WindowInfo {
    let windowID: CGWindowID
    let title: String
    let appName: String
    let frame: CGRect
    let image: NSImage?
}
