import Carbon
import Foundation

/// Registers a system-wide toggle shortcut (`⌃⌥S`) through Carbon HIToolbox.
///
/// Deliberately zero-polling and requires no Accessibility privacy permission: WindowServer
/// dispatches an event only when the user presses the key combination.
final class GlobalHotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private let hotKeyID = EventHotKeyID(
        signature: OSType(0x534C534B), // 'SLSK'
        id: 1
    )

    deinit {
        stop()
    }

    func start(onTrigger: @escaping () -> Void) {
        stop()
        self.onTrigger = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )
            let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr, pressedID.signature == monitor.hotKeyID.signature,
                  pressedID.id == monitor.hotKeyID.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { [weak monitor] in
                monitor?.onTrigger?()
            }
            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else { return }

        let modifiers = UInt32(controlKey | optionKey)
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if regStatus != noErr {
            stop()
        }
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        onTrigger = nil
    }
}
