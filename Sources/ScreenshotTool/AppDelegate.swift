import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, CaptureManagerDelegate {
    private let captureManager = CaptureManager()
    private let floatingPanelManager = FloatingPanelManager()
    private let hotkeys = HotkeyManager()
    private var statusItem: NSStatusItem!

    // MARK: - Shortcuts
    // ⇧⌘3/4/5 replace the macOS ones (turn those off in System Settings → Keyboard →
    // Keyboard Shortcuts → Screenshots). The rest use ⌃⌥⌘ so they don't steal
    // common app shortcuts like ⇧⌘R / ⇧⌘P / ⇧⌘W.
    private struct Shortcut {
        let keyCode: Int
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }

    private let areaShortcut       = Shortcut(keyCode: kVK_ANSI_4, key: "4", modifiers: [.command, .shift])
    private let windowShortcut     = Shortcut(keyCode: kVK_ANSI_5, key: "5", modifiers: [.command, .shift])
    private let fullscreenShortcut = Shortcut(keyCode: kVK_ANSI_3, key: "3", modifiers: [.command, .shift])
    // ⌃ variants copy straight to the clipboard, same as macOS
    private let areaCopyShortcut       = Shortcut(keyCode: kVK_ANSI_4, key: "4", modifiers: [.command, .shift, .control])
    private let fullscreenCopyShortcut = Shortcut(keyCode: kVK_ANSI_3, key: "3", modifiers: [.command, .shift, .control])
    private let textShortcut       = Shortcut(keyCode: kVK_ANSI_2, key: "2", modifiers: [.command, .shift])
    private let freezeShortcut     = Shortcut(keyCode: kVK_ANSI_F, key: "f", modifiers: [.command, .option, .control])
    private let previousShortcut   = Shortcut(keyCode: kVK_ANSI_R, key: "r", modifiers: [.command, .option, .control])
    private let togglePinsShortcut = Shortcut(keyCode: kVK_ANSI_P, key: "p", modifiers: [.command, .option, .control])
    private let closePinsShortcut  = Shortcut(keyCode: kVK_ANSI_W, key: "w", modifiers: [.command, .option, .control])

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        captureManager.delegate = self
        ImageExporter.shared.clearTemporaryFiles()
        setupMainMenu()
        setupStatusItem()
        registerHotkeys()
        requestScreenRecordingAccessIfNeeded()
        offerToDisableSystemShortcuts()
        enableLaunchAtLoginOnFirstRun()
    }

    // MARK: - Launch at Login
    // A screenshot tool has to always be there, so it's on by default (toggle in the menu)

    private func enableLaunchAtLoginOnFirstRun() {
        guard #available(macOS 13.0, *) else { return }
        let key = "didSetUpLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            print("Launch at login: \(error)")
        }
    }

    private func offerToDisableSystemShortcuts() {
        guard SystemScreenshotShortcuts.anyEnabled else { return }
        let alert = NSAlert()
        alert.messageText = "Replace the macOS screenshot shortcuts?"
        alert.informativeText = "macOS's own ⇧⌘3, ⇧⌘4, ⇧⌘5 (and the ⌃ copy-to-clipboard versions) are on, so both "
            + "tools run at once and macOS saves a file to your Desktop. Turn them off so Screenshot Tool handles them? "
            + "You can turn them back on from the menu bar."
        alert.addButton(withTitle: "Turn Off macOS Shortcuts")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SystemScreenshotShortcuts.setEnabled(false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ImageExporter.shared.clearTemporaryFiles()
    }

    private func registerHotkeys() {
        let bindings: [(Shortcut, String, () -> Void)] = [
            (areaShortcut,       "Capture Area",          { [weak self] in self?.captureManager.startAreaCapture() }),
            (windowShortcut,     "Capture Window",        { [weak self] in self?.captureManager.startWindowCapture() }),
            (fullscreenShortcut, "Capture Fullscreen",    { [weak self] in self?.captureManager.captureFullscreen() }),
            (areaCopyShortcut,   "Copy Area",             { [weak self] in self?.captureManager.startAreaCapture(toClipboard: true) }),
            (fullscreenCopyShortcut, "Copy Fullscreen",   { [weak self] in self?.captureManager.captureFullscreen(toClipboard: true) }),
            (textShortcut,       "Capture Text",          { [weak self] in self?.captureManager.startTextCapture() }),
            (freezeShortcut,     "Freeze Screen",         { [weak self] in self?.captureManager.startFreezeCapture() }),
            (previousShortcut,   "Capture Previous Area", { [weak self] in self?.captureManager.capturePreviousArea() }),
            (togglePinsShortcut, "Toggle Pins",           { [weak self] in self?.floatingPanelManager.toggleAllPanels() }),
            (closePinsShortcut,  "Close All Pins",        { [weak self] in self?.floatingPanelManager.closeAllPanels() })
        ]
        for (shortcut, name, handler) in bindings {
            if !hotkeys.register(keyCode: UInt32(shortcut.keyCode), modifiers: shortcut.modifiers, handler: handler) {
                print("Could not register shortcut for \(name) — it may be in use by another app")
            }
        }
    }

    private func requestScreenRecordingAccessIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        // Shows the system prompt and adds the app to the Screen Recording list
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Main Menu
    // Not visible for a menu bar app, but it's what routes ⌘Z / ⌘C / ⌘V / ⌘S / ⌘W
    // to the editor and text fields.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Screenshot Tool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenuItem(appMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Save…", action: #selector(AnnotationEditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(submenuItem(fileMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(AnnotationCanvasView.undo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(AnnotationCanvasView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenuItem(editMenu))

        NSApp.mainMenu = mainMenu
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshot Tool")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuilt every time it opens so the pin list is current
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item("Capture Area", #selector(captureArea), areaShortcut))
        menu.addItem(item("Capture Window", #selector(captureWindow), windowShortcut))
        menu.addItem(item("Capture Fullscreen", #selector(captureFullscreen), fullscreenShortcut))
        menu.addItem(item("Capture Previous Area", #selector(capturePreviousArea), previousShortcut))
        menu.addItem(item("Freeze Screen & Capture", #selector(freezeCapture), freezeShortcut))
        menu.addItem(item("Capture Text (OCR)", #selector(captureText), textShortcut))
        menu.addItem(.separator())
        menu.addItem(item("Dismiss All Thumbnails", #selector(dismissThumbnails), nil))
        menu.addItem(.separator())

        let pinItems = floatingPanelManager.makePanelMenuItems()
        if pinItems.isEmpty {
            let none = NSMenuItem(title: "No Pinned Screenshots", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            pinItems.forEach { menu.addItem($0) }
            menu.addItem(item("Show / Hide All Pins", #selector(togglePins), togglePinsShortcut))
            menu.addItem(item("Unlock All Pins", #selector(unlockPins), nil))
            menu.addItem(item("Close All Pins", #selector(closePins), closePinsShortcut))
        }
        menu.addItem(.separator())

        if #available(macOS 13.0, *) {
            let login = item("Launch at Login", #selector(toggleLaunchAtLogin), nil)
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(item("Open Screenshots Folder", #selector(openSaveFolder), nil))
        menu.addItem(item("Change Save Location…", #selector(changeSaveLocation), nil))
        if SystemScreenshotShortcuts.anyEnabled {
            menu.addItem(item("Turn Off macOS Screenshot Shortcuts", #selector(disableSystemShortcuts), nil))
        } else {
            menu.addItem(item("Restore macOS Screenshot Shortcuts", #selector(restoreSystemShortcuts), nil))
        }
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(item("Grant Screen Recording Access…", #selector(openScreenRecordingSettings), nil))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, _ shortcut: Shortcut?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut?.key ?? "")
        if let shortcut = shortcut { item.keyEquivalentModifierMask = shortcut.modifiers }
        item.target = self
        return item
    }

    // MARK: - Menu Actions

    @objc private func captureArea()         { captureManager.startAreaCapture() }
    @objc private func captureWindow()       { captureManager.startWindowCapture() }
    @objc private func captureFullscreen()   { captureManager.captureFullscreen() }
    @objc private func capturePreviousArea() { captureManager.capturePreviousArea() }
    @objc private func freezeCapture()       { captureManager.startFreezeCapture() }
    @objc private func captureText()         { captureManager.startTextCapture() }
    @objc private func dismissThumbnails()   { QuickAccessOverlay.dismissAll() }
    @objc private func disableSystemShortcuts() { SystemScreenshotShortcuts.setEnabled(false) }
    @objc private func restoreSystemShortcuts() { SystemScreenshotShortcuts.setEnabled(true) }
    @objc private func togglePins()          { floatingPanelManager.toggleAllPanels() }
    @objc private func unlockPins()          { floatingPanelManager.unlockAllPanels() }
    @objc private func closePins()           { floatingPanelManager.closeAllPanels() }

    @objc private func openSaveFolder() {
        let dir = Preferences.shared.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func changeSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Preferences.shared.saveDirectory
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Preferences.shared.saveDirectory = url
        }
    }

    @objc private func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - CaptureManagerDelegate

    func captureManager(_ manager: CaptureManager, didCapture result: CaptureResult) {
        if result.copyOnly {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([result.image])
            return
        }
        if result.mode == .ocr {
            TextRecognizer.recognize(result.image) { text in
                guard let text = text else {
                    Toast.show("No text found", symbol: "text.magnifyingglass")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Toast.show("Copied \(text.count) characters")
            }
            return
        }
        // Area captures pin exactly where they were taken
        let pinFrame = (result.mode == .area || result.mode == .previousArea) ? result.rect : .zero
        QuickAccessOverlay.show(with: result.image, pinFrame: pinFrame, floatingPanelManager: floatingPanelManager)
    }
}
