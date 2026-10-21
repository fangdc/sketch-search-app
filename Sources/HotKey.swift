import AppKit
import Carbon
import Foundation

/// 全局快捷键（默认 ⌥Space）。
/// 用 Carbon 的 RegisterEventHotKey 实现：不需要辅助功能权限，
/// 也不会像 NSEvent 全局监听那样要求用户额外授权。
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void
    private static var shared: GlobalHotKey?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData = userData else { return noErr }
                let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { instance.action() }
                return noErr
            },
            1, &eventType, context, &eventHandler)

        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x534B5348), id: 1) // 'SKSH'
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let handler = eventHandler { RemoveEventHandler(handler) }
            return nil
        }
        GlobalHotKey.shared = self
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
        if GlobalHotKey.shared === self { GlobalHotKey.shared = nil }
    }
}
