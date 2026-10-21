import Foundation

struct IndexResult {
    var scanned = 0
    var updated = 0
    var removed = 0
    var failed = 0
    var seconds: Double = 0
    /// 每个索引目录各找到多少个 .sketch —— 用来判断「某个刚加的文件夹里其实没有」。
    var perRoot: [(root: String, found: Int)] = []
}

enum Indexer {

    // dirent 的 d_type 取值（直接写字面量，避免不同 SDK 的宏导入差异）
    private static let typeUnknown: UInt8 = 0
    private static let typeDirectory: UInt8 = 4
    private static let typeRegular: UInt8 = 8

    // MARK: - 目录遍历

    /// 遍历所有 .sketch（含极老版本的文件夹形式）。
    ///
    /// 这里刻意不用 FileManager.enumerator：Foundation 的目录枚举器会为每个目录项读取
    /// 扩展属性，而 getxattr 在 iCloud 云盘路径上会长时间阻塞（实测直接把索引线程挂死）。
    /// 改用 POSIX opendir/readdir + stat，只做必要的系统调用，又快又稳。
    static func sketchFiles(roots: [String],
                            excludeDirs: [String],
                            activity: (() -> Void)? = nil) -> (files: [String], perRoot: [(root: String, found: Int)]) {
        let excluded = Set(excludeDirs)
        var found: [String] = []
        var visited = 0
        var perRoot: [(root: String, found: Int)] = []

        for root in roots {
            let expanded = (root as NSString).expandingTildeInPath
            var info = stat()
            let exists = expanded.withCString { stat($0, &info) } == 0
            guard exists else {
                Log.write("索引跳过（路径不存在或不可访问）：\(expanded)")
                continue
            }
            if (info.st_mode & S_IFMT) != S_IFDIR {
                if expanded.lowercased().hasSuffix(".sketch") { found.append(expanded) }
                continue
            }
            var roundFound = 0
            walk(expanded, excluded: excluded, found: &found, counter: &roundFound,
                 visited: &visited, activity: activity)
            Log.write("遍历完成：\(expanded) → 找到 \(roundFound) 个 .sketch")
            perRoot.append((expanded, roundFound))
        }
        Log.write("索引扫描合计：\(found.count) 个 .sketch")
        return (found, perRoot)
    }

    private static func walk(_ directory: String, excluded: Set<String>,
                             found: inout [String], counter: inout Int,
                             visited: inout Int, activity: (() -> Void)?) {
        guard let handle = opendir(directory) else {
            let code = errno
            Log.write("无法打开目录 \(directory)：errno=\(code) \(String(cString: strerror(code)))")
            return
        }
        defer { closedir(handle) }

        var subdirectories: [String] = []
        // 每访问一批目录就报一次「我还活着」。
        // 冷启动时 iCloud 文件要先下载，光遍历就可能超过 25 秒 ——
        // 不报进度的话，看门狗会把它误判成「被权限拦住」。
        visited += 1
        if visited % 100 == 0 { activity?() }
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if name.isEmpty || name == "." || name == ".." || name.hasPrefix(".") { continue }

            let full = (directory as NSString).appendingPathComponent(name)
            let kind = entry.pointee.d_type

            if kind == typeDirectory || kind == typeUnknown {
                let isDirectory = kind == typeDirectory || isDirectoryAt(full)
                if isDirectory {
                    if name.lowercased().hasSuffix(".sketch") {
                        found.append(full)
                        counter += 1
                    } else if !excluded.contains(name) {
                        subdirectories.append(full)
                    }
                    continue
                }
            }
            if name.lowercased().hasSuffix(".sketch") {
                found.append(full)
                counter += 1
            }
        }

