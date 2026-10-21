import Foundation

/// 把页面名 / 画板名写入文件的 Spotlight 关键词扩展属性。
///
/// macOS 的通用元数据导入器会读取 com.apple.metadata:kMDItemKeywords
/// （二进制 plist 的字符串数组），于是聚焦搜索就能按画板名命中该文件。
///
/// 实测：这个属性的数据超过约 20KB 会被 Spotlight 静默截断，
/// 所以按 18KB / 900 条主动封顶，并把被截断的文件报告出来。

enum SpotlightError: LocalizedError {
    case xattr(name: String, code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .xattr(let name, let code, let message):
            return "写入 \(name) 失败（\(code)：\(message)）"
        }
    }
}

struct SpotlightReport {
    var considered = 0
    var changed = 0
    var skipped = 0
    var failed = 0
    var keywords = 0
    var permissionDenied = 0
    var truncated: [(name: String, total: Int, kept: Int)] = []
    var seconds: Double = 0
}

enum Spotlight {
    static let keywordsAttribute = "com.apple.metadata:kMDItemKeywords"
    static let markerAttribute = "com.sksearch.kwhash"

    // MARK: - 扩展属性

    static func setXattr(path: String, name: String, value: Data) throws {
        let status = path.withCString { pathPointer in
            name.withCString { namePointer in
                value.withUnsafeBytes { raw -> Int32 in
                    guard let base = raw.baseAddress else { return Int32(-1) }
                    return setxattr(pathPointer, namePointer, base, value.count, 0, 0)
                }
            }
        }
        if status != 0 {
            let code = errno
            throw SpotlightError.xattr(name: name, code: code, message: String(cString: strerror(code)))
        }
    }

