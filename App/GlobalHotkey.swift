import Carbon.HIToolbox
import Foundation
import Observation

/// The opt-in global shortcut ⌃⌥H (off by default), which toggles the panel. Carbon's
/// `RegisterEventHotKey` needs no Accessibility permission, unlike an `NSEvent` global monitor.
/// The key is registered only while the setting is on; if another app holds it, the setting
/// records the conflict for Settings to show.
@MainActor
final class GlobalHotkey {
    /// 'HLhk', so the handler can tell this key from any other hot key in the process.
    nonisolated private static let hotKeyID = EventHotKeyID(signature: 0x484C_686B, id: 1)

    private let settings: SettingsModel
    private let action: @MainActor () -> Void
    // Touched from `deinit`, which isn't main-actor isolated; only the main thread uses them.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?

    init(settings: SettingsModel, action: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.action = action
        followSetting()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers while the setting is on and unregisters as soon as it's turned off.
    private func followSetting() {
        let enabled = withObservationTracking {
            settings.globalHotkeyEnabled
        } onChange: {
            Task { @MainActor [weak self] in self?.followSetting() }
        }
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr, pressed.signature == GlobalHotkey.hotKeyID.signature,
                      pressed.id == GlobalHotkey.hotKeyID.id else { return OSStatus(eventNotHandledErr) }
                // The application event target delivers on the main thread.
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotkey.action() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            guard status == noErr else {
                settings.globalHotkeyConflict = true
                return
            }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey), Self.hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = status == noErr ? ref : nil
        settings.globalHotkeyConflict = status != noErr
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        settings.globalHotkeyConflict = false
    }
}
