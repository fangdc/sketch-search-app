import AppKit
import SwiftUI

// MARK: - 系统设置风格的行
//
// 背景、行内边距、行间分隔线全部交给 `.formStyle(.grouped)` 的 Form 处理，
// 这里只负责「左边标题 / 右边控件」的排布，不自己画底。

/// 一行设置项：左边标题（可带灰色说明），右边控件。
struct SettingsRow<Trailing: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// 路径文本：等宽字体、单行、中间截断、可选中复制
private func pathText(_ path: String) -> some View {
    Text((path as NSString).abbreviatingWithTildeInPath)
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var settings: AppSettings

    /// 「缩略图缓存：127 MB」里的体积部分
    private var cacheSizeText: String {
        let bytes = state.thumbnailCacheBytes
        guard bytes > 0 else { return "0 MB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        TabView {
            indexTab
                .tabItem { Label("索引目录", systemImage: "folder") }
            spotlightTab
                .tabItem { Label("聚焦搜索", systemImage: "magnifyingglass") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 620)
        // 每次打开设置都重算一次缓存体积（扫描在后台做）
        .onAppear { state.refreshThumbnailCacheSize() }
    }

    // MARK: - 索引目录

    private var indexTab: some View {
        Form {
            Section {
                ForEach(settings.roots, id: \.self) { root in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        pathText(root)
                        Spacer(minLength: 12)
                        Button {
                            settings.roots.removeAll { $0 == root }
                        } label: {
                            // Label + iconOnly：系统才会按标准图标按钮算边框（纯 Image 不会）
                            Label("移除", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .controlSize(.small)
                        .help("从索引中移除这个文件夹")
                    }
                }

                HStack(spacing: 8) {
                    Button("添加文件夹") { addRoot() }
                        .controlSize(.small)
                    Spacer()
                    if state.isIndexing {
                        ProgressView().controlSize(.small)
                    }
                }
            } header: {
                Text("索引文件夹")
            } footer: {
                Text("添加存放 Sketch 文件的文件夹，SketchSearch 仅对文件夹中的 Sketch 文件进行画板解析，"
                     + "该功能不会破坏文件本体或进行其他破坏性操作。")
            }

            Section {
                Toggle("后台自动刷新索引", isOn: Binding(
                    get: { settings.autoRefreshEnabled },
                    set: { settings.autoRefreshEnabled = $0; state.applyAutoRefreshSetting() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                SettingsRow(title: "刷新间隔") {
                    Picker("", selection: Binding(
                        get: { settings.refreshIntervalMinutes },
                        set: { settings.refreshIntervalMinutes = $0; state.applyAutoRefreshSetting() }
                    )) {
                        Text("5 分钟").tag(5)
                        Text("10 分钟").tag(10)
                        Text("30 分钟").tag(30)
                        Text("1 小时").tag(60)
                        Text("3 小时").tag(180)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(Color(nsColor: .labelColor))
                    .disabled(!settings.autoRefreshEnabled)
                }
            } header: {
                Text("自动刷新")
            } footer: {
                Text("另外，每次切回本应用时若距上次刷新超过 2 分钟，也会自动更新一次。"
                     + "刷新是增量的：只有新增或改动过的 Sketch 文件会被重新解析，通常几秒完成。")
            }

            Section {
                SettingsRow(title: "手动刷新") {
                    HStack(spacing: 8) {
                        if state.isIndexing {
                            ProgressView().controlSize(.small)
                        }
                        Button("立即刷新") { state.refresh(force: false, announce: true) }
                            .controlSize(.small)
                            .disabled(state.isIndexing)
                    }
                }

                SettingsRow(title: "缩略图缓存：\(cacheSizeText)") {
                    Button("清理缓存") { state.clearThumbnailCache() }
                        .controlSize(.small)
                }
            } header: {
                Text("手动操作")
            }
        }
        .formStyle(.grouped)
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "加入索引"
        panel.message = "选择包含 .sketch 文件的文件夹"
        if panel.runModal() == .OK {
            let paths = panel.urls.map { $0.path }
            var added: [String] = []
            for path in paths where !settings.roots.contains(path) {
                settings.roots.append(path)
                added.append(path)
            }
            // 先判断新加的目录里有没有 .sketch（没有就立刻提示），再开始索引
            state.checkNewRoots(added)
            state.refresh(force: false, reason: "正在索引新加入的文件夹…", announce: true)
        }
    }

    // MARK: - 自动刷新

    // MARK: - Spotlight

    private var spotlightTab: some View {
        Form {
            Section {
                Toggle("把画板名 / 页面名同步到 Spotlight 关键词",
                       isOn: $settings.spotlightSyncEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                HStack(spacing: 8) {
                    Button("立即同步") { state.syncSpotlightNow() }
                        .controlSize(.small)
                        .disabled(state.isIndexing || !settings.spotlightSyncEnabled)
                    Button("清除已写入的关键词") { state.removeSpotlightKeywords() }
                        .controlSize(.small)
                        .disabled(state.isIndexing)
                    Spacer()
                    if state.isIndexing {
                        ProgressView().controlSize(.small)
                    }
                }
            } header: {
                Text("同步到 Spotlight")
            }

            Section {
                SettingsRow(title: "已标注") {
                    Text("\(state.stats.tagged) / \(state.stats.files) 个文件")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

            } header: {
                Text("状态")
            } footer: {
                if state.stats.truncated > 0 {
                    Text("其中 \(state.stats.truncated) 个文件画板过多，超出系统关键词容量上限，"
                         + "超出部分只能在本地搜索里搜到。")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var aboutTab: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AppLogoView(size: 64)
                    Text("SketchSearch").font(.title3.weight(.semibold))
                    Text("版本 1.0").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section {
                SettingsRow(title: "唤起搜索窗口") {
                    ShortcutRecorder(shortcut: settings.shortcutSummon) { newValue in
                        settings.shortcutSummon = newValue
                        // 全局热键要重新注册；菜单与按钮的快捷键由 SwiftUI 自动跟随
                        state.applyShortcutChange()
                    }
                }
                SettingsRow(title: "立即刷新索引") {
                    ShortcutRecorder(shortcut: settings.shortcutRefresh) { newValue in
                        settings.shortcutRefresh = newValue
                        state.applyShortcutChange()
                    }
                }
                SettingsRow(title: "在 Sketch 中打开所选文件") {
                    ShortcutRecorder(shortcut: settings.shortcutOpenInSketch) { newValue in
                        settings.shortcutOpenInSketch = newValue
                        state.applyShortcutChange()
                    }
                }
                HStack(spacing: 8) {
                    Button("恢复默认快捷键") {
                        settings.resetShortcuts()
                        state.applyShortcutChange()
                    }
                    .controlSize(.small)
                    Spacer()
                }
            } header: {
                Text("快捷键")
            }

            Section {
                SettingsRow(title: "开发者") {
                    Text("DACONG")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                SettingsRow(title: "许可") {
                    Text("MIT License")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("信息")
            }
        }
        .formStyle(.grouped)
    }
}
