import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: LocalizedError {
    case open(String)
    case sql(String)

    var errorDescription: String? {
        switch self {
        case .open(let detail): return "无法打开索引数据库：\(detail)"
        case .sql(let detail): return "数据库操作失败：\(detail)"
        }
    }
}

struct FileRecord {
    var path: String
    var name: String
    var dir: String
    var mtime: Double
    var size: Int64
    var pageCount: Int
    var artboardCount: Int
    var status: String
    var error: String?
    var kwHash: String?
    var kwCount: Int
    var kwTotal: Int
}

enum HitKind: String {
    case artboard
    case page
    case file
}

struct SearchHit: Identifiable, Hashable {
    let id: String
    let kind: HitKind
    let name: String
    let pageName: String
    let objectID: String
    let filePath: String
    let fileName: String
    let fileDir: String
    /// 所属文件的修改时间（秒）。列表按它倒序分组：最近改过的文件在最上面。
    let fileMTime: Double
}

/// 同一个文件下的搜索结果，用于左侧列表按文件分组
struct FileGroup: Identifiable {
    let filePath: String
    let fileName: String
    let fileDir: String
    let fileMTime: Double
    let hits: [SearchHit]
    var id: String { filePath }
}

struct SearchResults {
    var artboards: [SearchHit] = []
    var pages: [SearchHit] = []
    var files: [SearchHit] = []

    var isEmpty: Bool { artboards.isEmpty && pages.isEmpty && files.isEmpty }
    var total: Int { artboards.count + pages.count + files.count }
}

struct IndexStats {
    var files = 0
    var pages = 0
    var artboards = 0
    var bad = 0
    var bytes: Int64 = 0
    var tagged = 0
    var truncated = 0
}

final class Database {
    private var handle: OpaquePointer?
    let path: String

    private static let schema = """
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    CREATE TABLE IF NOT EXISTS files(
        path            TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        dir             TEXT NOT NULL,
        mtime           REAL NOT NULL DEFAULT 0,
        size            INTEGER NOT NULL DEFAULT 0,
        page_count      INTEGER NOT NULL DEFAULT 0,
        artboard_count  INTEGER NOT NULL DEFAULT 0,
        status          TEXT NOT NULL DEFAULT 'ok',
        error           TEXT,
        source          TEXT,
        kw_hash         TEXT,
        kw_count        INTEGER NOT NULL DEFAULT 0,
        kw_total        INTEGER NOT NULL DEFAULT 0,
        indexed_at      REAL
    );
    CREATE TABLE IF NOT EXISTS pages(
        file_path   TEXT NOT NULL,
        page_id     TEXT NOT NULL,
        name        TEXT NOT NULL DEFAULT '',
        ord         INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(file_path, page_id)
    );
    CREATE TABLE IF NOT EXISTS artboards(
        file_path   TEXT NOT NULL,
        page_id     TEXT NOT NULL,
        page_name   TEXT NOT NULL DEFAULT '',
        object_id   TEXT NOT NULL,
        name        TEXT NOT NULL DEFAULT '',
        kind        TEXT NOT NULL DEFAULT 'artboard',
        ord         INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(file_path, object_id)
    );
    CREATE INDEX IF NOT EXISTS idx_art_name ON artboards(name);
    CREATE INDEX IF NOT EXISTS idx_art_file ON artboards(file_path);
    CREATE INDEX IF NOT EXISTS idx_pages_file ON pages(file_path);
    CREATE INDEX IF NOT EXISTS idx_pages_name ON pages(name);
    """