        for subdirectory in subdirectories {
            walk(subdirectory, excluded: excluded, found: &found, counter: &counter,
                 visited: &visited, activity: activity)
        }
    }

    private static func isDirectoryAt(_ path: String) -> Bool {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// 用 stat 取修改时间与大小（同样避开 Foundation 的扩展属性读取）
    private static func fileInfo(_ path: String) -> (mtime: Double, size: Int64)? {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return (mtime, Int64(info.st_size))
    }

    static func isUnder(_ path: String, roots: [String]) -> Bool {
        for root in roots {
            let expanded = (root as NSString).expandingTildeInPath
            if path == expanded || path.hasPrefix(expanded.hasSuffix("/") ? expanded : expanded + "/") {
                return true
            }
        }
        return false
    }

    // MARK: - 增量索引

    @discardableResult
    static func run(database: Database,
                    roots: [String],
                    excludeDirs: [String],
                    force: Bool = false,
                    jobs: Int = 8,
                    progress: ((Int, Int) -> Void)? = nil,
                      activity: (() -> Void)? = nil) throws -> IndexResult {
        let started = Date()
        var result = IndexResult()

        let known = database.fileStates()
        let scan = sketchFiles(roots: roots, excludeDirs: excludeDirs, activity: activity)
        let candidates = scan.files
        result.perRoot = scan.perRoot
        result.scanned = candidates.count

        var pending: [(path: String, mtime: Double, size: Int64)] = []
        for path in candidates {
            guard let info = fileInfo(path) else { continue }
            if !force, let previous = known[path],
               previous.status == "ok",
               abs(previous.mtime - info.mtime) < 0.000001,
               previous.size == info.size {
                continue
            }
            pending.append((path, info.mtime, info.size))
        }

        result.updated = pending.count
        let total = pending.count
        guard total > 0 else {
            result.removed = try forgetMissing(database: database, roots: roots, seen: Set(candidates))
            result.seconds = Date().timeIntervalSince(started)
            Log.write("索引无需更新（全部已是最新），用时 \(String(format: "%.2f", result.seconds))s")
            return result
        }

        // 并行解析（zip 解压 + JSON 解析是纯计算）
        let parsed = UnsafeMutablePointer<SketchDocument?>.allocate(capacity: total)
        parsed.initialize(repeating: nil, count: total)
        defer {
            parsed.deinitialize(count: total)
            parsed.deallocate()
        }

        let lock = NSLock()
        var completed = 0
        let workerCount = max(1, min(jobs, 16))
        let queue = DispatchQueue(label: "sksearch.index", attributes: .concurrent)
        let group = DispatchGroup()
        let chunk = max(1, (total + workerCount - 1) / workerCount)

        for start in stride(from: 0, to: total, by: chunk) {
            let end = min(start + chunk, total)
            group.enter()
            queue.async {
                for index in start..<end {
                    let item = pending[index]
                    parsed[index] = SketchParser.parse(url: URL(fileURLWithPath: item.path))
                    lock.lock()
                    completed += 1
                    let snapshot = completed
                    lock.unlock()
                    if snapshot % 40 == 0 || snapshot == total {
                        progress?(snapshot, total)
                    }
                }
                group.leave()
            }
        }
        group.wait()

        try database.transaction {
            for (index, item) in pending.enumerated() {
                guard let document = parsed[index] else { continue }
                try database.upsert(file: item.path, mtime: item.mtime, size: item.size, document: document)
                if document.error != nil { result.failed += 1 }
            }
        }

        result.removed = try forgetMissing(database: database, roots: roots, seen: Set(candidates))
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    private static func forgetMissing(database: Database, roots: [String], seen: Set<String>) throws -> Int {
        // 两类要忘掉：
        //   ① 在索引目录之内、但这次扫描没见到（文件被删/改名，或整个盘没挂载）
        //   ② **根本不在索引目录之内** —— 用户已经在设置里把这个目录移除了
        // ② 原来漏了：只按「在 root 之内 && 没见到」判断，被移除目录下的记录
        // 既不在范围内、也不会被判定为 stale，于是永远留在库里还能被搜到。
        let stale = Array(database.allPaths().filter { path in
            guard isUnder(path, roots: roots) else { return true }
            return !seen.contains(path)
        })
        guard !stale.isEmpty else { return 0 }
        try database.transaction { try database.forget(paths: stale) }
        // 顺手清掉我们写在这些文件上的 Spotlight 关键词：
        // 只删数据库记录的话，⌘空格 里仍然能搜到 —— 用户会以为「移除了还在」。
        // 文件已不存在 / 盘没挂载时 removeXattr 会失败，无害。
        for path in stale {
            _ = Spotlight.removeXattr(path: path, name: Spotlight.keywordsAttribute)
        }
        return stale.count
    }
}
