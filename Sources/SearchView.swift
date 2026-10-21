import AppKit
import SwiftUI

// MARK: - 浮动控件高度测量

private struct TopBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// 把自己的高度上报给外层，用于给内容区留出对应的内边距
    func measureBarHeight<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.height)
        })
    }
}

// MARK: - 拿到承载本视图的窗口（键盘监听需要判断事件是否来自主窗口）

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        retry(for: view, attempt: 0)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.callback(nsView.window) }
    }

    /// 视图刚创建时往往还没挂到窗口上，隔一段时间重试几次
    private func retry(for view: NSView, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.25)) {
            if let window = view.window {
                self.callback(window)
            } else if attempt < 8 {
                self.retry(for: view, attempt: attempt + 1)
            }
        }
    }
}

// MARK: - 原生搜索框
//
// 系统自带的 NSSearchField：放大镜图标、清除按钮、焦点环、以及 macOS 26 的液态玻璃外观
// 全部由系统绘制，比自己画一个输入框更对味。
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.focusRingType = .default
        // 加大一档控制尺寸 —— 搜索框会变高（系统自带的尺寸档位，不是自绘）
        field.controlSize = .large
        // 启动时自动聚焦搜索框（和之前的体验保持一致）
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

// MARK: - 高亮

private func highlighted(_ text: String, query: String, color: Color) -> AttributedString {
    let tokens = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return AttributedString(text) }

    let source = text as NSString
    var matched: [NSRange] = []
    var location = 0
    while location < source.length {
        var best = NSRange(location: NSNotFound, length: 0)
        for token in tokens {
            let searchRange = NSRange(location: location, length: source.length - location)
            let found = source.range(of: token, options: [.caseInsensitive], range: searchRange)
            if found.location != NSNotFound, best.location == NSNotFound || found.location < best.location {
                best = found
            }
        }
        guard best.location != NSNotFound else { break }
        matched.append(best)
        location = best.location + max(best.length, 1)
    }

    guard !matched.isEmpty else { return AttributedString(text) }

    var output = AttributedString()
    var cursor = 0
    for range in matched {
        if range.location > cursor {
            output.append(AttributedString(source.substring(with:
                NSRange(location: cursor, length: range.location - cursor))))
        }
        var piece = AttributedString(source.substring(with: range))
        piece.foregroundColor = color
        piece.inlinePresentationIntent = .stronglyEmphasized
        output.append(piece)
        cursor = range.location + range.length
    }
    if cursor < source.length {
        output.append(AttributedString(source.substring(from: cursor)))
    }
    return output
}

// MARK: - 单行结果

struct HitRow: View {
    let hit: SearchHit
    let query: String
    /// 列表已按文件分组时，文件名在分组表头里，行内不必再重复一遍
    var showFileSubtitle: Bool = true

    private var symbol: String {
        switch hit.kind {
        case .artboard: return "rectangle.on.rectangle"
        case .page: return "doc.on.doc"
        case .file: return "doc"
        }
    }

