import AppKit
import Carbon
import SwiftUI

/// 一个可自定义的快捷键：物理键码 + 修饰键。
///
/// 用键码而不是字符：键码与键盘布局无关，换成法语键盘 AZERTY 时
/// 「⌘R」仍然按在那个物理位置上。
struct Shortcut: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    // MARK: 默认值

    static let summon = Shortcut(keyCode: 49, modifiers: [.option])          // ⌥Space
    static let refresh = Shortcut(keyCode: 15, modifiers: [.command])        // ⌘R
    static let openInSketch = Shortcut(keyCode: 36, modifiers: [.command])   // ⌘↩

    /// 只保留四种与设备无关的修饰键（去掉 capsLock / fn 之类）
    static func sanitize(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift])
    }

    // MARK: 展示

    /// 形如 ⌃⌥⇧⌘R。顺序遵循 macOS 的书写习惯。
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Shortcut.keyMap[keyCode]?.name ?? "键码 \(keyCode)")
    }

    // MARK: 注册用

    /// Carbon 的全局热键修饰位
    var carbonModifiers: UInt32 {
        var bits: UInt32 = 0
        if modifiers.contains(.command) { bits |= UInt32(cmdKey) }
        if modifiers.contains(.option) { bits |= UInt32(optionKey) }
        if modifiers.contains(.control) { bits |= UInt32(controlKey) }
        if modifiers.contains(.shift) { bits |= UInt32(shiftKey) }
        return bits
    }

    /// 给 SwiftUI 的 `.keyboardShortcut` 用；表里没有的键返回 nil（那种键只能做全局热键）
    var keyEquivalent: KeyEquivalent? {
        switch keyCode {
        case 36: return .return
        case 48: return .tab
        case 49: return .space
        case 51: return .delete
        case 53: return .escape
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default:
            guard let char = Shortcut.keyMap[keyCode]?.char else { return nil }
            return KeyEquivalent(char)
        }
    }

    /// 给 SwiftUI 的 `.keyboardShortcut` 用的修饰键
    var eventModifiers: SwiftUI.EventModifiers {
        var value: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { value.insert(.command) }
        if modifiers.contains(.option) { value.insert(.option) }
        if modifiers.contains(.control) { value.insert(.control) }
        if modifiers.contains(.shift) { value.insert(.shift) }
        return value
    }

    // MARK: 键码表（ANSI 布局）

    /// keyCode → （用于 KeyEquivalent 的字符, 展示名）
    static let keyMap: [UInt16: (char: Character, name: String)] = [
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"),
        5: ("g", "G"), 6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"),
        11: ("b", "B"), 12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"),
        16: ("y", "Y"), 17: ("t", "T"), 18: ("1", "1"), 19: ("2", "2"), 20: ("3", "3"),
        21: ("4", "4"), 22: ("6", "6"), 23: ("5", "5"), 24: ("=", "="), 25: ("9", "9"),
        26: ("7", "7"), 27: ("-", "-"), 28: ("8", "8"), 29: ("0", "0"), 30: ("]", "]"),
        31: ("o", "O"), 32: ("u", "U"), 33: ("[", "["), 34: ("i", "I"), 35: ("p", "P"),
        37: ("l", "L"), 38: ("j", "J"), 39: ("'", "'"), 40: ("k", "K"), 41: (";", ";"),
        42: ("\\", "\\"), 43: (",", ","), 44: ("/", "/"), 45: ("n", "N"), 46: ("m", "M"),
        47: (".", "."), 50: ("`", "`"), 36: ("\r", "↩"), 48: ("\t", "⇥"),
        49: (" ", "Space"), 51: ("\u{7F}", "⌫"), 53: ("\u{1B}", "⎋"),
        123: ("\u{F702}", "←"), 124: ("\u{F703}", "→"),
        125: ("\u{F701}", "↓"), 126: ("\u{F700}", "↑"),
    ]
}

/// 快捷键录制控件：点一下进入录制，按下组合键即生效，Esc 取消。
///
/// 用 NSViewRepresentable + NSButton 而不是 SwiftUI 的 @State：
/// 当前工具链编译 SwiftUI 的 State 宏会崩（项目里所有状态都放在 AppSettings / AppState）。
struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut
    var onChange: (Shortcut) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: shortcut.display,
                              target: context.coordinator,
                              action: #selector(Coordinator.begin(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isRecording {
            button.title = shortcut.display
        }
    }

    final class Coordinator: NSObject {
        var parent: ShortcutRecorder
        private(set) var isRecording = false
        private var monitor: Any?

        init(_ parent: ShortcutRecorder) { self.parent = parent }

        @objc func begin(_ sender: NSButton) {
            guard !isRecording else { return }
            isRecording = true
            sender.title = "请按下新的快捷键…"
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Esc：取消
                if event.keyCode == 53 { self.end(); return nil }
                let flags = Shortcut.sanitize(event.modifierFlags)
                // 必须至少带一个修饰键，否则会和普通输入冲突
                guard !flags.isEmpty else { return nil }
                self.parent.onChange(Shortcut(keyCode: event.keyCode, modifiers: flags))
                self.end()
                return nil
            }
        }

        private func end() {
            isRecording = false
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
