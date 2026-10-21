import Foundation

/// 解析 .sketch，提取页面与画板 / 组件（Symbol）名称。
struct SketchPage {
    var id: String
    var name: String
    var artboards: [SketchArtboard]
}

struct SketchArtboard {
    var objectID: String
    var name: String
    var kind: String   // artboard / symbol
}

struct SketchDocument {
    var pages: [SketchPage] = []
    var source: String?
    var error: String?

    var artboardCount: Int { pages.reduce(0) { $0 + $1.artboards.count } }
}

enum SketchParser {

    /// Sketch 自动生成的占位名，写进 Spotlight 只会造成噪音
    private static let placeholderNames: Set<String> = [
        "画板", "矩形", "组", "编组", "符号", "页面",
        "Artboard", "Rectangle", "Group", "Symbol", "Page"
    ]

    private static let placeholderPattern = try! NSRegularExpression(
        pattern: "^(?:画板|矩形|组|编组|符号|页面|Artboard|Rectangle|Group|Symbol|Page)\\s*\\d*$",
        options: [])

    static func isPlaceholder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if placeholderNames.contains(trimmed) { return true }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return placeholderPattern.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    private static func clean(_ value: Any?) -> String {
        guard let text = value as? String else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 200 { return "" }
        return trimmed
    }

    static func parse(url: URL) -> SketchDocument {
        var document = SketchDocument()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            document.error = "文件不存在"
            return document
        }

        do {
            if isDirectory.boolValue {
                let pages = try parseFolder(url)
                document.pages = pages.pages
                document.source = "folder"
            } else {
                let reader = try ZipReader(url: url)

                if reader.contains("meta.json") {
                    if let data = try? reader.read("meta.json"),
                       let pages = parseMetaJSON(data), !pages.isEmpty {
                        document.pages = pages
                        document.source = "meta"
                    }
                }
                // meta.json 不可用时回退到完整图层树
                if document.pages.isEmpty, reader.contains("document.json") {
                    if let data = try? reader.read("document.json") {
                        document.pages = try parseLayerTree(documentJSON: data, reader: reader)
                        document.source = "pages"
                    }
                }
            }
        } catch {
            document.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }

