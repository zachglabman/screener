import Foundation

/// macOS's built-in screenshot shortcuts. While they're on, ⇧⌘3/4/5 fire both
/// the system tool (which saves a file to the Desktop) and ours. Like CleanShot,
/// we offer to turn them off.
enum SystemScreenshotShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString

    // Symbolic hotkey IDs and their default (char, keyCode, modifiers) values
    private static let shortcuts: [Int: [Int]] = [
        28:  [51, 20, 1_179_648],   // ⇧⌘3  Save picture of screen
        29:  [51, 20, 1_441_792],   // ⇧⌃⌘3 Copy picture of screen
        30:  [52, 21, 1_179_648],   // ⇧⌘4  Save picture of selected area
        31:  [52, 21, 1_441_792],   // ⇧⌃⌘4 Copy picture of selected area
        184: [53, 23, 1_179_648]    // ⇧⌘5  Screenshot and recording options
    ]

    /// True if any of the conflicting macOS shortcuts is on (missing entries mean default = on).
    static var anyEnabled: Bool {
        let all = CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
        return shortcuts.keys.contains { id in
            (all[String(id)] as? [String: Any])?["enabled"] as? Bool ?? true
        }
    }

    static func setEnabled(_ enabled: Bool) {
        var all = CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
        for (id, parameters) in shortcuts {
            all[String(id)] = [
                "enabled": enabled,
                "value": ["parameters": parameters, "type": "standard"]
            ]
        }
        CFPreferencesSetAppValue(key, all as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)

        // Apply without logging out
        let reload = Process()
        reload.executableURL = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        reload.arguments = ["-u"]
        try? reload.run()
        reload.waitUntilExit()
    }
}
