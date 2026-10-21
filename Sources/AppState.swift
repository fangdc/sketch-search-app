import AppKit
import Carbon
import Combine
import Foundation
import QuickLookThumbnailing
import SwiftUI

enum KindFilter: String, CaseIterable {
    case artboard, page, file

    var title: String {
        switch self {
        case .artboard: return "画板"
        case .page: return "页面"
        case .file: return "文件"
        }
    }
}

/// 应用的核心状态与业务编排：索引、自动刷新、搜索、缩略图、Spotlight 同步。
final class AppState: ObservableObject {

    @Published var query = ""
    @Published var results = SearchResults()
    @Published var selection: SearchHit?
    @Published var kindFilter: KindFilter = .artboard

    /// 标题栏 + 工具栏占的高度（供预览区把毛玻璃条对准工具栏下方）
    @Published var toolbarHeight: CGFloat = 52
    /// 首次启动的引导页是否需要弹出
    @Published var needsFolderSetup = false
    /// 引导页里"待确认"的文件夹列表（用户点「开始使用」才会写进设置）
    @Published var draftRoots: [String] = []

    @Published var stats = IndexStats()
    @Published var isIndexing = false
    @Published var indexProgress: (done: Int, total: Int)?
    @Published var lastRefresh: Date?
    @Published var spotlightSummary: String?

    /// 气泡提示的两种语气：成功（绿对勾）/ 提醒（橙色警告三角）。
    /// 所有提示统一走气泡，不再有常驻的行内状态行。
    enum ToastKind {
        case success
        case warning
    }

    /// 短暂的"气泡"提示，几秒后自动消失（例如：手动刷新成功）
    /// 缩略图缓存占用字节数（设置页显示用）
    @Published var thumbnailCacheBytes: Int64 = 0

    @Published var toast: String?
    /// 当前气泡的语气
    @Published var toastKind: ToastKind = .success
    /// 每次弹气泡自增，用来让旧计时器失效，避免它把新气泡提前关掉
    private var toastToken = 0

    /// 文件封面图（Key = 文件路径）。用 Sketch 自带的 QuickLook 缩略图扩展生成，
    /// 生成是异步的，没好之前列表先显示占位图标。
    @Published var fileCovers: [String: NSImage] = [:]
    private var coverRequests: Set<String> = []
    private let coverQueue = DispatchQueue(label: "com.sksearch.covers", qos: .utility)
    /// 一次最多为多少个文件请求封面，避免结果很多时把 QuickLook 扩展打爆
    private let maxCoverRequests = 30

    /// 浮动权限提示条的实测高度，内容区按它留内边距
    @Published var topBarInset: CGFloat = 0

    @Published var thumbnail: NSImage?
    @Published var thumbnailMessage: String?
    @Published var isLoadingThumbnail = false

    // MARK: - 预览缩放 / 拖动
    //
    // 本项目不能用 @State（SwiftUI 的 StateMacro 在当前工具链下会崩），
    // 所以缩放和偏移都放在这里，由视图读写。

    /// 1.0 = 适应画布；>1 放大，<1 缩小
    @Published var previewZoom: CGFloat = 1
    /// 放大后拖动产生的位移
    @Published var previewOffset: CGSize = .zero

    static let minPreviewZoom: CGFloat = 0.2
    static let maxPreviewZoom: CGFloat = 8

    /// 解析失败占比超过这个值才提示"部分文件解析失败"（10%）。
    /// 低于它就不打扰用户 —— 个别文件解析不了不影响搜索这个核心用途。
    static let parseFailureWarningRatio = 0.1

    private var zoomAtGestureStart: CGFloat?
    private var offsetAtDragStart: CGSize?

    @Published var focusedFile: SearchHit?
    @Published var focusedFileArtboards: [SearchHit] = []

    @Published var alertMessage: String?
    @Published var spotlightHintVisible = false

    /// 首次运行时如果索引长时间没有进展，多半是被系统隐私授权挡住了
    @Published var permissionHintVisible = false

    let settings: AppSettings
    private var database: Database?
    private let workQueue = DispatchQueue(label: "com.sksearch.work", qos: .utility)
    /// 预览导出 / 拷贝用的独立队列。
    /// **不能和索引共用一个串行队列** —— 外接硬盘读取慢时索引会卡住几十秒，
    /// 排在它后面的缩略图导出一并卡住，界面上就是"一直转圈加载不出来"。
    private let previewQueue = DispatchQueue(label: "com.sksearch.preview", qos: .userInitiated)
    /// 缩略图后台预热用的串行队列（低优先级，不抢前台预览的 CPU）
    private let prewarmQueue = DispatchQueue(label: "com.sksearch.prewarm", qos: .utility)
    /// 结果一变就自增，让上一轮预热尽早收手
    private var prewarmGeneration = 0
    /// 待执行的预热任务（连续输入时只保留最后一次）
    private var prewarmSchedule: DispatchWorkItem?
    /// 缩略图后台预热：首批预热多少个结果
    private let prewarmInitialCount = 25
    /// 顺序浏览时每批补多少个
    private let prewarmBatchSize = 20
    /// 距离窗口末尾还剩几个时触发下一批（25 个的窗口 → 看到第 20 个就补）
    private let prewarmAhead = 6
    /// 当前预热窗口：[start, end)。仅主线程访问。
    private var prewarmWindowStart = 0
    private var prewarmWindowEnd = 0
    private let stateLock = NSLock()
    private var pendingThumbnailID: String?
    private var refreshTimer: Timer?
    private var searchDebounce: DispatchWorkItem?
    private var thumbnailWork: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var fullScreenObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private(set) var hotKey: GlobalHotKey?
    private var started = false
    var openMainWindow: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    /// 最后一次「索引确实在动」的时间。遍历和解析都会刷新它；
    /// 看门狗只在它超过 25 秒没更新时才提示权限问题 ——
    /// 否则冷启动时（iCloud 文件要先下载，光遍历就可能超过 25 秒）会误报。
    private var lastIndexActivity = Date()


