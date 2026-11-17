import AppKit
import Carbon

// MARK: - Global Hotkeys (Carbon RegisterEventHotKey — no Accessibility permission needed)
final class HotkeyManager {
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    deinit {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }

    /// Returns false if the shortcut is already taken by another app or the system.
    @discardableResult
    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags,
                  handler: @escaping () -> Void) -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5353_544C), id: nextID) // 'SSTL'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, carbonFlags(from: modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else { return false }
        hotKeyRefs.append(ref)
        handlers[nextID] = handler
        nextID += 1
        return true
    }

    private func carbonFlags(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.shift)   { flags |= UInt32(shiftKey) }
        if modifiers.contains(.option)  { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }
}
