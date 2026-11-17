import Foundation
import AppKit

/// Writes images to disk — only ever when the user asks (Save, Save As, or a drag
/// into another app). Captures otherwise live in memory only.
final class ImageExporter {
    static let shared = ImageExporter()

    private init() {}

    // MARK: - Save

    /// Saves to the user's configured folder with auto-naming. Returns the file written.
    @discardableResult
    func exportToSaveDirectory(_ image: NSImage) -> URL? {
        let prefs = Preferences.shared
        // WebP isn't supported by ImageIO for writing; save PNG instead
        let format = prefs.imageFormat == .webp ? .png : prefs.imageFormat
        let saveDir = prefs.saveDirectory
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let url = uniqueURL(in: saveDir, filename: prefs.generateFilename(for: format))
        return writeImage(image, to: url, format: format) ? url : nil
    }

    /// Picks the format from the file extension (JPEG for .jpg/.jpeg, otherwise PNG).
    @discardableResult
    func writeImage(_ image: NSImage, to url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return writeImage(image, to: url, format: (ext == "jpg" || ext == "jpeg") ? .jpeg : .png)
    }

    @discardableResult
    func writeImage(_ image: NSImage, to url: URL, format: Preferences.ImageFormat) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = image.size // keeps Retina captures tagged at 144 dpi
        var data: Data?
        switch format {
        case .png:
            data = rep.representation(using: .png, properties: [:])
        case .jpeg:
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: Preferences.shared.jpegQuality])
        case .webp:
            // WebP not natively supported; fall back to PNG
            data = rep.representation(using: .png, properties: [:])
        }
        do {
            try data?.write(to: url)
            return data != nil
        } catch {
            print("Failed to write \(url.path): \(error)")
            return false
        }
    }

    // MARK: - Temporary files (drag & drop)

    private var temporaryDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotTool", isDirectory: true)
    }

    /// Writes a PNG to a temp folder so it can be dragged into apps that want a file.
    /// The folder is wiped on launch and quit.
    func temporaryFile(for image: NSImage) -> URL? {
        try? FileManager.default.createDirectory(at: temporaryDir, withIntermediateDirectories: true)
        let url = uniqueURL(in: temporaryDir, filename: Preferences.shared.generateFilename(for: .png))
        return writeImage(image, to: url, format: .png) ? url : nil
    }

    func clearTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDir)
    }

    // MARK: - Helpers

    /// Appends " 2", " 3", … if a file with the same timestamp already exists.
    private func uniqueURL(in dir: URL, filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var url = dir.appendingPathComponent(filename)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
