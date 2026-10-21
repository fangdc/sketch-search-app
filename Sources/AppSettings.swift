import AppKit
import Foundation
import SwiftUI

/// 应用设置，持久化在 UserDefaults 里。
final class AppSettings: ObservableObject {

    private enum Key {
        static let roots = "roots"
        static let autoRefresh = "autoRefreshEnabled"
        static let interval = "refreshIntervalMinutes"
        static let spotlightEnabled = "spotlightSyncEnabled"
        static let firstRunDone = "firstRunDone"
        static let summon = "shortcutSummon"
        static let refresh = "shortcutRefresh"
        static let openInSketch = "shortcutOpenInSketch"
    }

    @Published var roots: [String] {
        didSet { defaults.set(roots, forKey: Key.roots) }
    }

    /// 后台自动刷新索引（并在开启时同步 Spotlight 关键词）
    @Published var autoRefreshEnabled: Bool {
        didSet { defaults.set(autoRefreshEnabled, forKey: Key.autoRefresh) }
    }

    /// 自动刷新间隔（分钟）
    @Published var refreshIntervalMinutes: Int {
        didSet { defaults.set(refreshIntervalMinutes, forKey: Key.interval) }
    }

    /// 是否把画板名同步给 Spotlight（让 ⌘空格 也能搜到）
    @Published var spotlightSyncEnabled: Bool {
        didSet { defaults.set(spotlightSyncEnabled, forKey: Key.spotlightEnabled) }
    }

    @Published var firstRunDone: Bool {
        didSet { defaults.set(firstRunDone, forKey: Key.firstRunDone) }
    }

    // MARK: 快捷键（用户可改）

    /// 唤起搜索窗口（全局热键）
    @Published var shortcutSummon: Shortcut {
        didSet { saveShortcut(shortcutSummon, forKey: Key.summon) }
    }

    /// 立即刷新索引
    @Published var shortcutRefresh: Shortcut {
        didSet { saveShortcut(shortcutRefresh, forKey: Key.refresh) }
    }

    /// 在 Sketch 中打开所选文件
    @Published var shortcutOpenInSketch: Shortcut {
        didSet { saveShortcut(shortcutOpenInSketch, forKey: Key.openInSketch) }
    }

    private let defaults = UserDefaults.standard

    // Spotlight 关键词容量上限（实测约 20KB 会被系统截断，留出余量）
    let maxKeywords = 900
    let maxKeywordBytes = 18000

    let excludedDirectories = ["node_modules", ".git", ".Trash", "Library/Caches", "sketch-assets"]

    init() {
        let storedRoots = defaults.stringArray(forKey: Key.roots)
        // 新装时**不要**预置任何目录。
        // 以前默认塞 iCloud 云盘，结果首次启动就去扫它 —— macOS 立刻弹
        // 「SketchSearch 想访问 iCloud 云盘」，而用户根本没选过 iCloud；
        // 等他在引导页选自己的目录（比如「文档」）时又不弹窗（NSOpenPanel 会自动授权），
        // 于是看起来像「乱要权限」。现在只有用户亲手选过的位置才会被访问。
        roots = storedRoots ?? []

        if defaults.object(forKey: Key.autoRefresh) == nil {
            autoRefreshEnabled = true
        } else {
            autoRefreshEnabled = defaults.bool(forKey: Key.autoRefresh)
        }

        let storedInterval = defaults.integer(forKey: Key.interval)
        refreshIntervalMinutes = storedInterval > 0 ? storedInterval : 10

        if defaults.object(forKey: Key.spotlightEnabled) == nil {
            spotlightSyncEnabled = true
        } else {
            spotlightSyncEnabled = defaults.bool(forKey: Key.spotlightEnabled)
        }

        firstRunDone = defaults.bool(forKey: Key.firstRunDone)

        shortcutSummon = AppSettings.loadShortcut(Key.summon, defaults: defaults) ?? .summon
        shortcutRefresh = AppSettings.loadShortcut(Key.refresh, defaults: defaults) ?? .refresh
        shortcutOpenInSketch = AppSettings.loadShortcut(Key.openInSketch, defaults: defaults) ?? .openInSketch
    }

    // MARK: 快捷键持久化

    private func saveShortcut(_ shortcut: Shortcut, forKey key: String) {
        defaults.set(["keyCode": Int(shortcut.keyCode),
                      "modifiers": Int(shortcut.modifiers.rawValue)], forKey: key)
    }

    private static func loadShortcut(_ key: String, defaults: UserDefaults) -> Shortcut? {
        guard let dict = defaults.dictionary(forKey: key),
              let keyCode = dict["keyCode"] as? Int,
              let modifiers = dict["modifiers"] as? Int else { return nil }
        return Shortcut(keyCode: UInt16(keyCode),
                        modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
    }

    /// 全部恢复默认
    func resetShortcuts() {
        shortcutSummon = .summon
        shortcutRefresh = .refresh
        shortcutOpenInSketch = .openInSketch
    }

    var refreshIntervalSeconds: TimeInterval {
        TimeInterval(max(1, refreshIntervalMinutes) * 60)
    }

    // MARK: - 数据存放位置

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("SketchSearch", isDirectory: true)
    }

    static var databaseURL: URL {
        supportDirectory.appendingPathComponent("index.db")
    }

    static var thumbnailDirectory: URL {
        supportDirectory.appendingPathComponent("thumbs", isDirectory: true)
    }
}