    static func getXattr(path: String, name: String) -> Data? {
        let size = path.withCString { pathPointer in
            name.withCString { namePointer in
                getxattr(pathPointer, namePointer, nil, 0, 0, 0)
            }
        }
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = path.withCString { pathPointer in
            name.withCString { namePointer in
                buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return getxattr(pathPointer, namePointer, base, size, 0, 0)
                }
            }
        }
        guard read > 0 else { return nil }
        return Data(buffer[0..<read])
    }

    @discardableResult
    static func removeXattr(path: String, name: String) -> Bool {
        let status = path.withCString { pathPointer in
            name.withCString { namePointer in
                removexattr(pathPointer, namePointer, 0)
            }
        }
        return status == 0
    }

    static func keywordsData(_ names: [String]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: names, format: .binary, options: 0)
    }

    static func hash(_ names: [String]) -> String {
        var hasher = SHA1()
        hasher.update(names.joined(separator: "\n"))
        return hasher.finalize()
    }

    // MARK: - 批量写入

    static func apply(database: Database,
                      maxCount: Int,
                      maxBytes: Int,
                      limit: Int? = nil,
                      onlyMissing: Bool = false,
                      force: Bool = false,
                      mdimport: Bool = true,
                      progress: ((Int, Int) -> Void)? = nil) -> SpotlightReport {
        var report = SpotlightReport()
        let started = Date()
        let candidates = database.keywordCandidates(limit: limit, onlyMissing: onlyMissing)
        report.considered = candidates.count

        var pendingImport: [String] = []
        let fileManager = FileManager.default

        for (index, record) in candidates.enumerated() {
            let path = record.path
            guard fileManager.fileExists(atPath: path) else { continue }

            let names = database.namesForFile(path: path)
            let built = SketchParser.keywords(pageNames: names.pageNames,
                                              artboardNames: names.artboardNames,
                                              maxCount: maxCount,
                                              maxBytes: maxBytes)
            guard !built.keywords.isEmpty else {
                report.skipped += 1
                continue
            }
            if built.candidates > built.keywords.count {
                report.truncated.append((record.name, built.candidates, built.keywords.count))
            }

            let digest = hash(built.keywords)
            if !force {
                if record.kwHash == digest {
                    report.skipped += 1
                    continue
                }
                // 文件上已有的标注与当前画板名一致：只补数据库状态，不重复写入
                // （首次运行时数据库是空的，但文件可能早被标注过，这一步能省掉几百次写入）
                if let stored = getXattr(path: path, name: markerAttribute),
                   String(decoding: stored, as: UTF8.self) == digest {
                    try? database.setKeywordState(path: path, hash: digest,
                                                  count: built.keywords.count, total: built.candidates)
                    report.skipped += 1
                    continue
                }
            }

            guard let payload = keywordsData(built.keywords) else {
                report.failed += 1
                continue
            }

            do {
                try setXattr(path: path, name: keywordsAttribute, value: payload)
                try setXattr(path: path, name: markerAttribute,
                             value: Data(digest.utf8))
            } catch {
                report.failed += 1
                if let spotlightError = error as? SpotlightError,
                   case .xattr(_, let code, _) = spotlightError, code == 1 || code == 13 {
                    report.permissionDenied += 1
                }
                continue
            }

            try? database.setKeywordState(path: path, hash: digest,
                                          count: built.keywords.count, total: built.candidates)
            pendingImport.append(path)
            report.changed += 1
            report.keywords += built.keywords.count
            progress?(index + 1, candidates.count)
        }

        if mdimport, !pendingImport.isEmpty {
            runMdimport(paths: pendingImport)
        }
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    static func removeAll(database: Database, limit: Int? = nil) -> Int {
        let candidates = database.keywordCandidates(limit: limit)
        var touched: [String] = []
        for record in candidates where FileManager.default.fileExists(atPath: record.path) {
            let removedMarker = removeXattr(path: record.path, name: markerAttribute)
            let removedKeywords = removeXattr(path: record.path, name: keywordsAttribute)
            if removedMarker || removedKeywords { touched.append(record.path) }
            try? database.setKeywordState(path: record.path, hash: nil, count: 0, total: nil)
        }
        runMdimport(paths: touched)
        return touched.count
    }

    static func status(database: Database) -> (candidates: Int, tagged: Int, stale: Int, missing: Int) {
        let candidates = database.keywordCandidates()
        var tagged = 0, stale = 0, missing = 0
        for record in candidates {
            guard FileManager.default.fileExists(atPath: record.path) else {
                missing += 1
                continue
            }
            guard let stored = getXattr(path: record.path, name: markerAttribute) else { continue }
            if String(decoding: stored, as: UTF8.self) == (record.kwHash ?? "") {
                tagged += 1
            } else {
                stale += 1
            }
        }
        return (candidates.count, tagged, stale, missing)
    }

    /// 让 Spotlight 立刻重新导入这些文件，不必等后台索引
    static func runMdimport(paths: [String], chunkSize: Int = 40) {
        guard !paths.isEmpty else { return }
        let tool = "/usr/bin/mdimport"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        var index = 0
        while index < paths.count {
            let batch = Array(paths[index..<min(index + chunkSize, paths.count)])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = batch
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            index += chunkSize
        }
    }
}

/// 轻量 SHA1，避免为了一个哈希引入 CommonCrypto 的桥接代码
struct SHA1 {
    private var state: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    private var buffer = [UInt8]()
    private var length: UInt64 = 0

    mutating func update(_ string: String) {
        update(Array(string.utf8))
    }

    mutating func update(_ bytes: [UInt8]) {
        length += UInt64(bytes.count) * 8
        buffer.append(contentsOf: bytes)
        while buffer.count >= 64 {
            process(Array(buffer[0..<64]))
            buffer.removeFirst(64)
        }
    }

    private mutating func process(_ chunk: [UInt8]) {
        var words = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            let offset = i * 4
            words[i] = (UInt32(chunk[offset]) << 24) | (UInt32(chunk[offset + 1]) << 16)
                | (UInt32(chunk[offset + 2]) << 8) | UInt32(chunk[offset + 3])
        }
        for i in 16..<80 {
            let value = words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16]
            words[i] = (value << 1) | (value >> 31)
        }
        var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4]
        for i in 0..<80 {
            let f: UInt32, k: UInt32
            switch i {
            case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
            case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
            default: f = b ^ c ^ d; k = 0xCA62C1D6
            }
            let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ words[i]
            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
        }
        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
    }

    mutating func finalize() -> String {
        let bitLength = length
        buffer.append(0x80)
        while buffer.count % 64 != 56 { buffer.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }
        while buffer.count >= 64 {
            process(Array(buffer[0..<64]))
            buffer.removeFirst(64)
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }
}
