import AppKit
import Foundation

/// 画板缩略图：调用 Sketch 自带的 sketchtool 按画板 id 精确导出，并做磁盘缓存。
/// 缓存键包含文件 mtime，Sketch 文件改了会自动失效重导。

enum ThumbnailError: LocalizedError {
    case noSketchTool
    case missingFile(String)
    case exportFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .noSketchTool:
            return "找不到 Sketch。请确认已安装 Sketch（/Applications/Sketch.app）"
        case .missingFile(let path):
            return "文件不存在：\(path)"
        case .exportFailed(let detail):
            return "缩略图导出失败：\(detail)"
        case .timeout:
            return "缩略图导出超时，Sketch 文件可能过大"
        }
    }
}

enum Thumbnailer {

    /// 缩略图缓存上限（200 MB）。超过后按"最久未使用"淘汰，避免长期只增不减。
    static let cacheLimitBytes: Int64 = 200 * 1024 * 1024

    /// 导出倍数。实测 0.25 和更高的倍数在导出耗时上几乎没区别（成本主要在打开
    /// .sketch 文件，不在渲染），差别只在文件体积和解码速度。
    ///
    /// 取 1x：主流 UI 画板（手机稿高 1257、桌面稿宽 1440）在 1x 下就已经≥ 2x 屏预览区
    /// 需要的尺寸（竖版 1120px / 横版 1368px），清晰度够，单张只有 ~180KB。
    /// 只有尺寸特别小的画板（比如宽 800 的稿子）会被放大一点点。
    static let exportScale: Double = 1.0

    /// 长边上限：超大画板按 2x 导出会有好几 MB，等比缩到这个像素以内再缓存。
    static let maxLongestSide: CGFloat = 2400

    /// 「拷贝预览图」导出的长边上限。
    /// 3x 是目的，但不能无限大 —— 超大画板 3x 之后可能上万像素（上亿像素、几百 MB 内存），
    /// 加载成 NSImage 会直接拖垮应用。超过就等比缩到这个值。
    static let maxCopyLongestSide: CGFloat = 6000

