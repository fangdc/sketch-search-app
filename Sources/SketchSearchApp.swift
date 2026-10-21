import AppKit
import SwiftUI

@main
struct SketchSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var state: AppState
    @Environment(\.openSettings) private var openSettings

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _state = StateObject(wrappedValue: AppState(settings: settings))
    }

    var body: some Scene {
        Window("SketchSearch", id: "main") {
            SearchView()
                .environmentObject(state)
                .environmentObject(settings)
                .onAppear { state.start() }
        }
        .defaultSize(width: 1140, height: 700)
        // 这里不再隐藏标题栏：tab 组件和刷新/设置按钮要放进窗口顶部的工具栏，
        // 需要标准的标题栏+工具栏容器。
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                if let key = settings.shortcutRefresh.keyEquivalent {
                    Button("立即刷新索引") { state.refresh(force: false, announce: true) }
                        .keyboardShortcut(key, modifiers: settings.shortcutRefresh.eventModifiers)
                        .disabled(state.isIndexing)
                } else {
                    Button("立即刷新索引") { state.refresh(force: false, announce: true) }
                        .disabled(state.isIndexing)
                }
                Button("重建索引") { state.rebuildIndex() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(state.isIndexing)
            }
        }

        MenuBarExtra("SketchSearch", systemImage: "mail.and.text.magnifyingglass") {
            // 快捷键交给 .keyboardShortcut 绘制：系统会把它排到右侧、用小灰字显示，
            // 和系统菜单是同一套样式。值来自设置，用户改了就跟着变。
            // （⌥Space 同时也由 Carbon 全局注册；重复不会双触发 —— Carbon 会把该组合键
            //   从应用的事件流里截走。）
            if let key = settings.shortcutSummon.keyEquivalent {
                Button("打开搜索窗口") { state.showMainWindow() }
                    .keyboardShortcut(key, modifiers: settings.shortcutSummon.eventModifiers)
            } else {
                // F 键之类没有 KeyEquivalent 的键：只能写进标题
                Button("打开搜索窗口　\(settings.shortcutSummon.display)") { state.showMainWindow() }
            }
            Divider()
            if let key = settings.shortcutRefresh.keyEquivalent {
                Button("立即刷新索引") { state.refresh(force: false, announce: true) }
                    .keyboardShortcut(key, modifiers: settings.shortcutRefresh.eventModifiers)
                    .disabled(state.isIndexing)
            } else {
                Button("立即刷新索引　\(settings.shortcutRefresh.display)") {
                    state.refresh(force: false, announce: true)
                }
                .disabled(state.isIndexing)
            }
            if let last = state.lastRefresh {
                Text("上次刷新：" + last.formatted(date: .omitted, time: .shortened))
            }
            Text("已索引 \(state.stats.files) 个文件 · \(state.stats.artboards) 个画板")
            Divider()
            // 不能用 SettingsLink：关窗后应用处于 .accessory（无程序坞图标），
            // 这时直接开设置窗口不会自动激活到最前。先切回 .regular 再开。
            Button("设置…") {
                if NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                }
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        }

        Settings {
            SettingsView(settings: settings)
                .environmentObject(state)
                .environmentObject(settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    /// 关闭窗口不退出应用：菜单栏图标和后台自动刷新继续工作
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点程序坞图标、或 `open -a SketchSearch` 重新打开时：
    /// 关窗后程序坞图标本来已经收掉了，这里把窗口叫回来（同时会把激活策略切回 regular）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.current?.showMainWindow()
        }
        return true
    }
}
