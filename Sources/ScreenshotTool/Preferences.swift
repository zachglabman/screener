import Foundation
import AppKit

final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Save Location
    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: "saveDirectory"),
               !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Screenshots")
        }
        set { defaults.set(newValue.path, forKey: "saveDirectory") }
    }

    // MARK: - File Format
    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: "imageFormat") ?? "png") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: "imageFormat") }
    }

    enum ImageFormat: String, CaseIterable {
        case png  = "png"
        case jpeg = "jpeg"
        case webp = "webp"

        var fileExtension: String { rawValue }
        var displayName: String {
            switch self {
            case .png:  return "PNG"
            case .jpeg: return "JPEG"
            case .webp: return "WebP"
            }
        }
    }

    var jpegQuality: CGFloat {
        get { CGFloat(defaults.double(forKey: "jpegQuality") > 0 ? defaults.double(forKey: "jpegQuality") : 0.9) }
        set { defaults.set(Double(newValue), forKey: "jpegQuality") }
    }

    // MARK: - Naming
    var fileNamingPattern: String {
        get { defaults.string(forKey: "fileNamingPattern") ?? "Screenshot-{date}-{time}" }
        set { defaults.set(newValue, forKey: "fileNamingPattern") }
    }

    func generateFilename(for format: ImageFormat? = nil) -> String {
        let fmt = format ?? imageFormat
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let datePart = df.string(from: now)
        df.dateFormat = "HHmmss"
        let timePart = df.string(from: now)
        let name = fileNamingPattern
            .replacingOccurrences(of: "{date}", with: datePart)
            .replacingOccurrences(of: "{time}", with: timePart)
        return "\(name).\(fmt.fileExtension)"
    }

    // MARK: - Overlay
    var overlayPosition: OverlayPosition {
        get { OverlayPosition(rawValue: defaults.string(forKey: "overlayPosition") ?? "bottomRight") ?? .bottomRight }
        set { defaults.set(newValue.rawValue, forKey: "overlayPosition") }
    }

    enum OverlayPosition: String, CaseIterable {
        case topLeft     = "topLeft"
        case topRight    = "topRight"
        case bottomLeft  = "bottomLeft"
        case bottomRight = "bottomRight"

        var displayName: String {
            switch self {
            case .topLeft:     return "Top Left"
            case .topRight:    return "Top Right"
            case .bottomLeft:  return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            }
        }
    }

    var overlayAutoDismissSeconds: Double {
        get {
            let v = defaults.double(forKey: "overlayAutoDismissSeconds")
            return v > 0 ? v : 5.0
        }
        set { defaults.set(newValue, forKey: "overlayAutoDismissSeconds") }
    }

    var overlayAutoDismissEnabled: Bool {
        // Off by default: thumbnails stay in the corner until dismissed
        get { defaults.object(forKey: "overlayAutoDismissEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "overlayAutoDismissEnabled") }
    }

    // MARK: - Floating Windows
    var floatingWindowDefaultOpacity: Double {
        get {
            let v = defaults.double(forKey: "floatingWindowDefaultOpacity")
            return v > 0 ? v : 1.0
        }
        set { defaults.set(newValue, forKey: "floatingWindowDefaultOpacity") }
    }

    var floatingWindowAlwaysOnTop: Bool {
        get { defaults.object(forKey: "floatingWindowAlwaysOnTop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "floatingWindowAlwaysOnTop") }
    }

    // MARK: - Capture
    var showMagnifier: Bool {
        // Off by default, like CleanShot: plain crosshair
        get { defaults.object(forKey: "showMagnifier") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "showMagnifier") }
    }

    var includeWindowShadow: Bool {
        get { defaults.object(forKey: "includeWindowShadow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "includeWindowShadow") }
    }

    // MARK: - Annotation Defaults
    var annotationColor: NSColor {
        get {
            if let data = defaults.data(forKey: "annotationColor"),
               let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                return color
            }
            return .systemRed
        }
        set {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: false) {
                defaults.set(data, forKey: "annotationColor")
            }
        }
    }

    var annotationLineWidth: CGFloat {
        get {
            let v = defaults.double(forKey: "annotationLineWidth")
            return v > 0 ? CGFloat(v) : 3.0
        }
        set { defaults.set(Double(newValue), forKey: "annotationLineWidth") }
    }

    var lastCaptureRect: CGRect? {
        get {
            guard let str = defaults.string(forKey: "lastCaptureRect") else { return nil }
            return NSRectFromString(str)
        }
        set {
            if let r = newValue {
                defaults.set(NSStringFromRect(r), forKey: "lastCaptureRect")
            } else {
                defaults.removeObject(forKey: "lastCaptureRect")
            }
        }
    }
}