    private var subtitle: String {
        switch hit.kind {
        case .artboard:
            return showFileSubtitle ? hit.fileName : hit.pageName
        case .page:
            return showFileSubtitle ? hit.fileName : ""
        case .file:
            return (hit.fileDir as NSString).abbreviatingWithTildeInPath
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(hit.name, query: query, color: .orange))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if hit.kind == .artboard, !hit.pageName.isEmpty, showFileSubtitle {
                Text(hit.pageName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - 主界面

struct SearchView: View {
    /// 左栏固定宽度：写死才能保证搜索前后分栏线不动
    private static let sidebarWidth: CGFloat = 340

    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 用 NavigationSplitView 而不是自己拼 HStack：
        // 苹果为 macOS 26 重做过它，侧栏会"穿透"到窗口最顶（交通灯落在侧栏里），
        // 工具栏只覆盖右侧内容区 —— 这就是 Finder / 系统设置的结构，
        // 不会出现一条横贯全宽的分隔区。
        NavigationSplitView {
            sidebar
                // 宽度可以在 min~max 之间手动拖拽；ideal 固定，保证首次打开是设计宽度、
                // 也不会因为空状态/有结果而自己跳（之前锁死 min=ideal=max 就是为了修这个跳动，
                // 那样代价是拖不动，所以这里改成放开范围 + 固定 ideal）。
                .navigationSplitViewColumnWidth(min: 240,
                                                ideal: Self.sidebarWidth,
                                                max: 560)
        } detail: {
            detailPane
        }
        .toolbar { toolbarContent }
        // 工具栏背景保持透明：系统那层材质横跨整窗，会在左侧栏顶部留一条底色。
        // 通透的毛玻璃由预览区自己用 NSVisualEffectView 画（见 VisualEffectBackground）。
        .toolbarBackground(.hidden, for: .windowToolbar)
        .overlay(alignment: .top) { permissionOverlay }
        // 操作结果气泡（例如刷新成功），浮在内容之上、几秒后自动消失
        .overlay(alignment: .top) { toastOverlay }
        .frame(minWidth: 960, minHeight: 600)
        .background(WindowAccessor { window in state.setMainWindow(window) })
        // 首次启动的文件夹引导页
        .sheet(isPresented: $state.needsFolderSetup) {
            FirstRunView()
                .environmentObject(state)
        }
        .onPreferenceChange(TopBarHeightKey.self) { value in
            guard abs(value - state.topBarInset) > 0.5 else { return }
            state.topBarInset = value
        }
        // 输入搜索词 → 防抖后重跑搜索。
        // 这一条之前缺失（query 只是普通 @Published，没有 didSet，也没有 Combine 监听），
        // 结果就是只有启动时注入查询词那次会搜，手动输入完全搜不到。
        .onChange(of: state.query) { _, _ in
            state.queryChanged()
        }
        // 切换 tab（画板/页面/文件）同样要重跑 —— 筛选条件是在 SQL 里生效的
        .onChange(of: state.kindFilter) { _, _ in
            state.queryChanged()
        }
        .onAppear {
            state.openMainWindow = { openWindow(id: "main") }
        }
        .alert("提示", isPresented: Binding(
            get: { state.alertMessage != nil },
            set: { if !$0 { state.alertMessage = nil } }
        )) {
            Button("好") { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
    }

    /// 窗口工具栏：tab 组件在左、刷新 / 设置在右。
    /// 控件放进工具栏后，位置和间距由系统统一处理，不会再出现"顶到红绿灯那行"之类的问题。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            filterPicker
        }
        ToolbarItemGroup(placement: .primaryAction) {
            copyPathButton
            refreshButton
            settingsButton
        }
    }

    /// 左栏：顶部搜索框 + 结果列表。
    /// 顶部不再额外留交通灯的间距 —— NavigationSplitView 的侧栏已经延伸到窗口最顶，
    /// 系统会自动把内容排在工具栏（安全区）下方，交通灯本来就在那之上，不会重叠。
    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                // 加大一档控制尺寸：搜索框变高。
                // 必须用 SwiftUI 的 controlSize —— 它会通过环境覆盖 AppKit 侧设的值。
                .controlSize(.large)
                .padding(.horizontal, 12)
                .padding(.top, 8 + state.topBarInset)
                .padding(.bottom, 10)
            resultPane
        }
        // 初始空状态浮在**整个侧栏**上（而不是"搜索框以下"的区域）。
        // 这样它和右侧预览区的空状态都居中于各自面板，两边的图标/文字才能落在同一水平线。
        .overlay {
            if state.focusedFile == nil && state.query.isEmpty {
                sidebarEmptyState
            } else if state.focusedFile == nil && state.results.isEmpty && !state.query.isEmpty {
                sidebarNoResultState
            }
        }
    }

    /// 搜不到结果时的空状态。同样浮在整个侧栏上，位置和初始空状态一致。
    private var sidebarNoResultState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.quaternary)
            Text("没有找到「\(state.query)」")
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.3))
            Text("试试更短的关键词，或点击工具栏的刷新按钮更新索引")
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 26)
    }

    /// 左栏初始空状态。样式与右侧预览区的空状态严格一致：
    /// 图标 34pt、文字 .headline、间距 12、四周留白 26。

    private var sidebarEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 34))
                .foregroundStyle(.quaternary)
            Text("在你的 Sketch 文件里按画板名找图")
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 26)
    }

    /// 左栏顶部的搜索框：系统原生 NSSearchField（外观、图标、清除按钮、焦点环都由系统绘制）
    private var searchField: some View {
        NativeSearchField(text: $state.query, placeholder: "搜索画板名、页面名或文件名")
    }

    /// 右栏：预览区。
    /// 画板名和路径交给系统工具栏显示（navigationTitle / navigationSubtitle）——
    /// 这样材质和 SF Symbols 那种原生窗口工具栏完全一致，比自绘一个毛玻璃条通透得多。
    private var detailPane: some View {
        PreviewPane(topInset: state.topBarInset)
            .navigationTitle(previewTitle)
            .navigationSubtitle(previewSubtitle)
    }

    /// 工具栏标题：当前选中的画板名
    private var previewTitle: String {
        guard let hit = state.selection else { return "未选择" }
        return hit.name.isEmpty ? "（未命名）" : hit.name
    }

    /// 工具栏副标题：页面名 + 文件路径
    private var previewSubtitle: String {
        guard let hit = state.selection else { return "从左侧选择一条结果" }
        let page = (hit.kind == .artboard && !hit.pageName.isEmpty) ? "\(hit.pageName) · " : ""
        return page + hit.filePath
    }

    /// 工具栏里的"复制文件路径"按钮
    private var copyPathButton: some View {
        Button {
            state.copyPath(nil)
        } label: {
            Label("复制路径", systemImage: "doc.on.doc")
                .labelStyle(.iconOnly)
        }
        .disabled(state.selection == nil)
        .help("复制文件路径")
    }

    /// 刷新按钮：工具栏项自带玻璃底，所以这里**不要**再套 .glassButton()，
    /// 否则会叠成两层玻璃（看起来比旁边的 tab 多一层底）。
    private var refreshButton: some View {
        Button {
            state.refresh(force: false, announce: true)
        } label: {
            refreshLabel
        }
        .disabled(state.isIndexing)
        .help("增量更新索引并同步 Spotlight 关键词（⌘R）")
    }

    /// 设置按钮：同样交给工具栏自带的玻璃样式，只保留图标
    private var settingsButton: some View {
        SettingsLink {
            Label("设置", systemImage: "gearshape")
                .labelStyle(.iconOnly)
        }
        .help("打开设置")
    }

    /// 操作结果气泡：原生液态玻璃材质，浮在内容顶部居中，出现/消失有轻微动画。
    /// 两种语气共用同一个外形，只换图标和颜色：成功=绿对勾，提醒=橙色警告三角。
    /// 注意：不要在 glassSurface 之后再叠 .shadow —— 那会强制离屏渲染，
    /// 把玻璃材质压平，看起来就成了一块实心的白色胶囊。
    private var toastOverlay: some View {
        Group {
            if let text = state.toast {
                HStack(spacing: 7) {
                    Image(systemName: state.toastKind == .warning
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(state.toastKind == .warning ? Color.orange : Color.green)
                    Text(text)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(Capsule(), interactive: false)
                .padding(.top, state.topBarInset + 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.toast)
    }

    /// 权限提示做成浮动条；没显示时高度为 0，内容区不会多留白
    private var permissionOverlay: some View {
        Group {
            if state.permissionHintVisible {
                permissionBanner
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .measureBarHeight(TopBarHeightKey.self)
    }

    /// 刷新按钮的图标：索引进行中时，图标自己原地旋转。
    ///
    /// 这里千万不要用 ProgressView 去替换图标。工具栏项的内容和尺寸一变，
    /// macOS 26 就不再把刷新和右边的设置当成同一组，两者会拆成两个独立的玻璃胶囊
    /// （表现就是"刷新按钮和设置按钮分离"）。让同一个 Label 原地转，
    /// 视图类型和宽度全程不变，分组就稳了。
    @ViewBuilder
    private var refreshLabel: some View {
        if #available(macOS 15.0, *) {
            Label("刷新索引", systemImage: "arrow.clockwise")
                .labelStyle(.iconOnly)
                // speed 是 SymbolEffectOptions 上的实例方法，只能链式调用；
                // 默认转速偏慢，这里调到 8 倍
                .symbolEffect(.rotate, options: .repeat(.continuous).speed(8.0),
                              isActive: state.isIndexing)
        } else {
            Label("刷新索引", systemImage: "arrow.clockwise")
                .labelStyle(.iconOnly)
        }
    }

    /// 筛选器：macOS 27 的 `.pickerStyle(.tabs)` —— 系统原生 tab 组件，放进窗口工具栏。
    ///
    /// 试过 TabView 本体：它的 tab 栏需要真实的 tab 内容，空内容时在工具栏里什么都不显示；
    /// 内嵌在内容区又因为固有宽度为 0 而无法定位。`.tabs` 是同一个玻璃 tab 外观、
    /// 但可以放进工具栏由系统摆位的原生控件。
    @ViewBuilder
    private var filterPicker: some View {
        if #available(macOS 27.0, *) {
            Picker("筛选", selection: $state.kindFilter) {
                ForEach(KindFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.tabs)
            .labelsHidden()
        } else {
            Picker("筛选", selection: $state.kindFilter) {
                ForEach(KindFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("索引似乎被系统权限挡住了")
                    .font(.callout.weight(.medium))
                Text("点「重新授权」选中要搜索的文件夹，系统会直接把访问权交给应用，"
                     + "不需要去系统设置里手动添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("重新授权…") { state.reauthorize() }
                .glassButton()
            Button("重试") { state.forceRetryIndex() }
                .glassButton(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: .orange)
        .padding(.horizontal, 16)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private var resultPane: some View {
        if state.focusedFile != nil {
            focusedFilePane
        } else if state.results.isEmpty && !state.query.isEmpty {
            // 由 sidebar 的 overlay 统一绘制（见 sidebarNoResultState）
            Color.clear
        } else if state.query.isEmpty {
            // 初始空状态由 sidebar 的 overlay 统一绘制（见 sidebarEmptyState）
            Color.clear
        } else {
            ScrollViewReader { proxy in
                List(selection: $state.selection) {
                    // 按文件分组，组与组之间按文件修改时间倒序（最近改过的在最上面）。
                    // 表头做成"普通行"而不是 Section 的 header —— macOS 会把 Section header
                    // 钉在列表顶部，而这里要的是它跟着列表一起滚走。
                    ForEach(state.resultGroups) { group in
                        fileGroupHeader(group)
                            .listRowSeparator(.hidden)
                        ForEach(group.hits) { hit in
                            HitRow(hit: hit, query: state.query, showFileSubtitle: false)
                                .tag(hit)
                                .id(hit.id)
                                // 行与行之间不要分割线，只保留分组表头下方那条
                                .listRowSeparator(.hidden)
                                .contextMenu {
                                    Button("在 Sketch 中打开") { state.openInSketch(hit) }
                                    Button("在 Finder 中显示") { state.revealInFinder(hit) }
                                    Button("复制文件路径") { state.copyPath(hit) }
                                    Divider()
                                    Button("查看该文件全部画板") { state.showArtboardsInFocusedFile(hit) }
                                }
                        }
                    }
                }
                .listStyle(.inset)
                // 去掉列表自带的不透明底色，让 NavigationSplitView 侧栏的磨砂玻璃透上来
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 36)
                // 留出浮动搜索栏/状态栏的位置：静止时不遮挡，滚动时从玻璃下面经过
                .contentMargins(.top, state.topBarInset, for: .scrollContent)
                // 用方向键切换时把选中项滚进可视区域
                .onChange(of: state.selection) { _, newValue in
                    guard let hit = newValue else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(hit.id, anchor: nil)
                    }
                }
            }
        }
    }

    /// 文件分组的表头：文件封面 + 文件名 + 该文件的最近修改时间。
    /// 行分隔线被隐藏了（行与行之间不要线），所以这里自己画一条，
    /// 保证"文件名下方"始终有一条分割线把分组和内容分开。
    private func fileGroupHeader(_ group: FileGroup) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                fileCover(group)
                Text(group.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Self.relativeTime(group.fileMTime))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, 2)
            Divider()
        }
        // 与上一个分组的最后一行拉开距离，否则分组挨得太紧、看不出层次
        .padding(.top, 26)
    }

    /// 文件封面图：用 Sketch 自带 QuickLook 扩展生成的缩略图；还没生成好就先放占位图标
    @ViewBuilder
    private func fileCover(_ group: FileGroup) -> some View {
        if let cover = state.fileCovers[group.filePath] {
            Image(nsImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        } else {
            Image(systemName: "doc")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    private static func relativeTime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        return relativeFormatter.localizedString(for: Date(timeIntervalSince1970: seconds),
                                                 relativeTo: Date())
    }

    private var focusedFilePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    state.focusedFile = nil
                    state.focusedFileArtboards = []
                } label: {
                    Label("返回搜索结果", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                Spacer()
                Text("\(state.focusedFileArtboards.count) 个画板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $state.selection) {
                    ForEach(state.focusedFileArtboards) { hit in
                        HitRow(hit: hit, query: "")
                            .tag(hit)
                            .id(hit.id)
                    }
                }
                .listStyle(.inset)
                // 去掉列表自带的不透明底色，让 NavigationSplitView 侧栏的磨砂玻璃透上来
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 36)
                .contentMargins(.top, state.topBarInset, for: .scrollContent)
                .onChange(of: state.selection) { _, newValue in
                    guard let hit = newValue else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(hit.id, anchor: nil)
                    }
                }
            }
        }
    }
}

// MARK: - 右侧预览

struct PreviewPane: View {
    @EnvironmentObject var state: AppState
    var topInset: CGFloat = 0

    /// 底部两个按钮的高度，与工具栏里那个分段筛选控件（系统 .regular 尺寸，24pt）保持一致
    private static let barButtonHeight: CGFloat = 38

    /// 适配窗口时要在底部让出的空间（按钮栏高度 + 上下留白）。
    /// 让出来的只有"适配尺寸"：放大走的是 scaleEffect，不影响布局，
    /// 所以放大之后画板仍然可以延伸到按钮下方。
    private static let bottomBarInset: CGFloat = barButtonHeight + 22

    /// 有选中结果时按钮才可用
    private var hasSelection: Bool { state.selection != nil }

    /// 「在 Sketch 中打开」的快捷键（用户可在设置里改）
    private var openShortcut: Shortcut { state.settings.shortcutOpenInSketch }

    var body: some View {
        // 画布一直铺到窗口最顶（含工具栏下方）；顶部压一条系统原生毛玻璃，
        // 画布放大时会被它模糊透出 —— 和 Finder / SF Symbols 的工具栏一个原理。
        stage
            .overlay(alignment: .top) {
                // 毛玻璃条只在"画布真的伸到工具栏下方"时才出现，也就是放大之后。
                // 空状态 / 100% 适配时下方没有内容可模糊，材质自带的色调反而会和画布形成
                // 一条色差带（深色模式实测：条 #212528 vs 画布 #1E1E1E）。
                if state.thumbnail != nil && state.previewZoom > 1.0 {
                    VisualEffectBackground(material: .headerView, blending: .withinWindow)
                        .frame(height: state.toolbarHeight)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) { actions }
            // 忽略顶部安全区，画布才能真正延伸到工具栏下方
            .ignoresSafeArea(.container, edges: .top)
            // 避开浮动在最上方的权限提示条；预览面板不滚动，直接留白即可
            .padding(.top, topInset)
    }


    private var stage: some View {
        ZStack {
            // 预览区底色用纯白（原来是 underPageBackgroundColor 的浅灰）
            // 画布底色跟随系统外观：浅色模式是纯白，深色模式变深。
            // 写死 Color.white 会让深色模式下"白底 + 自适应浅色图标"= 图标看不见。
            Color(nsColor: .textBackgroundColor)
            if let image = state.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 18)
                    // 顶部让开工具栏高度：100% 适配时画板不会藏到毛玻璃条下面
                    .padding(.top, 18 + state.toolbarHeight)
                    .padding(.bottom, 18 + Self.bottomBarInset)
                    .scaleEffect(state.previewZoom)
                    .offset(state.previewOffset)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            } else if state.isLoadingThumbnail {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(state.thumbnailMessage ?? "正在导出…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                // 居中基准让开工具栏：与左栏空状态落在同一水平线。
                // 用 toolbarHeight 而不是 topInset —— 实测 topBarInset 恒为 0（它量的是另一回事）
                .padding(.top, state.toolbarHeight)
            } else {
                // 样式与左栏空状态严格一致（图标 34pt / .headline / 间距 12）
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 34))
                        .foregroundStyle(.quaternary)
                    Text(state.thumbnailMessage ?? "选中一个画板即可预览缩略图")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.3))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                }
                // 居中基准让开工具栏：与左栏空状态落在同一水平线。
                // 用 toolbarHeight 而不是 topInset —— 实测 topBarInset 恒为 0（它量的是另一回事）
                .padding(.top, state.toolbarHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 手势绑在整个画布上（而不是只绑在图里），这样放大后边缘区域也能继续操作
        .contentShape(Rectangle())
        .gesture(previewMagnifyGesture)
        .simultaneousGesture(previewDragGesture)
        .clipped()
        .overlay(alignment: .topTrailing) { zoomControl }
    }

    /// 触控板双指捏合缩放
    private var previewMagnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                state.updatePreviewPinch(magnification: value.magnification)
            }
            .onEnded { _ in state.endPreviewPinch() }
    }

    /// 鼠标 / 触控板拖动平移（只在放大后生效，适应窗口时拖了也没意义）
    private var previewDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard state.previewZoom > 1 else { return }
                state.updatePreviewDrag(translation: value.translation)
            }
            .onEnded { _ in state.endPreviewDrag() }
    }

    /// 画布右上角的缩放控件：上面一组是放大/缩小，下面单独一个恢复按钮
    private var zoomControl: some View {
        VStack(spacing: 9) {
            VStack(spacing: 2) {
                Button {
                    state.zoomInPreview()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("放大")

                Button {
                    state.zoomOutPreview()
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("缩小")
            }
            .padding(6)
            .glassSurface(Capsule(), interactive: true)

            Button {
                state.resetPreviewZoom()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("恢复初始大小")
            .padding(6)
            .glassSurface(Capsule(), interactive: true)
        }
        // 顶部让开工具栏高度，否则缩放控件会被毛玻璃条盖住
        .padding(.horizontal, 14)
        .padding(.top, 14 + state.toolbarHeight)
        .padding(.bottom, 14)
    }

    private var actions: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                // 两个"拷贝"按钮只对画板有意义（页面/文件没有画板图可拷），
                // 所以只在「画板」这一栏显示。
                // 注意：**不能按选中项判断** —— 否则用户刚打开软件（还没选中任何结果）
                // 就看不到这两个功能，会以为没有。
                if state.kindFilter == .artboard {
                    // 左侧：拷贝预览图（3x 高清）。样式与「在 Finder 中显示」完全一致。
                    Button {
                        state.copyPreviewImage()
                    } label: {
                        Label("拷贝预览图", systemImage: "photo")
                            .font(.system(size: 13))
                            .foregroundStyle(hasSelection ? Color.primary : Color.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: Self.barButtonHeight)
                            .glassSurface(Capsule(), interactive: hasSelection)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.selection == nil)
                    .opacity(state.selection == nil ? 0.45 : 1)
                    .help("拷贝所选画板的 3x 高清图到剪贴板")

                    // 拷贝矢量画板：粘到别的 Sketch 文件里是可编辑的原生图层。
                    Button {
                        state.copyVectorArtboard()
                    } label: {
                        Label("拷贝矢量画板", systemImage: "skew")
                            .font(.system(size: 13))
                            .foregroundStyle(hasSelection ? Color.primary : Color.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: Self.barButtonHeight)
                            .glassSurface(Capsule(), interactive: hasSelection)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.selection == nil)
                    .opacity(state.selection == nil ? 0.45 : 1)
                    .help("拷贝画板的原始矢量数据（Sketch 原生格式），粘到 Sketch 里可直接编辑")
                }

                // 复制路径已移到顶部路径行的最右边（图标形式），这里不再重复
                Spacer(minLength: 8)

                // 右侧两个按钮：Finder 在左、Sketch 在右。
                // 必须自绘胶囊：系统玻璃按钮样式的高度由 controlSize 决定
                // （regular≈33pt / large≈29pt / small≈20pt），无法精确对齐工具栏里
                // 那个分段控件的高度（实测 38pt）。自绘才能保证两者严格等高。
                Button {
                    state.revealInFinder(nil)
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(hasSelection ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: Self.barButtonHeight)
                        .glassSurface(Capsule(), interactive: hasSelection)
                }
                .buttonStyle(.plain)
                .disabled(state.selection == nil)
                .opacity(state.selection == nil ? 0.45 : 1)

                Button {
                    state.openInSketch(nil)
                } label: {
                    Label("在 Sketch 中打开", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 13, weight: .medium))
                        // 禁用时不着强调色、文字转灰 —— 玻璃不吃 .opacity，
                        // 只降透明度的话蓝色高亮还在，看着仍然"能点"
                        .foregroundStyle(hasSelection ? Color.white : Color.secondary)
                        .padding(.horizontal, 16)
                        .frame(height: Self.barButtonHeight)
                        // 原生液态玻璃 + 强调色着色（等价于系统的 .glassProminent，
                        // 但高度由我们自己锁定，才能和工具栏的分段控件严格等高）
                        .glassSurface(Capsule(),
                                      tint: hasSelection ? .orange : nil,
                                      interactive: hasSelection)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(openShortcut.keyEquivalent ?? .return,
                                  modifiers: openShortcut.eventModifiers)
                .disabled(state.selection == nil)
                .opacity(state.selection == nil ? 0.45 : 1)
                .help("用 Sketch 打开所选文件（⌘↩）")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }
}
