import Carbon.HIToolbox
import MoobilityCore

/// The global replay shortcut. Carbon's hot keys need no Input Monitoring permission and consume the key press.
final class HotKey {
    var onPress: (() -> Void)?

    private var registered: EventHotKeyRef?
    private var registeredCombo: HotKeyCombo?
    private var handler: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.onPress?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// False when registration failed; the old combo stays registered.
    func register(_ combo: HotKeyCombo) -> Bool {
        if combo == registeredCombo { return true }
        var created: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D43_616D), id: 1)  // 'MCam'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &created)
        guard status == noErr, let created else { return false }
        if let registered { UnregisterEventHotKey(registered) }
        registered = created
        registeredCombo = combo
        return true
    }
}
