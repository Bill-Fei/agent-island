import AppKit
import Carbon.HIToolbox

/// One system-wide hot key (⌃⌥A). Registered only while an approval is pending.
/// It only asks the island to open the review popover; it can never approve anything.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void
    var isRegistered: Bool { hotKeyRef != nil }

    init(onPress: @escaping () -> Void) { self.onPress = onPress }

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_A), modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let target = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { target.onPress() } }
            return noErr
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, pointer, &handlerRef) == noErr else { return }
        let identifier = EventHotKeyID(signature: OSType(0x4C4C5441), id: 1)
        if RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef) != noErr {
            unregister()
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
