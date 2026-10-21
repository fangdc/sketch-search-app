import Foundation

// 引擎自检：索引 + 搜索，用来和 Python 版结果对账。
// 编译： swiftc Sources/*.swift Tests/main.swift -o test-index -lsqlite3 -lz

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs")
let dbPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : NSTemporaryDirectory() + "sksearch-self-test.db"

try? FileManager.default.removeItem(atPath: dbPath)
try? FileManager.default.removeItem(atPath: dbPath + "-wal")
try? FileManager.default.removeItem(atPath: dbPath + "-shm")

do {
    let database = try Database(path: dbPath)
    let started = Date()
    let result = try Indexer.run(
        database: database,
        roots: [root],
        excludeDirs: ["node_modules", ".git", ".Trash", "Library/Caches", "sketch-assets"],
        force: true,
        jobs: 8
    ) { done, total in
        if done % 200 == 0 { print("  解析 \(done)/\(total)") }
    }

    print("扫描=\(result.scanned) 更新=\(result.updated) 失败=\(result.failed) 用时=\(String(format: "%.2f", result.seconds))s (总耗时 \(String(format: "%.2f", Date().timeIntervalSince(started)))s)")

    let stats = database.stats()
    print("文件=\(stats.files) 页面=\(stats.pages) 画板=\(stats.artboards) 异常=\(stats.bad)")

    for query in ["订单详情", "个人中心", "登录页", "首页"] {
        let hits = database.search(query)
        print("搜索「\(query)」→ 画板 \(hits.artboards.count) / 页面 \(hits.pages.count) / 文件 \(hits.files.count)")
        if let first = hits.artboards.first {
            print("    首个: \(first.name)  ⟨\(first.fileName)⟩  页面=\(first.pageName)  id=\(first.objectID)")
        }
    }
} catch {
    print("ERROR: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    exit(1)
}