    /// 当前实例。AppDelegate 在「点 Dock 图标 / 重新打开」时拿它把窗口叫回来
    /// （AppDelegate 由 @NSApplicationDelegateAdaptor 创建，拿不到 SwiftUI 的 state）。
    static weak var current: AppState?
    weak var mainWindow: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings

        // 缩略图加载统一由 selection 的变化驱动。
        // List(selection:) 是直接写这个属性的，不会走 select()，所以必须在这里订阅，
        // 否则「点列表 / 方向键切换」都不会更新右侧预览图。
        $selection
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hit in
                guard let self = self else { return }
                if let hit = hit {
                    self.loadThumbnail(for: hit)
                    // 换了一张图，缩放和位移都要归位，否则会停在上一次的放大状态
                    self.resetPreviewZoom()
                    // 浏览到接近已预热范围末尾时，自动再补一批
                    self.handlePrewarm(for: hit)
                } else {
                    self.clearThumbnail()
                }
            }
            .store(in: &cancellables)
        AppState.current = self
    }

    deinit {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        for observer in fullScreenObservers { NotificationCenter.default.removeObserver(observer) }
        if let observer = activationObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        // 清掉上次异常退出可能残留的"拷贝预览图"临时目录，避免堆积
        let stale = Thumbnailer.cleanStaleCopyTemporaries()
        if stale > 0 { Log.write("已清理 \(stale) 个残留的拷贝临时目录") }
        // 矢量画板的临时文件要给 Sketch 留出读取时间，所以只清一小时前的
        SketchClipboard.cleanStaleTemporaries()
        do {
            database = try Database(path: AppSettings.databaseURL.path)
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.write("数据库打开失败：\(error)")
            return
        }

        Log.write("应用启动｜索引目录=\(settings.roots.joined(separator: ", "))｜数据库=\(AppSettings.databaseURL.path)")
        Log.write("Sketch 安装=\(Thumbnailer.isSketchInstalled())｜自动刷新=\(settings.autoRefreshEnabled)｜间隔=\(settings.refreshIntervalMinutes)分｜Spotlight同步=\(settings.spotlightSyncEnabled)")

        loadStats()
        installHotKey()
        observeActivation()

        // 首次启动：先弹引导页让用户自己选文件夹（不预选任何目录）。
        // 这样既避免"默认目录里没有他的文件"的困惑，也让选中的文件夹顺带拿到系统授权。
        if !settings.firstRunDone {
            needsFolderSetup = true
        }

        if settings.autoRefreshEnabled {
            scheduleTimer()
        }

        // 首次启动或索引为空时立刻建索引，否则用后台刷新补齐增量
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let existing = self.database?.stats().files ?? 0
            self.refresh(force: false, reason: existing == 0 ? "首次建立索引" : nil)
        }
    }

    private func installHotKey() {
        let shortcut = settings.shortcutSummon
        // 赋值会释放旧的 GlobalHotKey，它的 deinit 里会 UnregisterEventHotKey
        hotKey = GlobalHotKey(keyCode: UInt32(shortcut.keyCode),
                              modifiers: shortcut.carbonModifiers) { [weak self] in
            self?.showMainWindow()
        }
    }

    /// 用户在设置里改了快捷键后调用：重新注册全局热键
    func applyShortcutChange() {
        installHotKey()
        Log.write("快捷键已更新｜唤起=\(settings.shortcutSummon.display)"
                  + " 刷新=\(settings.shortcutRefresh.display)"
                  + " 打开=\(settings.shortcutOpenInSketch.display)")
    }

    private func observeActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // 每次激活都顺手清一遍窗口装饰：SwiftUI 会在我们重试窗口结束之后才把
            // "显示/隐藏侧栏"按钮加回来，所以只靠启动时那几次重试是抓不住的。
            if let window = self.mainWindow { self.cleanupWindowChrome(of: window) }
            guard self.settings.autoRefreshEnabled, !self.isIndexing else { return }
            if let last = self.lastRefresh, Date().timeIntervalSince(last) < 120 { return }
            self.refresh(force: false, reason: nil)
        }
    }

    func showMainWindow() {
        // 之前关窗时切成了 .accessory（无程序坞图标），重新打开就切回来
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    // MARK: - 自动刷新

    func scheduleTimer() {
        refreshTimer?.invalidate()
        guard settings.autoRefreshEnabled else {
            refreshTimer = nil
            return
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: settings.refreshIntervalSeconds,
                                            repeats: true) { [weak self] _ in
            self?.refresh(force: false, reason: nil)
        }
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func applyAutoRefreshSetting() {
        scheduleTimer()
    }

    /// 索引 + （可选）Spotlight 关键词同步
    /// - Parameter announce: 用户主动点刷新时传 true，结束后弹气泡；自动刷新不要弹，否则会打扰。
    func refresh(force: Bool, reason: String? = nil, announce: Bool = false) {
        // 一个索引目录都没有：说明新装还没选过，或用户把目录全删了。
        // 这时候不要扫描 —— 扫描会得到 0 个文件，反而弹出「需要授权」的假警报。
        guard !settings.roots.isEmpty else {
            Log.write("跳过索引：还没有选择任何索引目录")
            return
        }
        guard !isIndexing else { return }
        if let reason = reason { Log.write("刷新原因：\(reason)") }
        DispatchQueue.main.async {
            self.isIndexing = true
            self.permissionHintVisible = false
        }
        startPermissionWatchdog()

        workQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                // 后台索引用独立的数据库连接：WAL 模式下读写不互相阻塞
                let writer = try Database(path: AppSettings.databaseURL.path)
                let result = try Indexer.run(
                    database: writer,
                    roots: self.settings.roots,
                    excludeDirs: self.settings.excludedDirectories,
                    force: force,
                    jobs: 8,
                    progress: { done, total in
                        self.stateLock.lock()
                        self.lastIndexActivity = Date()
                        self.stateLock.unlock()
                        DispatchQueue.main.async { self.indexProgress = (done, total) }
                    },
                    // 遍历阶段也报活：否则 25 秒的看门狗会把「慢慢下载 iCloud 文件」
                    // 误判成「被权限拦住」
                    activity: { [weak self] in
                        self?.stateLock.lock()
                        self?.lastIndexActivity = Date()
                        self?.stateLock.unlock()
                    })

                Log.write("索引结果：扫描=\(result.scanned) 更新=\(result.updated) 移除=\(result.removed) 解析失败=\(result.failed) 用时=\(String(format: "%.2f", result.seconds))s")

                // 只有需要用户处理的问题才往状态栏上写；一切正常时状态栏只显示索引新鲜度
                var warning: String?

                if result.scanned == 0 {
                    Log.write("本次扫描没有找到任何 .sketch")
                } else {
                    // 解析失败只在"占比明显偏高"时给个模糊提示。
                    // 这个工具本身是辅助搜索，个别文件解析不了完全不影响使用，
                    // 报出具体数字（"3 个文件解析失败"）只会制造焦虑。
                    // 具体数量仍然写进日志，排查时能看到。
                    let ratio = result.scanned > 0 ? Double(result.failed) / Double(result.scanned) : 0
                    if ratio >= Self.parseFailureWarningRatio {
                        warning = "部分文件解析失败"
                    }
                }

                if self.settings.spotlightSyncEnabled {
                    let report = Spotlight.apply(database: writer,
                                                 maxCount: self.settings.maxKeywords,
                                                 maxBytes: self.settings.maxKeywordBytes)
                    Log.write("Spotlight 同步：候选=\(report.considered) 新写入=\(report.changed) 跳过=\(report.skipped) 失败=\(report.failed) 权限拒绝=\(report.permissionDenied) 截断文件=\(report.truncated.count) 关键词=\(report.keywords)")
                    // 注意：关键词被截断是永久性的已知限制，不是"需要用户处理"的问题，
                    // 所以只写进设置页的说明，不占用状态栏 —— 否则状态栏会永远挂着一条警告
                    if report.permissionDenied > 0 {
                        warning = "需要允许访问 iCloud 云盘，才能同步到聚焦搜索"
                    }
                    DispatchQueue.main.async {
                        self.spotlightHintVisible = report.permissionDenied > 0
                        if report.permissionDenied > 0 {
                            self.spotlightSummary = "有 \(report.permissionDenied) 个文件的画板名写入被系统拒绝，"
                                + "请在「系统设置 → 隐私与安全性 → 文件与文件夹」中允许本应用访问 iCloud 云盘"
                        } else if !report.truncated.isEmpty {
                            self.spotlightSummary = "\(report.truncated.count) 个文件画板过多，"
                                + "超出 Spotlight 关键词容量上限，超出部分只能在本地搜索里搜到"
                        } else {
                            self.spotlightSummary = nil
                        }
                    }
                }

                DispatchQueue.main.async {
                    self.lastRefresh = Date()
                    if let warning = warning {
                        self.showWarning(warning)
                    }
                    self.indexProgress = nil
                    self.isIndexing = false
                    // 索引跑完了，之前那条「被权限拦住」的提示就不成立了
                    self.permissionHintVisible = false
                    self.loadStats()
                    if self.settings.firstRunDone == false {
                        self.settings.firstRunDone = true
                    }
                    // 后台刷新结束后重跑搜索刷新结果，但要保住用户当前的选中项
                    self.runSearchNow(preserveSelection: true)
                    // 只有用户主动刷新才弹气泡；自动刷新弹会打扰人
                    if announce && warning == nil {
                        self.showToast("索引已更新")
                    }
                }
            } catch {
                Log.write("索引异常：\(error)")
                DispatchQueue.main.async {
                    self.isIndexing = false
                    self.indexProgress = nil
                    self.showWarning("索引失败，点刷新重试")
                    self.alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    func loadStats() {
        guard let database = database else { return }
        let value = database.stats()
        DispatchQueue.main.async { self.stats = value }
    }

    /// 弹一个几秒后自动消失的气泡提示
    func showToast(_ text: String, kind: ToastKind = .success, seconds: Double = 2.5) {
        toastToken &+= 1
        let token = toastToken
        toastKind = kind
        toast = text
        Log.write("[气泡] \(kind == .warning ? "警告" : "成功")｜\(text)｜\(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.toastToken == token else { return }
            self.toast = nil
        }
    }

    /// 提醒类气泡的便捷入口（橙色警告三角）
    func showWarning(_ text: String, seconds: Double = 3.5) {
        showToast(text, kind: .warning, seconds: seconds)
    }

    // MARK: - 预览缩放 / 拖动

    /// 缩到"适应画布"或更小时把位移回正 —— 否则图会停在画布外，看着像图丢了
    func setPreviewZoom(_ value: CGFloat) {
        previewZoom = min(max(value, Self.minPreviewZoom), Self.maxPreviewZoom)
        if previewZoom <= 1 { previewOffset = .zero }
    }

    func zoomInPreview() { setPreviewZoom(previewZoom * 1.25) }
    func zoomOutPreview() { setPreviewZoom(previewZoom / 1.25) }

    func resetPreviewZoom() {
        previewZoom = 1
        previewOffset = .zero
        zoomAtGestureStart = nil
        offsetAtDragStart = nil
    }

    /// 触控板双指捏合。magnification 是相对手势起点的倍数，
    /// 所以要在第一次回调时把当时的缩放记下来当基准。
    func updatePreviewPinch(magnification: CGFloat) {
        if zoomAtGestureStart == nil { zoomAtGestureStart = previewZoom }
        setPreviewZoom((zoomAtGestureStart ?? previewZoom) * magnification)
    }

    func endPreviewPinch() {
        zoomAtGestureStart = nil
    }

    /// 鼠标 / 触控板拖动平移
    func updatePreviewDrag(translation: CGSize) {
        if offsetAtDragStart == nil { offsetAtDragStart = previewOffset }
        let base = offsetAtDragStart ?? .zero
        previewOffset = CGSize(width: base.width + translation.width,
                               height: base.height + translation.height)
    }

    func endPreviewDrag() {
        offsetAtDragStart = nil
    }

    /// 为这些文件准备封面图（已有的跳过，正在请求的跳过）。
    /// 走 Sketch 自带的 QuickLook 缩略图扩展，异步生成、结果缓存下来。
    func ensureFileCovers(for paths: [String]) {
        var pending: [String] = []
        for path in paths {
            if fileCovers[path] != nil { continue }
            if coverRequests.contains(path) { continue }
            pending.append(path)
            if pending.count >= maxCoverRequests { break }
        }
        guard !pending.isEmpty else { return }
        for path in pending { coverRequests.insert(path) }

        for path in pending {
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path),
                size: CGSize(width: 44, height: 44),
                scale: 2,
                representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                let image = rep?.nsImage
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.coverRequests.remove(path)
                    if let image = image {
                        self.fileCovers[path] = image
                    }
                }
            }
        }
    }

    /// 正常情况下索引几百个文件只要一两秒。若 25 秒仍无任何进度，
    /// 基本可以断定是 macOS 的「文件与文件夹 / iCloud 云盘」授权弹窗在等待用户确认。
    private func startPermissionWatchdog() {
        // 索引开始时把活动时间归零，避免拿到上一次索引留下的旧值
        stateLock.lock()
        lastIndexActivity = Date()
        stateLock.unlock()

        // 每 5 秒复查一次：只有「确实在索引、且连续 25 秒没有任何进度」才提示。
        // 原来的做法是「启动后 25 秒时 indexProgress 仍为 nil」——
        // 冷启动时遍历 iCloud 目录就可能超过 25 秒（文件还要现下载），于是误报。
        for tick in 1...24 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(tick) * 5) { [weak self] in
                guard let self = self, self.isIndexing, !self.permissionHintVisible else { return }
                self.stateLock.lock()
                let idle = Date().timeIntervalSince(self.lastIndexActivity)
                self.stateLock.unlock()
                guard idle >= 25 else { return }
                self.permissionHintVisible = true
                self.showWarning("索引被系统权限拦住，需要允许访问文件所在位置")
                Log.write("看门狗：索引已 \(Int(idle)) 秒无任何进展，提示用户检查隐私授权")
            }
        }
    }

    /// 刚加入的目录里有没有 .sketch —— 没有就立刻告知。
    ///
    /// 不能等「下一次索引扫描完成后」再判断：如果此时已经有扫描在跑，
    /// 新目录不会触发新扫描，就永远等不到结论（实测就是不弹）。
    /// 这里直接对刚加的目录做一次快速遍历，几百个文件只要几毫秒。
    func checkNewRoots(_ paths: [String]) {
        let empty = paths.filter { path in
            Indexer.sketchFiles(roots: [path],
                                excludeDirs: settings.excludedDirectories).files.isEmpty
        }
        guard !empty.isEmpty else { return }
        Log.write("新加的目录里没有 .sketch：\(empty.joined(separator: ", "))")
        alertMessage = "该文件夹中没有找到 Sketch 文件"
    }

    /// 主动向系统要权限：重新选一次文件夹。
    /// macOS 没有「申请访问某目录」的 API，但通过 NSOpenPanel 选中的目录会被
    /// powerbox 直接授权 —— 让用户点一下选文件夹，比引导他去系统设置快得多。
    func reauthorize() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "授权"
        panel.message = "选中要搜索的文件夹即可授予访问权限"
        if let first = settings.roots.first {
            panel.directoryURL = URL(fileURLWithPath: first)
        }
        if panel.runModal() == .OK {
            var added: [String] = []
            for url in panel.urls where !settings.roots.contains(url.path) {
                settings.roots.append(url.path)
                added.append(url.path)
            }
            checkNewRoots(added)
            forceRetryIndex()
        }
    }


    /// 权限弹窗挂住时，原来那条索引线程可能仍然阻塞着；这里强行把状态复位再重试
    func forceRetryIndex() {
        isIndexing = false
        indexProgress = nil
        permissionHintVisible = false
        refresh(force: false, reason: "正在重新尝试索引…", announce: true)
    }

    // MARK: - 首次启动的文件夹引导

    /// 引导页点「开始使用」：把草稿写入设置，然后立刻建索引
    func finishFolderSetup() {
        guard !draftRoots.isEmpty else { return }
        settings.roots = draftRoots
        settings.firstRunDone = true
        needsFolderSetup = false
        Log.write("首次引导完成｜索引目录=\(draftRoots.joined(separator: ", "))")
        checkNewRoots(draftRoots)
        rebuildIndex()
    }

    /// 引导页点「稍后再说」：这次不再打扰，用户可以之后在设置里添加
    func skipFolderSetup() {
        settings.firstRunDone = true
        needsFolderSetup = false
        Log.write("首次引导跳过，沿用现有索引目录=\(settings.roots.joined(separator: ", "))")
    }

    // MARK: - 搜索

    func queryChanged() {
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearchNow() }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 重新执行搜索。
    /// preserveSelection 用于后台刷新完成后的重跑：不能把用户正在看的那个结果顶掉。
    func runSearchNow(preserveSelection: Bool = false) {
        let previousID = preserveSelection ? selection?.id : nil
        focusedFile = nil
        focusedFileArtboards = []
        guard let database = database else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = SearchResults()
            selection = nil
            clearThumbnail()
            return
        }
        let found = database.search(text)
        results = found

        // 为结果里出现的文件准备封面图（按当前排序取前若干个）
        var coverPaths: [String] = []
        var seenPaths = Set<String>()
        for hit in found.artboards + found.pages + found.files where seenPaths.insert(hit.filePath).inserted {
            coverPaths.append(hit.filePath)
        }
        ensureFileCovers(for: coverPaths)

        // 后台刷新导致的重跑：原来选中的那条如果还在，保持不动
        if let previousID = previousID,
           let restored = (found.artboards + found.pages + found.files).first(where: { $0.id == previousID }) {
            DispatchQueue.main.async { self.selection = restored }
            return
        }

        // 搜索后自动选中第一个画板，直接看到图。
        // 必须推到下一个 runloop 再改选中态，否则会在列表渲染过程中触发重入。
        let first = found.artboards.first ?? found.pages.first ?? found.files.first
        DispatchQueue.main.async {
            if let first = first {
                self.select(first)
            } else {
                self.selection = nil
                self.clearThumbnail()
            }
        }
        // 结果稳定后在后台悄悄预热前几张缩略图，用户点过去时就是秒开。
        // 结果换了就自增 generation（让上一轮预热收手）并把窗口复位。
        DispatchQueue.main.async {
            self.stateLock.lock()
            self.prewarmGeneration &+= 1
            self.stateLock.unlock()
            self.prewarmWindowStart = 0
            self.prewarmWindowEnd = 0
            self.schedulePrewarmStart()
        }
    }

    // MARK: - 缩略图后台预热（窗口式）

    /// 输入时会反复触发搜索，所以先 debounce；连续输入只保留最后一次。
    /// 只在还没开始预热时才启动（用户选中第一条时通常已经先触发了一批）。
    private func schedulePrewarmStart() {
        prewarmSchedule?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.prewarmWindowEnd == 0 else { return }
            self.extendPrewarmWindow()
        }
        prewarmSchedule = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    /// 用户选中某项时决定怎么预热：
    /// - 落在当前窗口内 → 顺序浏览，快到窗口末尾就顺着往后补一批
    /// - 跳到窗口外（鼠标直接点很远处）→ 以点击项为首，**立刻重开**一个首批窗口
    private func handlePrewarm(for hit: SearchHit) {
        let hits = orderedHits
        guard let index = hits.firstIndex(where: { $0.id == hit.id }) else { return }

        if index < prewarmWindowStart || index >= prewarmWindowEnd {
            // 跳着点：作废正在跑的那批，以点击项为起点重新开窗
            stateLock.lock()
            prewarmGeneration &+= 1
            stateLock.unlock()
            prewarmWindowStart = index
            prewarmWindowEnd = index
            extendPrewarmWindow()
            return
        }

        if index >= prewarmWindowEnd - prewarmAhead {
            extendPrewarmWindow()
        }
    }

    /// 从窗口末尾再补一批：窗口刚开时是首批 25 个，之后每批 20 个。
    /// 用低优先级串行队列 + sketchtool 单核模式，尽量不打扰用户正在看的那张。
    /// generation 只在"结果被替换 / 用户跳点"时自增，同向批次之间不会互相打断。
    private func extendPrewarmWindow() {
        guard let database = database else { return }
        let hits = orderedHits
        let start = prewarmWindowEnd
        guard start < hits.count else { return }

        let isFirstBatch = (start == prewarmWindowStart)
        let batch = isFirstBatch ? prewarmInitialCount : prewarmBatchSize
        let end = min(hits.count, start + batch)
        prewarmWindowEnd = end

        var jobs: [(id: String, filePath: String, objectID: String, name: String, mtime: Double)] = []
        for hit in hits[start..<end] {
            guard hit.kind == .artboard, !hit.objectID.isEmpty else { continue }
            guard let record = database.file(at: hit.filePath) else { continue }
            jobs.append((hit.id, hit.filePath, hit.objectID, hit.name, record.mtime))
        }
        guard !jobs.isEmpty else { return }

        stateLock.lock()
        let generation = prewarmGeneration
        let current = pendingThumbnailID
        stateLock.unlock()

        let cacheDirectory = AppSettings.thumbnailDirectory
        Log.write("缩略图预热：第 \(start)~\(end) 项"
                  + "\(isFirstBatch ? "（首批）" : "（顺延）")，待导出 \(jobs.count) 个")
        prewarmQueue.async { [weak self] in
            var exported = 0
            var skipped = 0
            for job in jobs {
                guard let self = self else { return }
                // 结果已经换了一批（用户改了搜索词）→ 立刻收手
                self.stateLock.lock()
                let stale = (self.prewarmGeneration != generation)
                self.stateLock.unlock()
                if stale {
                    Log.write("缩略图预热中止：搜索结果已变化（已导出 \(exported) 个）")
                    return
                }
                // 用户正在看的那张，前台已经在导了，别重复
                if job.id == current { continue }

                let target = Thumbnailer.cachedURL(cacheDirectory: cacheDirectory,
                                                   filePath: job.filePath,
                                                   objectID: job.objectID,
                                                   mtime: job.mtime,
                                                   scale: Thumbnailer.exportScale)
                if FileManager.default.fileExists(atPath: target.path) {
                    skipped += 1
                    continue
                }

                let began = Date()
                _ = try? Thumbnailer.thumbnail(cacheDirectory: cacheDirectory,
                                               filePath: job.filePath,
                                               objectID: job.objectID,
                                               name: job.name,
                                               mtime: job.mtime,
                                               serial: true)
                let seconds = String(format: "%.2f", Date().timeIntervalSince(began))
                if Date().timeIntervalSince(began) > 5 {
                    Log.write("预热单张偏慢：\(job.name) ⟨\(job.filePath)⟩ 耗时 \(seconds)s")
                }
                exported += 1
            }
            Log.write("缩略图预热完成：新导出 \(exported) 个，已缓存跳过 \(skipped) 个")
        }
    }

    var visibleArtboards: [SearchHit] {
        kindFilter == .artboard ? results.artboards : []
    }

    var visiblePages: [SearchHit] {
        kindFilter == .page ? results.pages : []
    }

    var visibleFiles: [SearchHit] {
        kindFilter == .file ? results.files : []
    }

    /// 左侧列表按「文件」分组，文件之间按修改时间倒序 —— 最近改过的文件排在最上面。
    /// 同一文件下的画板/页面会合到一组里，界面上就是一个文件一个分组。
    var resultGroups: [FileGroup] {
        let hits = visibleArtboards + visiblePages + visibleFiles
        guard !hits.isEmpty else { return [] }

        var order: [String] = []
        var buckets: [String: [SearchHit]] = [:]
        for hit in hits {
            if buckets[hit.filePath] == nil { order.append(hit.filePath) }
            buckets[hit.filePath, default: []].append(hit)
        }

        return order
            .compactMap { path -> FileGroup? in
                guard let group = buckets[path], let first = group.first else { return nil }
                return FileGroup(filePath: path, fileName: first.fileName, fileDir: first.fileDir,
                                 fileMTime: first.fileMTime, hits: group)
            }
            .sorted { $0.fileMTime > $1.fileMTime }
    }

    // MARK: - 选择与缩略图

    func select(_ hit: SearchHit) {
        focusedFile = nil
        focusedFileArtboards = []
        // 只改 selection，缩略图交给 $selection 的订阅统一处理，
        // 这样「点列表 / 方向键 / 程序选中」三条路径行为完全一致
        selection = hit
    }

    /// 当前界面上按顺序排列的所有结果。
    /// 在「该文件全部画板」视图里，键盘导航要跟着那个列表走，而不是搜索结果。
    var orderedHits: [SearchHit] {
        if focusedFile != nil { return focusedFileArtboards }
        // 必须和界面上看到的顺序完全一致（按文件分组后的顺序），否则键盘导航会跳错
        return resultGroups.flatMap { $0.hits }
    }

    func selectIndex(_ index: Int) {
        let hits = orderedHits
        guard index >= 0, index < hits.count else { return }
        select(hits[index])
    }

    /// 键盘上下键切换；没有选中时，下键选第一条、上键选最后一条
    func moveSelection(by delta: Int) {
        let hits = orderedHits
        guard !hits.isEmpty else { return }
        guard let current = selection, let index = hits.firstIndex(of: current) else {
            select(delta > 0 ? hits[0] : hits[hits.count - 1])
            return
        }
        let next = min(max(index + delta, 0), hits.count - 1)
        guard next != index else { return }
        select(hits[next])
    }

    // MARK: - 键盘：让焦点在搜索框里也能用方向键切换结果

    func setMainWindow(_ window: NSWindow?) {
        guard let window = window else { return }
        if mainWindow === window, keyMonitor != nil { return }
        mainWindow = window
        cleanupWindowChrome(of: window)
        observeFullScreen(of: window)
        observeWindowClose(of: window)
        installKeyMonitor()
        Log.write("键盘监听已绑定主窗口：\(Int(window.frame.width))x\(Int(window.frame.height))")
    }

    /// 点红叉关窗 = 收进菜单栏，而不是退出应用：
    /// 关窗后把激活策略切成 `.accessory` —— 程序坞图标消失，状态栏图标继续驻留；
    /// 从状态栏或 Dock 再打开窗口时切回 `.regular`，图标跟着回来。
    private func observeWindowClose(of window: NSWindow) {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // 等关闭动画走完再切策略，避免切换瞬间的闪烁
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
                Log.write("主窗口已关闭 → 收进菜单栏（激活策略 accessory）")
            }
        }
    }

    /// 进全屏 / 退全屏之后 AppKit 会重建工具栏，SwiftUI 会把这些东西又加回来：
    ///   · "显示/隐藏侧栏"按钮（连同它那层玻璃底 —— 全屏时侧栏顶部就会多出一层底）
    ///   · 标题栏下面的分隔线
    /// 所以每次全屏状态变化都要重新清理一遍。
    private func observeFullScreen(of window: NSWindow) {
        let names: [Notification.Name] = [NSWindow.didEnterFullScreenNotification,
                                          NSWindow.didExitFullScreenNotification]
        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let self = self, let window = window else { return }
                Log.write("[全屏] \(name == NSWindow.didEnterFullScreenNotification ? "进入" : "退出")全屏，重新应用窗口装饰设置")
                self.cleanupWindowChrome(of: window)
                // 工具栏重建是异步的，过一小会儿再设一次
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak window] in
                    guard let self = self, let window = window else { return }
                    self.cleanupWindowChrome(of: window)
                }
            }
            fullScreenObservers.append(observer)
        }
    }

    /// 清掉窗口上那些系统自动加、我们不要的装饰。
    /// 这里只做一件事：去掉工具栏底部那条分隔线（全屏切换后 AppKit 会重建工具栏，所以要重设）。
    private func cleanupWindowChrome(of window: NSWindow) {
        window.titlebarSeparatorStyle = .none
        // 内容视图铺满整个窗口：预览画布才能延伸到工具栏下方，被工具栏的毛玻璃模糊透出
        // （SF Symbols 那种效果）。侧栏也因此一直延伸到窗口顶部，工具栏材质不会在它上面留一条底色。
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // 窗口自身底色跟随画布。全屏时工具栏隐藏，内容万一没盖满，
        // 露出来的就是这层底色 —— 用系统窗口灰会和画布（#1E1E1E）形成一条色差带。
        window.backgroundColor = .textBackgroundColor
        // contentLayoutRect 不含标题栏/工具栏，差值就是它们的总高度
        // （实测窗口模式与全屏都是 52）。
        // 允许归零只是防御：以前写成 chrome > 0 才更新，一旦某个窗口状态真的返回 0，
        // 就会永远残留旧值、把预览内容与居中基准整体推偏。
        let chrome = max(0, window.frame.height - window.contentLayoutRect.height)
        if abs(chrome - toolbarHeight) > 0.5 {
            toolbarHeight = chrome
        }
    }

    /// 点击搜索框以外的任何地方（空白处、列表、预览区、工具栏）时，主动让搜索框失焦。
    /// SwiftUI 的空白区域不接受 first responder，所以系统不会自动把焦点收走，
    /// 搜索框会一直保持聚焦状态（表现为一直有蓝色焦点环）。
    private func installClickMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self,
                  let window = self.mainWindow,
                  event.window === window else { return event }
            // 点在搜索框自己身上（含它的子视图 / 字段编辑器）就不动
            let hit = window.contentView?.hitTest(event.locationInWindow)
            if Self.isInsideSearchField(hit) { return event }
            // 只有当前焦点确实在某个文本输入里时才收 —— 别去干扰别的 responder
            if window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    /// 从命中视图往上找，判断是否落在搜索框内部
    private static func isInsideSearchField(_ view: NSView?) -> Bool {
        var current = view
        while let v = current {
            if v is NSSearchField { return true }
            current = v.superview
        }
        return false
    }

    private func installKeyMonitor() {
        installClickMonitor()
        guard keyMonitor == nil else { return }
        // 只监听本应用内的事件（不需要辅助功能权限）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard self.isSearchWindow(event.window) else { return event }
            // 带 Command / Option / Control 的组合键交回系统处理
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return event
            }
            switch event.keyCode {
            case 125: // ↓
                self.moveSelection(by: 1)
                return nil
            case 126: // ↑
                self.moveSelection(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    /// 事件是否来自搜索主窗口（设置窗口、菜单栏图标窗口都要放行）
    private func isSearchWindow(_ window: NSWindow?) -> Bool {
        guard let window = window else { return false }
        if let main = mainWindow { return window === main }
        // 主窗口引用还没就绪时的兜底：排除面板与菜单栏状态窗口
        if window is NSPanel { return false }
        if type(of: window).description().contains("NSStatusBarWindow") { return false }
        return window.frame.width > 300
    }

    /// 为"选中的文件"生成大尺寸封面图（列表图标那张是 44pt，放大会糊）。
    private func loadFileCover(for hit: SearchHit) {
        let path = hit.filePath
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 560, height: 560),
            scale: 2,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 生成期间用户可能已经切到别的结果了，只有还停在这个文件上才替换
                guard self.selection?.kind == .file, self.selection?.filePath == path else { return }
                if let image = image {
                    self.thumbnail = image
                    self.thumbnailMessage = nil
                } else if self.thumbnail == nil {
                    self.thumbnailMessage = "这个文件暂时生成不出封面图"
                }
                self.isLoadingThumbnail = false
            }
        }
    }

    private func clearThumbnail() {
        thumbnailWork?.cancel()
        thumbnail = nil
        thumbnailMessage = nil
        isLoadingThumbnail = false
    }

    private func loadThumbnail(for hit: SearchHit) {
        thumbnailWork?.cancel()
        stateLock.lock()
        pendingThumbnailID = hit.id
        stateLock.unlock()

        let shortFile = (hit.filePath as NSString).lastPathComponent
        Log.write("预览请求：\(hit.name) ⟨\(shortFile)⟩ 页面=\(hit.pageName) kind=\(hit.kind.rawValue)")

        // 选中的是"文件"本身：显示这个 .sketch 的封面图（Sketch 自带的 QuickLook 缩略图）。
        // 列表图标用的那张只有 44pt，在这里会糊，所以单独按大尺寸再生成一张。
        if hit.kind == .file {
            if let small = fileCovers[hit.filePath] {
                thumbnail = small          // 先拿列表那张顶上，避免空白
                thumbnailMessage = nil
                isLoadingThumbnail = false
            } else {
                thumbnail = nil
                thumbnailMessage = "正在生成封面…"
                isLoadingThumbnail = true
            }
            loadFileCover(for: hit)
            return
        }

        guard hit.kind == .artboard, !hit.objectID.isEmpty else {
            thumbnail = nil
            thumbnailMessage = "页面本身没有缩略图，展开该文件的画板可以逐个预览"
            isLoadingThumbnail = false
            return
        }

        guard let database = database, let record = database.file(at: hit.filePath) else {
            thumbnail = nil
            thumbnailMessage = "文件不在索引里"
            return
        }

        let cacheDirectory = AppSettings.thumbnailDirectory
        let cached = Thumbnailer.cachedURL(cacheDirectory: cacheDirectory,
                                           filePath: hit.filePath,
                                           objectID: hit.objectID,
                                           mtime: record.mtime,
                                           scale: Thumbnailer.exportScale)

        if let image = NSImage(contentsOf: cached) {
            thumbnail = image
            thumbnailMessage = nil
            isLoadingThumbnail = false
            return
        }

        thumbnail = nil
        thumbnailMessage = "正在用 Sketch 导出这个画板…"
        isLoadingThumbnail = true

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 方向键快速切换时会有多个导出排队；前面那些已经没人要了就直接跳过，
            // 否则要等一串几秒的导出才能看到当前这张图
            self.stateLock.lock()
            let stillWanted = (self.pendingThumbnailID == hit.id)
            self.stateLock.unlock()
            guard stillWanted else {
                Log.write("预览跳过（选中项已切走）：\(hit.name)")
                return
            }

            let beganAt = Date()
            do {
                let began = beganAt
                let url = try Thumbnailer.thumbnail(cacheDirectory: cacheDirectory,
                                                    filePath: hit.filePath,
                                                    objectID: hit.objectID,
                                                    name: hit.name,
                                                    mtime: record.mtime,
                                                    timeout: 60)
                let image = NSImage(contentsOf: url)
                let seconds = String(format: "%.2f", Date().timeIntervalSince(began))
                Log.write("预览完成：\(hit.name) → \(image == nil ? "图片读取失败" : "成功")（导出耗时 \(seconds)s）")
                DispatchQueue.main.async {
                    guard self.selection?.id == hit.id else { return }
                    self.thumbnail = image
                    self.thumbnailMessage = image == nil ? "缩略图读取失败" : nil
                    self.isLoadingThumbnail = false
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                let seconds = String(format: "%.2f", Date().timeIntervalSince(beganAt))
                Log.write("预览失败（耗时 \(seconds)s）：\(hit.name) ⟨\(shortFile)⟩ → \(message)")
                DispatchQueue.main.async {
                    guard self.selection?.id == hit.id else { return }
                    self.thumbnail = nil
                    self.thumbnailMessage = message
                    self.isLoadingThumbnail = false
                }
            }
        }
        thumbnailWork = work
        previewQueue.async(execute: work)
    }

    /// 列出某个文件里的全部画板。入口在列表的右键菜单里，不占界面。
    func showArtboardsInFocusedFile(_ hit: SearchHit? = nil) {
        guard let target = hit ?? selection, let database = database else { return }
        focusedFile = target
        focusedFileArtboards = database.artboards(inFile: target.filePath)
    }

    // MARK: - 动作

    func openInSketch(_ hit: SearchHit?) {
        guard let hit = hit ?? selection else { return }
        if !Thumbnailer.openInSketch(hit.filePath) {
            alertMessage = "无法打开文件：\(hit.filePath)"
        }
    }

    func revealInFinder(_ hit: SearchHit?) {
        guard let hit = hit ?? selection else { return }
        Thumbnailer.revealInFinder(hit.filePath)
    }

    func copyPath(_ hit: SearchHit?) {
        guard let hit = hit ?? selection else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.filePath, forType: .string)
    }

    /// 拷贝当前所选画板的预览图 —— 导出 3x 高清图放进剪贴板。
    /// 预览区里显示的是 1x 缩略图（够看但不够用），所以这里重新按 3x 导一份。
    func copyPreviewImage(_ hit: SearchHit? = nil) {
        guard let hit = hit ?? selection else { return }
        showToast("正在生成 3x 高清图…", seconds: 1.5)

        previewQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                guard let image = try Thumbnailer.highResolutionImage(filePath: hit.filePath,
                                                                     objectID: hit.objectID,
                                                                     name: hit.name,
                                                                     mtime: hit.fileMTime) else {
                    throw ThumbnailError.exportFailed("导出的图片为空")
                }
                DispatchQueue.main.async {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    // 同时写 PNG 和 TIFF：不同接收方（Sketch / Figma / 系统预览 / 聊天工具）
                    // 认的类型不一样，两个都放进去最稳。
                    if let tiff = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        pasteboard.setData(png, forType: .png)
                    }
                    pasteboard.writeObjects([image])
                    self.showToast("已拷贝预览图")
                    Log.write("拷贝预览图：\(hit.name) ⟨\(hit.fileName)⟩ "
                              + "\(Int(image.size.width))x\(Int(image.size.height))（临时文件已删除）")
                }
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                DispatchQueue.main.async {
                    self.showWarning("拷贝预览图失败：\(detail)")
                    Log.write("拷贝预览图失败：\(detail)")
                }
            }
        }
    }

    /// 拷贝当前所选画板的**矢量数据**（Sketch 原生剪贴板格式）。
    /// 粘到别的 Sketch 文件里会还原成可编辑的原生图层，而不是一张图片。
    func copyVectorArtboard(_ hit: SearchHit? = nil) {
        guard let hit = hit ?? selection else { return }
        showToast("正在生成矢量数据…", seconds: 2)

        previewQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let outcome = try SketchClipboard.copyArtboard(filePath: hit.filePath,
                                                               objectID: hit.objectID)
                DispatchQueue.main.async {
                    self.showToast("已拷贝矢量画板")
                    Log.write("拷贝矢量画板：\(hit.name) ⟨\(hit.fileName)⟩ "
                              + "JSON \(outcome.rawBytes) → gzip \(outcome.compressedBytes) bytes")
                }
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                DispatchQueue.main.async {
                    self.showWarning("拷贝矢量画板失败：\(detail)")
                    Log.write("拷贝矢量画板失败：\(detail)")
                }
            }
        }
    }

    func removeSpotlightKeywords() {
        workQueue.async { [weak self] in
            guard let self = self, let database = self.database else { return }
            let count = Spotlight.removeAll(database: database)
            DispatchQueue.main.async {
                self.spotlightSummary = "已清除 \(count) 个文件的 Spotlight 关键词"
                self.loadStats()
            }
        }
    }

    /// 只重新同步 Spotlight 关键词，不重建索引
    func syncSpotlightNow() {
        guard !isIndexing else { return }
        isIndexing = true
        workQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let writer = try Database(path: AppSettings.databaseURL.path)
                let report = Spotlight.apply(database: writer,
                                             maxCount: self.settings.maxKeywords,
                                             maxBytes: self.settings.maxKeywordBytes)
                Log.write("Spotlight 手动同步：候选=\(report.considered) 新写入=\(report.changed) 跳过=\(report.skipped) 失败=\(report.failed) 权限拒绝=\(report.permissionDenied) 截断=\(report.truncated.count)")
                DispatchQueue.main.async {
                    self.isIndexing = false
                    self.spotlightHintVisible = report.permissionDenied > 0
                    if report.permissionDenied > 0 {
                        self.showWarning("需要允许访问 iCloud 云盘，才能同步到聚焦搜索")
                        self.spotlightSummary = "有 \(report.permissionDenied) 个文件的画板名写入被系统拒绝，"
                            + "请在「系统设置 → 隐私与安全性 → 文件与文件夹」中允许本应用访问 iCloud 云盘"
                    } else if !report.truncated.isEmpty {
                        self.spotlightSummary = "\(report.truncated.count) 个文件画板过多，超出关键词容量上限，"
                            + "超出部分只能在本地搜索里搜到"
                    } else {
                        self.spotlightSummary = "全部 \(report.considered) 个文件的画板名都已在 Spotlight 关键词里"
                    }
                    self.loadStats()
                }
            } catch {
                Log.write("Spotlight 手动同步失败：\(error)")
                DispatchQueue.main.async {
                    self.isIndexing = false
                    self.showWarning("同步到聚焦搜索失败")
                    self.alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    func rebuildIndex() {
        refresh(force: true, reason: "正在重建索引…", announce: true)
    }

    func clearThumbnailCache() {
        let count = Thumbnailer.clearCache(at: AppSettings.thumbnailDirectory)
        alertMessage = "已清除 \(count) 张缩略图缓存"
        refreshThumbnailCacheSize()
    }

    /// 设置页要显示「缩略图缓存：xxx MB」，扫目录放到后台做
    func refreshThumbnailCacheSize() {
        let directory = AppSettings.thumbnailDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bytes = Thumbnailer.cacheSize(at: directory)
            DispatchQueue.main.async { self?.thumbnailCacheBytes = bytes }
        }
    }
}