        if document.pages.isEmpty && document.error == nil {
            document.error = "读不到任何页面（meta.json / document.json 都不可用）"
        }
        return document
    }

    // MARK: - meta.json 快速通道

    private static func parseMetaJSON(_ data: Data) -> [SketchPage]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = root["pagesAndArtboards"] as? [String: Any] else { return nil }

        var pages: [SketchPage] = []
        for (pageID, value) in table {
            guard let page = value as? [String: Any] else { continue }
            var artboards: [SketchArtboard] = []
            if let items = page["artboards"] as? [String: Any] {
                for (artID, artValue) in items {
                    let art = artValue as? [String: Any] ?? [:]
                    artboards.append(SketchArtboard(objectID: artID,
                                                    name: clean(art["name"]),
                                                    kind: "artboard"))
                }
            }
            artboards.sort { $0.name < $1.name }
            pages.append(SketchPage(id: pageID, name: clean(page["name"]), artboards: artboards))
        }
        return pages
    }

    // MARK: - 图层树回退通道

    private static func parseLayerTree(documentJSON: Data, reader: ZipReader) throws -> [SketchPage] {
        guard let root = try JSONSerialization.jsonObject(with: documentJSON) as? [String: Any] else {
            return []
        }

        var orderedNames: [String] = []
        if let refs = root["pages"] as? [[String: Any]] {
            for ref in refs {
                if let path = ref["_ref"] as? String {
                    orderedNames.append((path as NSString).lastPathComponent)
                }
            }
        }

        var available = reader.memberNames(prefix: "pages/", suffix: ".json")
        var ordered: [String] = []
        for stem in orderedNames {
            if let match = available.first(where: { ($0 as NSString).lastPathComponent == stem + ".json" }) {
                ordered.append(match)
                available.removeAll { $0 == match }
            }
        }
        ordered.append(contentsOf: available)

        var pages: [SketchPage] = []
        for member in ordered {
            guard let data = try? reader.read(member),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let objectID = (page["do_objectID"] as? String)
                ?? ((member as NSString).lastPathComponent as NSString).deletingPathExtension
            var artboards: [SketchArtboard] = []
            collectArtboards(page["layers"], into: &artboards)
            pages.append(SketchPage(id: objectID, name: clean(page["name"]), artboards: artboards))
        }
        return pages
    }

    private static func collectArtboards(_ layers: Any?, into result: inout [SketchArtboard]) {
        guard let layers = layers as? [[String: Any]] else { return }
        for layer in layers {
            let klass = layer["_class"] as? String ?? ""
            if klass == "artboard" || klass == "symbolMaster" {
                result.append(SketchArtboard(objectID: layer["do_objectID"] as? String ?? "",
                                             name: clean(layer["name"]),
                                             kind: klass == "symbolMaster" ? "symbol" : "artboard"))
            }
            collectArtboards(layer["layers"], into: &result)
        }
    }

    // MARK: - 旧版文件夹形式

    private static func parseFolder(_ url: URL) throws -> SketchDocument {
        var document = SketchDocument()
        let documentURL = url.appendingPathComponent("document.json")
        guard let data = try? Data(contentsOf: documentURL) else {
            document.error = "文件夹里没有 document.json"
            return document
        }

        var orderedFiles: [URL] = []
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let refs = root["pages"] as? [[String: Any]] {
            for ref in refs {
                if let path = ref["_ref"] as? String {
                    orderedFiles.append(url.appendingPathComponent(path + ".json"))
                }
            }
        }
        let pagesDir = url.appendingPathComponent("pages")
        if let listing = try? FileManager.default.contentsOfDirectory(at: pagesDir,
                                                                     includingPropertiesForKeys: nil) {
            for file in listing where file.pathExtension == "json" && !orderedFiles.contains(file) {
                orderedFiles.append(file)
            }
        }

        for file in orderedFiles {
            guard let pageData = try? Data(contentsOf: file),
                  let page = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else { continue }
            var artboards: [SketchArtboard] = []
            collectArtboards(page["layers"], into: &artboards)
            document.pages.append(SketchPage(id: page["do_objectID"] as? String ?? file.lastPathComponent,
                                             name: clean(page["name"]),
                                             artboards: artboards))
        }
        return document
    }

    /// 用于写入 Spotlight 的名字列表：页面名在前，画板名在后，去重并过滤占位名
    static func keywords(pages: [SketchPage], maxCount: Int, maxBytes: Int) -> (keywords: [String], candidates: Int) {
        return keywords(pageNames: pages.map { $0.name },
                        artboardNames: pages.flatMap { $0.artboards.map { $0.name } },
                        maxCount: maxCount, maxBytes: maxBytes)
    }

    /// 直接按两组名字构造关键词（索引存在数据库里，不必重新解析文件）
    static func keywords(pageNames: [String], artboardNames: [String],
                         maxCount: Int, maxBytes: Int) -> (keywords: [String], candidates: Int) {
        var seen = Set<String>()
        var ordered: [String] = []

        func push(_ raw: String) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 200 else { return }
            guard !isPlaceholder(name), !seen.contains(name) else { return }
            seen.insert(name)
            ordered.append(name)
        }

        for name in pageNames { push(name) }
        for name in artboardNames { push(name) }

        // 排序后再截断：Sketch 包里的页面/画板顺序在不同进程里可能不同，
        // 不排序会导致每次算出的关键词集合不一致，从而反复重写 Spotlight 属性。
        ordered.sort()

        var capped: [String] = []
        var used = 0
        for name in ordered {
            let cost = name.utf8.count + 8
            if capped.count >= maxCount || used + cost > maxBytes { break }
            capped.append(name)
            used += cost
        }
        return (capped, ordered.count)
    }
}