    init(path: String) throws {
        self.path = path
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            throw DBError.open(message)
        }
        try execute(Self.schema)
    }

    deinit {
        if let handle = handle { sqlite3_close(handle) }
    }

    // MARK: - 基础执行

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "未知错误"
            if let pointer = errorPointer { sqlite3_free(pointer) }
            throw DBError.sql(message)
        }
    }

    private func prepare(_ sql: String, _ bindings: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DBError.sql(String(cString: sqlite3_errmsg(handle)))
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String:
                sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case let number as Int:
                sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Int64:
                sqlite3_bind_int64(statement, index, number)
            case let number as Double:
                sqlite3_bind_double(statement, index, number)
            default:
                sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    @discardableResult
    func run(_ sql: String, _ bindings: [Any?] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw DBError.sql(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    private func query(_ sql: String, _ bindings: [Any?] = [], row: (OpaquePointer) -> Void) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement!)
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func double(_ statement: OpaquePointer, _ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    // MARK: - 写入

    /// 事务包装：批量写入时把几百次提交合并成一次，速度差别很大
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func upsert(file path: String, mtime: Double, size: Int64, document: SketchDocument) throws {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let status = document.error == nil ? "ok" : "error"
        let artboardCount = document.artboardCount

        try run("DELETE FROM pages WHERE file_path = ?", [path])
        try run("DELETE FROM artboards WHERE file_path = ?", [path])

        for (pageIndex, page) in document.pages.enumerated() {
            let pageID = page.id.isEmpty ? "page-\(pageIndex)" : page.id
            try run("INSERT OR REPLACE INTO pages(file_path, page_id, name, ord) VALUES (?,?,?,?)",
                    [path, pageID, page.name, pageIndex])
            for (artIndex, art) in page.artboards.enumerated() {
                let objectID = art.objectID.isEmpty ? "\(pageID)-\(artIndex)" : art.objectID
                try run("INSERT OR REPLACE INTO artboards"
                        + "(file_path, page_id, page_name, object_id, name, kind, ord)"
                        + " VALUES (?,?,?,?,?,?,?)",
                        [path, pageID, page.name, objectID, art.name, art.kind, artIndex])
            }
        }

        try run("INSERT INTO files(path, name, dir, mtime, size, page_count, artboard_count,"
                + " status, error, source, kw_hash, kw_count, kw_total, indexed_at)"
                + " VALUES (?,?,?,?,?,?,?,?,?,?,"
                + "   (SELECT kw_hash FROM files WHERE path = ?),"
                + "   COALESCE((SELECT kw_count FROM files WHERE path = ?), 0),"
                + "   COALESCE((SELECT kw_total FROM files WHERE path = ?), 0), ?)"
                + " ON CONFLICT(path) DO UPDATE SET"
                + "   name=excluded.name, dir=excluded.dir, mtime=excluded.mtime, size=excluded.size,"
                + "   page_count=excluded.page_count, artboard_count=excluded.artboard_count,"
                + "   status=excluded.status, error=excluded.error, source=excluded.source,"
                + "   indexed_at=excluded.indexed_at",
                [path, name, dir, mtime, size, document.pages.count, artboardCount,
                 status, document.error, document.source,
                 path, path, path, Date().timeIntervalSince1970])
    }

    func forget(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        for path in paths {
            try run("DELETE FROM files WHERE path = ?", [path])
            try run("DELETE FROM pages WHERE file_path = ?", [path])
            try run("DELETE FROM artboards WHERE file_path = ?", [path])
        }
    }

    func setKeywordState(path: String, hash: String?, count: Int, total: Int?) throws {
        try run("UPDATE files SET kw_hash = ?, kw_count = ?, kw_total = COALESCE(?, kw_total) WHERE path = ?",
                [hash, count, total, path])
    }

    // MARK: - 读取

    func fileStates() -> [String: (mtime: Double, size: Int64, status: String)] {
        var result: [String: (Double, Int64, String)] = [:]
        try? query("SELECT path, mtime, size, status FROM files") { statement in
            result[self.text(statement, 0)] = (sqlite3_column_double(statement, 1),
                                               sqlite3_column_int64(statement, 2),
                                               self.text(statement, 3))
        }
        return result
    }

    func allPaths() -> Set<String> {
        var result = Set<String>()
        try? query("SELECT path FROM files") { statement in
            result.insert(self.text(statement, 0))
        }
        return result
    }

    func file(at path: String) -> FileRecord? {
        var record: FileRecord?
        try? query("SELECT * FROM files WHERE path = ?", [path]) { statement in
            record = FileRecord(path: self.text(statement, 0),
                                name: self.text(statement, 1),
                                dir: self.text(statement, 2),
                                mtime: sqlite3_column_double(statement, 3),
                                size: sqlite3_column_int64(statement, 4),
                                pageCount: Int(sqlite3_column_int64(statement, 5)),
                                artboardCount: Int(sqlite3_column_int64(statement, 6)),
                                status: self.text(statement, 7),
                                error: self.text(statement, 8),
                                kwHash: self.text(statement, 10).isEmpty ? nil : self.text(statement, 10),
                                kwCount: Int(sqlite3_column_int64(statement, 11)),
                                kwTotal: Int(sqlite3_column_int64(statement, 12)))
        }
        return record
    }

    func keywordCandidates(limit: Int? = nil, onlyMissing: Bool = false) -> [FileRecord] {
        var sql = "SELECT path, name, kw_hash, kw_count, kw_total, artboard_count, page_count, status"
            + " FROM files WHERE status = 'ok' AND artboard_count + page_count > 0"
        if onlyMissing { sql += " AND (kw_hash IS NULL OR kw_hash = '')" }
        sql += " ORDER BY path"
        if let limit = limit { sql += " LIMIT \(limit)" }

        var records: [FileRecord] = []
        try? query(sql) { statement in
            records.append(FileRecord(path: self.text(statement, 0),
                                      name: self.text(statement, 1),
                                      dir: "", mtime: 0, size: 0,
                                      pageCount: Int(sqlite3_column_int64(statement, 6)),
                                      artboardCount: Int(sqlite3_column_int64(statement, 5)),
                                      status: self.text(statement, 7),
                                      error: nil,
                                      kwHash: self.text(statement, 2).isEmpty ? nil : self.text(statement, 2),
                                      kwCount: Int(sqlite3_column_int64(statement, 3)),
                                      kwTotal: Int(sqlite3_column_int64(statement, 4))))
        }
        return records
    }

    func namesForFile(path: String) -> (pageNames: [String], artboardNames: [String]) {
        var pages: [String] = []
        var artboards: [String] = []
        try? query("SELECT name FROM pages WHERE file_path = ? ORDER BY ord", [path]) { statement in
            pages.append(self.text(statement, 0))
        }
        try? query("SELECT name FROM artboards WHERE file_path = ? ORDER BY ord, rowid", [path]) { statement in
            artboards.append(self.text(statement, 0))
        }
        return (pages, artboards)
    }

    func artboards(inFile path: String) -> [SearchHit] {
        var hits: [SearchHit] = []
        let fileName = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        var mtime: Double = 0
        try? query("SELECT mtime FROM files WHERE path = ?", [path]) { statement in
            mtime = self.double(statement, 0)
        }
        try? query("SELECT object_id, name, page_name, kind FROM artboards WHERE file_path = ? ORDER BY ord",
                   [path]) { statement in
            hits.append(SearchHit(id: path + "|" + self.text(statement, 0),
                                  kind: .artboard,
                                  name: self.text(statement, 1),
                                  pageName: self.text(statement, 2),
                                  objectID: self.text(statement, 0),
                                  filePath: path,
                                  fileName: fileName,
                                  fileDir: dir,
                                  fileMTime: mtime))
        }
        return hits
    }

    func stats() -> IndexStats {
        var result = IndexStats()
        try? query("SELECT COUNT(*), COALESCE(SUM(page_count),0), COALESCE(SUM(artboard_count),0),"
                   + " SUM(CASE WHEN status <> 'ok' THEN 1 ELSE 0 END),"
                   + " COALESCE(SUM(size),0),"
                   + " SUM(CASE WHEN kw_hash IS NOT NULL AND kw_hash <> '' THEN 1 ELSE 0 END),"
                   + " SUM(CASE WHEN kw_total > kw_count THEN 1 ELSE 0 END)"
                   + " FROM files") { statement in
            result.files = Int(sqlite3_column_int64(statement, 0))
            result.pages = Int(sqlite3_column_int64(statement, 1))
            result.artboards = Int(sqlite3_column_int64(statement, 2))
            result.bad = Int(sqlite3_column_int64(statement, 3))
            result.bytes = sqlite3_column_int64(statement, 4)
            result.tagged = Int(sqlite3_column_int64(statement, 5))
            result.truncated = Int(sqlite3_column_int64(statement, 6))
        }
        return result
    }

    // MARK: - 搜索

    func search(_ rawQuery: String, limit: Int = 300, perFile: Int = 60) -> SearchResults {
        let tokens = rawQuery
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return SearchResults() }

        var results = SearchResults()
        let primary = tokens[0].lowercased()

        // 画板
        var artboardClauses: [String] = []
        var artboardBindings: [Any?] = []
        for token in tokens {
            artboardClauses.append("(a.name LIKE ? OR a.page_name LIKE ? OR f.name LIKE ?)")
            let pattern = "%\(token)%"
            artboardBindings.append(contentsOf: [pattern, pattern, pattern])
        }
        let artboardSQL = "SELECT a.file_path, a.name, a.page_name, a.object_id, f.name, f.dir, f.mtime"
            + " FROM artboards a JOIN files f ON f.path = a.file_path"
            + " WHERE " + artboardClauses.joined(separator: " AND ")
            // 必须在这里就按文件修改时间排序再截断。
            // 否则（比如搜很短的词"1"，命中上万条）SQL 会任意取 3000 行，
            // 最近改过的文件可能根本没被取到，后面内存里再排序也救不回来。
            + " ORDER BY f.mtime DESC LIMIT 3000"
        var artboardRows: [(String, String, String, String, String, String, Double)] = []
        try? query(artboardSQL, artboardBindings) { statement in
            artboardRows.append((self.text(statement, 0), self.text(statement, 1), self.text(statement, 2),
                                 self.text(statement, 3), self.text(statement, 4), self.text(statement, 5),
                                 self.double(statement, 6)))
        }
        artboardRows.sort { left, right in
            // 先按文件修改时间倒序：最近改过的文件排在最上面
            if left.6 != right.6 { return left.6 > right.6 }
            let l = rank(left.1, primary), r = rank(right.1, primary)
            if l != r { return l < r }
            if left.1.count != right.1.count { return left.1.count < right.1.count }
            if left.1 != right.1 { return left.1 < right.1 }
            // 同名同长度的画板很多，必须再按路径和 id 兜底，
            // 否则排序结果在不同次运行之间会变，列表顺序不稳定
            if left.0 != right.0 { return left.0 < right.0 }
            return left.3 < right.3
        }
        var perFileCount: [String: Int] = [:]
        for row in artboardRows {
            let count = perFileCount[row.0, default: 0]
            if count >= perFile { continue }
            perFileCount[row.0] = count + 1
            results.artboards.append(SearchHit(id: row.0 + "|" + row.3, kind: .artboard, name: row.1,
                                               pageName: row.2, objectID: row.3,
                                               filePath: row.0, fileName: row.4, fileDir: row.5,
                                               fileMTime: row.6))
            if results.artboards.count >= limit { break }
        }

        // 页面
        var pageClauses: [String] = []
        var pageBindings: [Any?] = []
        for token in tokens {
            pageClauses.append("(p.name LIKE ? OR f.name LIKE ?)")
            let pattern = "%\(token)%"
            pageBindings.append(contentsOf: [pattern, pattern])
        }
        let pageSQL = "SELECT p.file_path, p.name, p.page_id, f.name, f.dir, f.mtime"
            + " FROM pages p JOIN files f ON f.path = p.file_path"
            + " WHERE " + pageClauses.joined(separator: " AND ")
            + " ORDER BY f.mtime DESC LIMIT 500"
        try? query(pageSQL, pageBindings) { statement in
            let path = self.text(statement, 0)
            let pageName = self.text(statement, 1)
            results.pages.append(SearchHit(id: path + "|page|" + self.text(statement, 2),
                                           kind: .page, name: pageName, pageName: pageName,
                                           objectID: self.text(statement, 2),
                                           filePath: path, fileName: self.text(statement, 3),
                                           fileDir: self.text(statement, 4),
                                           fileMTime: self.double(statement, 5)))
        }
        // 先按文件修改时间倒序，再按匹配度
        results.pages.sort {
            if $0.fileMTime != $1.fileMTime { return $0.fileMTime > $1.fileMTime }
            return rank($0.name, primary) < rank($1.name, primary)
        }

        // 文件
        var fileClauses: [String] = []
        var fileBindings: [Any?] = []
        for token in tokens {
            fileClauses.append("(name LIKE ? OR dir LIKE ?)")
            let pattern = "%\(token)%"
            fileBindings.append(contentsOf: [pattern, pattern])
        }
        let fileSQL = "SELECT path, name, dir, artboard_count, page_count, mtime FROM files"
            + " WHERE status = 'ok' AND " + fileClauses.joined(separator: " AND ")
            + " ORDER BY mtime DESC LIMIT \(limit)"
        try? query(fileSQL, fileBindings) { statement in
            let path = self.text(statement, 0)
            results.files.append(SearchHit(id: path, kind: .file, name: self.text(statement, 1),
                                           pageName: "", objectID: "",
                                           filePath: path, fileName: self.text(statement, 1),
                                           fileDir: self.text(statement, 2),
                                           fileMTime: self.double(statement, 5)))
        }
        return results
    }

    private func rank(_ name: String, _ primary: String) -> Int {
        let lower = name.lowercased()
        if lower == primary { return 0 }
        if lower.hasPrefix(primary) { return 1 }
        if lower.contains(primary) { return 2 }
        return 3
    }
}
