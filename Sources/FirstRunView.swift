import AppKit
import SwiftUI

/// 首次启动的引导页：让用户亲手选一次要搜索的文件夹。
///
/// 为什么要这一步（而不是给个默认目录闷头索引）：
///   1. 别人的 .sketch 未必在 iCloud 云盘里，可能在文稿、移动硬盘或某个项目目录，
///      写死默认目录会让新用户"搜不到任何东西"却不知道为什么；
///   2. macOS 对 桌面 / 文稿 / 下载 这些位置有隐私保护，直接访问会被拦住。
///      而**通过 NSOpenPanel 选中的文件夹会自动获得授权**（系统的 powerbox 机制），
///      所以让用户亲手选一次，就不需要额外的权限弹窗，也不会出现"索引被权限挡住"的失败横幅。
struct FirstRunView: View {
    @EnvironmentObject var state: AppState

    /// 与主界面预览区底部按钮一致的高度（38）
    private static let barButtonHeight: CGFloat = 38

    /// 至少选了一个文件夹才能「开始使用」
    private var canFinish: Bool { !state.draftRoots.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            hint
            folderList

            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        chooseFolders()
                    } label: {
                        Label("选择文件夹", systemImage: "folder.badge.plus")
                            .font(.system(size: 13))
                            .padding(.horizontal, 14)
                            .frame(height: Self.barButtonHeight)
                            .glassSurface(Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    Button {
                        state.finishFolderSetup()
                    } label: {
                        Label("开始使用", systemImage: "checkmark")
                            .font(.system(size: 13, weight: .medium))
                            // 禁用时不着色、文字转灰 —— 这才是"不可用"的样子。
                            // 玻璃不吃 .opacity，光降透明度的话蓝色高亮仍在。
                            .foregroundStyle(canFinish ? Color.white : Color.secondary)
                            .padding(.horizontal, 16)
                            .frame(height: Self.barButtonHeight)
                            .glassSurface(Capsule(),
                                          tint: canFinish ? .orange : nil,
                                          interactive: canFinish)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canFinish)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var header: some View {
        // 图标 + 标题 + 副标题：三行整体居中，上下留白。
        // 关闭按钮用 ZStack 浮在右上角，不参与居中布局（否则会把整块挤偏）。
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 10) {
                AppLogoView(size: 64)
                Text("欢迎使用 SketchSearch")
                    .font(.title3.bold())
                Text("快速搜索 Sketch 文件中的画板页面并提供快速预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 12)

            // 右上角关闭：等同于原来的「稍后再说」，沿用已保存的目录并结束引导
            CloseButton { state.skipFolderSetup() }
                .padding(.top, -4)
                .padding(.trailing, -6)
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("请选择文件夹")
                .font(.headline)
            Text("添加存放 Sketch 文件的文件夹，SketchSearch 仅对文件夹中的 Sketch 文件进行画板解析，该功能不会破坏文件本体或进行其他破坏性操作")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 文件夹列表区的高度。**固定值**，不随条目数量变化 ——
    /// 否则空态 96pt、选了 1 个变 30pt、选 2 个变 60pt，弹窗会一直跳。
    /// 条目超过可视范围时在内部滚动。
    private static let listHeight: CGFloat = 96

    @ViewBuilder
    private var folderList: some View {
        Group {
            if state.draftRoots.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(.quaternary)
                    Text("请添加文件夹")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(state.draftRoots, id: \.self) { root in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text((root as NSString).abbreviatingWithTildeInPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Button {
                                    state.draftRoots.removeAll { $0 == root }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            if root != state.draftRoots.last {
                                Divider()
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.listHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 选择文件夹。用 NSOpenPanel 不只是图方便 —— 用户在这里选过的路径会被系统授予访问权限。
    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "加入搜索"
        panel.message = "选择包含 .sketch 文件的文件夹"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                if !state.draftRoots.contains(path) {
                    state.draftRoots.append(path)
                }
            }
        }
    }
}