    static func sketchtoolPath() -> String? {
        let candidates = [
            "/Applications/Sketch.app/Contents/MacOS/sketchtool",
            NSHomeDirectory() + "/Applications/Sketch.app/Contents/MacOS/sketchtool"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func cacheKey(filePath: String, objectID: String, mtime: Double, scale: Double) -> String {
        var hasher = SHA1()
        hasher.update("\(filePath)|\(objectID)|\(mtime)|\(scale)")
        return hasher.finalize()
    }

    static func cachedURL(cacheDirectory: URL, filePath: String, objectID: String,
                          mtime: Double, scale: Double) -> URL {
        let key = cacheKey(filePath: filePath, objectID: objectID, mtime: mtime, scale: scale)
        return cacheDirectory.appendingPathComponent(key + ".png")
    }

    /// 同步导出（调用方请放到后台队列）。已有缓存会直接返回。
    static func thumbnail(cacheDirectory: URL,
                          filePath: String,
                          objectID: String,
                          name: String,
                          mtime: Double,
                          scale: Double = Thumbnailer.exportScale,
                          timeout: TimeInterval = 180,
                          force: Bool = false,
                          serial: Bool = false,
                          downscale: Bool = true) throws -> URL {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw ThumbnailError.missingFile(filePath)
        }
        guard let tool = sketchtoolPath() else { throw ThumbnailError.noSketchTool }

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let target = cachedURL(cacheDirectory: cacheDirectory, filePath: filePath,
                               objectID: objectID, mtime: mtime, scale: scale)

        if !force, FileManager.default.fileExists(atPath: target.path),
           (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue ?? 0 > 0 {
            touch(target)
            return target
        }

        var lastDetail = "sketchtool 没有输出图片"
        // 先按画板 id 导出，失败再退回按名字（重名画板用 id 更准）
        for item in [objectID, name].filter({ !$0.isEmpty }) {
            let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sksearch-thumb-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDirectory) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            var arguments = [
                "export", "artboards", filePath,
                "--item=\(item)",
                "--formats=png",
                "--scales=\(scale)",
                "--output=\(outputDirectory.path)",
                "--overwriting=YES",
                "--include-symbols=YES",
                "--use-id-for-name=YES",
                "--save-for-web=NO",
                "--trimmed=YES"
            ]
            // 后台预热时限制成单核，避免和用户正在等的那张抢 CPU
            if serial { arguments.append("--serial=YES") }
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // 必须一边等进程、一边把管道读空。
            // 否则 sketchtool 往管道里写满缓冲区（64KB）后就会阻塞在 write 上、
            // 进程永远不退出，我们只能干等到超时 —— 实测某些文件（文字图层多、
            // CoreText 警告刷屏）会整整卡满 180 秒，而同一命令在终端里只要 1 秒。
            let drainGroup = DispatchGroup()
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                // 读到 EOF 即可，内容不需要 —— 目的只是不让子进程阻塞在写上
                _ = pipe.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }

            do {
                try process.run()
            } catch {
                throw ThumbnailError.exportFailed(error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                throw ThumbnailError.timeout
            }
            // 进程已退出，管道很快就会读到 EOF
            _ = drainGroup.wait(timeout: .now() + 2)

            var produced: [URL] = []
            if let listing = try? FileManager.default.contentsOfDirectory(
                at: outputDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
                produced = listing
                    .filter { $0.pathExtension.lowercased() == "png" }
                    .sorted { left, right in
                        let l = (try? left.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        let r = (try? right.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        return l > r
                    }
            }

            if let first = produced.first {
                let staging = target.appendingPathExtension("part")
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.copyItem(at: first, to: staging)
                _ = try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: staging, to: target)
                // 只有"给缩略图缓存"的导出才缩体积。
                // 「拷贝预览图」要的是 3x 原图，绝不能在这里被缩回 2400px
                // （实测 393×1595 的画板，3x 应为 1179×4785，曾被缩成 591×2400 = 1.5x）。
                if downscale {
                    downscaleIfNeeded(target)
                    enforceCacheLimit(at: cacheDirectory)
                }
                return target
            }

            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastLine = output.split(separator: "\n").last {
                lastDetail = String(lastLine)
            }
        }
        throw ThumbnailError.exportFailed(lastDetail)
    }

    static func clearCache(at cacheDirectory: URL) -> Int {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: cacheDirectory,
                                                           includingPropertiesForKeys: nil) else { return 0 }
        let images = items.filter { $0.pathExtension.lowercased() == "png" }
        for item in images { try? manager.removeItem(at: item) }
        return images.count
    }

    /// "拷贝预览图"用：按指定倍数导出高清图（默认 3x）。
    ///
    /// 注意这里**不走常规缩略图缓存** —— 缓存里的图是 1x、给列表和预览用的；
    /// 3x 的图体积大得多，塞进缓存会把 200MB 的上限迅速吃满。
    /// 所以每次导出到独立临时目录，把图读进内存后立刻把目录删掉 —— 不留任何文件。
    static func highResolutionImage(filePath: String,
                                    objectID: String,
                                    name: String,
                                    mtime: Double,
                                    scale: Double = 3.0) throws -> NSImage? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sksearch-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try thumbnail(cacheDirectory: directory,
                                filePath: filePath,
                                objectID: objectID,
                                name: name,
                                mtime: mtime,
                                scale: scale,
                                downscale: false)
        // 超大画板保护：先只读像素尺寸（不解码），超过上限才等比缩小。
        // 3x 的 4000×3000 画板就是 12000×9000、上亿像素 —— 直接加载会吃掉几百 MB 内存。
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            let longest = CGFloat(max(width, height))
            if longest > maxCopyLongestSide,
               let image = NSImage(contentsOf: url),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                Log.write("拷贝预览图：原图 \(width)x\(height) 超出长边上限，"
                          + "已缩到 \(Int(maxCopyLongestSide))")
                downscale(url, source: cgImage, toLongestSide: maxCopyLongestSide)
            }
        }

        // 必须先整个读进内存再返回：NSImage(contentsOf:) 是惰性加载，
        // 上面的 defer 一执行文件就没了，懒加载的图会变成空白。
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// 清掉历史遗留的高清图临时目录（异常退出时可能残留）。
    /// 在应用启动时调一次即可 —— 用户不希望这些拷贝文件堆积在磁盘上。
    @discardableResult
    static func cleanStaleCopyTemporaries() -> Int {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let items = try? manager.contentsOfDirectory(at: base,
                                                           includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for item in items where item.lastPathComponent.hasPrefix("sksearch-copy-") {
            try? manager.removeItem(at: item)
            removed += 1
        }
        return removed
    }

    /// 命中缓存时把文件的修改时间推到现在，当作"最近使用时间"。
    /// macOS 默认不更新访问时间（atime），所以 LRU 只能靠这个自己维护。
    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: url.path)
    }

    /// 超大画板等比缩小后覆盖缓存文件。
    ///
    /// 注意触发条件是"长边超过上限的 1.5 倍"而不是"超过上限"：sketchtool 输出的 PNG
    /// 编码比 AppKit 重新编码更优，轻微缩小不但省不了空间，反而会让文件变大、还多花时间。
    /// 只有缩得足够多（比如 3840px → 2400px）才划算。
    private static func downscaleIfNeeded(_ url: URL) {
        guard let image = NSImage(contentsOf: url),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let longest = CGFloat(max(source.width, source.height))
        guard longest > maxLongestSide * 1.5 else { return }
        downscale(url, source: source, toLongestSide: maxLongestSide)
    }

    /// 等比缩到指定长边（供缓存控体积与「拷贝预览图」的超大图保护共用）
    private static func downscale(_ url: URL, source: CGImage, toLongestSide cap: CGFloat) {
        let longest = CGFloat(max(source.width, source.height))
        guard longest > cap else { return }

        let factor = cap / longest
        let targetWidth = max(1, Int((CGFloat(source.width) * factor).rounded()))
        let targetHeight = max(1, Int((CGFloat(source.height) * factor).rounded()))
        guard let context = CGContext(data: nil,
                                      width: targetWidth,
                                      height: targetHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0,
                                        width: CGFloat(targetWidth),
                                        height: CGFloat(targetHeight)))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// 缓存超过上限时，按最久未使用依次淘汰。
    /// 淘汰目标是上限的 80%，避免刚好卡在阈值上每次预览都触发一次清理。
    @discardableResult
    static func enforceCacheLimit(at cacheDirectory: URL,
                                  limit: Int64 = cacheLimitBytes) -> (removed: Int, bytes: Int64) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return (0, 0)
        }

        var entries: [(url: URL, size: Int64, used: Date)] = []
        var total: Int64 = 0
        for item in items where item.pathExtension.lowercased() == "png" {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            entries.append((item, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > limit else { return (0, total) }

        let target = limit * 8 / 10
        var removed = 0
        var freed: Int64 = 0
        for entry in entries.sorted(by: { $0.used < $1.used }) {
            if total <= target { break }
            if (try? manager.removeItem(at: entry.url)) != nil {
                total -= entry.size
                freed += entry.size
                removed += 1
            }
        }
        Log.write("缩略图缓存超过上限，已淘汰 \(removed) 个文件（释放 \(freed / 1024 / 1024) MB），"
                  + "当前 \(total / 1024 / 1024) MB")
        return (removed, total)
    }

    static func cacheSize(at cacheDirectory: URL) -> Int64 {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: cacheDirectory,
                                                           includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(Int64(0)) { total, item in
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    static func isSketchInstalled() -> Bool {
        sketchtoolPath() != nil
    }

    /// 用 Sketch 打开文件
    @discardableResult
    static func openInSketch(_ path: String) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return false }
        let sketchURL = URL(fileURLWithPath: "/Applications/Sketch.app")
        if manager.fileExists(atPath: sketchURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                    withApplicationAt: sketchURL,
                                    configuration: configuration) { _, _ in }
            return true
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return true
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
