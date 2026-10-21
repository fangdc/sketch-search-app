import AppKit
import Foundation

/// 「拷贝矢量画板」：把 .sketch 文件里某个画板的**原始图层数据**按 Sketch 的原生
/// 剪贴板格式写进系统剪贴板。粘到别的 Sketch 文件里是**可编辑的原生图层**，不是图片。
///
/// 格式是从实测里反推出来的（在 Sketch 里复制一个画板，然后 dump 剪贴板）：
///
///     type  com.bohemiancoding.sketch.v3  →  gzip 压缩的 UTF-8 JSON
///     JSON  { layers: [...], sharedStyles: [...], localSymbols: {...},
///             foreignSymbols: {...}, sharedSwatches: [...],
///             position / absolutePosition / alignmentRectSize / ... ,
///             modelVersion, pasteboardVersion, pageID }
///
/// 其中 `layers` 就是 `pages/*.json` 里那种图层 JSON，原样搬过来即可；
/// 其余字段是 Sketch 重建图层时需要的上下文 —— 共享样式、Symbol、色板。
/// 实测缺了这些上下文，Sketch 会因为"解析不出 symbolInstance / sharedStyleID"
/// 而**静默失败**（粘贴毫无反应），所以必须一并带上。
enum SketchClipboard {

    enum Failure: LocalizedError {
        case cannotOpen(String)
        case artboardNotFound
        case emptyPayload

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let path): return "打不开 Sketch 文件：\(path)"
            case .artboardNotFound: return "在文件里找不到这个画板（可能已被修改或删除）"
            case .emptyPayload: return "画板数据为空"
            }
        }
    }

    struct Outcome {
        let layerCount: Int
        let rawBytes: Int
        let compressedBytes: Int
    }

    static let typeV3 = NSPasteboard.PasteboardType("com.bohemiancoding.sketch.v3")
    static let typeV4Temp = NSPasteboard.PasteboardType("com.bohemiancoding.sketch.v4.tempfile")
    static let typeV3Temp = NSPasteboard.PasteboardType("com.bohemiancoding.sketch.v3.tempfile")

    /// Sketch 当前模型的版本号（复制一个画板时它写的就是 182 / pasteboardVersion 7）
    private static let modelVersion = 182
    private static let pasteboardVersion = 7

    // MARK: - 对外入口

    /// 从 filePath 里取出 objectID 对应的画板，写进剪贴板。
    /// 需要在后台队列调用（要读整个 .sketch，大文件可能要一两秒）。
    static func copyArtboard(filePath: String, objectID: String) throws -> Outcome {
        let url = URL(fileURLWithPath: filePath)
        guard let reader = try? ZipReader(url: url) else {
            throw Failure.cannotOpen(filePath)
        }

        // 1. 在各页面里找目标画板，同时收集本文件的 symbolMaster（localSymbols）
        var artboard: [String: Any]?
        var pageID = ""
        var localSymbols: [String: Any] = [:]
        var pageData: [[String: Any]] = []

        for member in reader.memberNames(prefix: "pages/", suffix: ".json") {
            guard let data = try? reader.read(member),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            pageData.append(page)
            if let found = findLayer(page["layers"], objectID: objectID) {
                artboard = found
                pageID = (page["do_objectID"] as? String)
                    ?? ((member as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            collectSymbolMasters(page["layers"], into: &localSymbols)
        }

        guard let artboard = artboard else { throw Failure.artboardNotFound }

        // 1.5 图片改为内联 base64（否则粘出来图片全丢）
        let artboardWithImages = inlineImages(artboard, reader: reader) as? [String: Any] ?? artboard
        localSymbols = localSymbols.mapValues { inlineImages($0, reader: reader) }

        // 2. 文档级的共享资源（共享样式 / 外部符号 / 色板）
        var sharedStyles: [Any] = []
        var sharedSwatches: [Any] = []
        var foreignSymbols: [String: Any] = [:]
        if let data = try? reader.read("document.json"),
           let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            sharedStyles = objects(document["foreignLayerStyles"]) + objects(document["foreignTextStyles"])
            sharedSwatches = objects(document["foreignSwatches"]) + objects(document["sharedSwatches"])
            for item in objects(document["foreignSymbols"]) {
                if let dict = item as? [String: Any],
                   let key = (dict["symbolID"] as? String) ?? (dict["do_objectID"] as? String) {
                    foreignSymbols[key] = dict
                }
            }
        }

        // 3. 组装信封。位置信息按画板自身的 frame 填 —— Sketch 用它决定"粘贴到原位"
        let frame = artboard["frame"] as? [String: Any] ?? [:]
        let x = double(frame["x"]), y = double(frame["y"])
        let width = double(frame["width"]), height = double(frame["height"])
        let point: [String: Any] = ["_class": "NSValue", "type": "point",
                                    "value": "{\(x), \(y)}"]
        let center: [String: Any] = ["_class": "NSValue", "type": "point",
                                     "value": "{\(x + width / 2), \(y + height / 2)}"]

        let payload: [String: Any] = [
            "layers": [artboardWithImages],
            "position": point,
            "relativePositions": [point],
            "absolutePosition": point,
            "absoluteCenters": [objectID: center],
            "alignmentRectSize": ["_class": "NSValue", "type": "size",
                                  "value": "{\(width), \(height)}"],
            "sharedStyles": sharedStyles,
            "sharedSwatches": sharedSwatches,
            "foreignSymbols": foreignSymbols,
            "localSymbols": localSymbols,
            "parentAddress": 0,
            "parentTraits": 4292608,
            // 复制时 Sketch 写的是 "{}" 的 base64
            "distances": ["_data": Data("{}".utf8).base64EncodedString()],
            "modelVersion": modelVersion,
            "pasteboardVersion": pasteboardVersion,
            "pageID": pageID,
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let raw = try? JSONSerialization.data(withJSONObject: payload),
              let compressed = Gzip.compress(raw) else {
            throw Failure.emptyPayload
        }

        // 4. 写剪贴板。除主数据外还放一份临时文件路径 ——
        //    Sketch 复制时两者都给，走它的常规路径更保险。
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(compressed, forType: typeV3)
        if let tempPath = writeTemporaryPayload(compressed) {
            let pathData = Data(tempPath.utf8)
            item.setData(pathData, forType: typeV4Temp)
            item.setData(pathData, forType: typeV3Temp)
        }
        pasteboard.writeObjects([item])

        return Outcome(layerCount: 1, rawBytes: raw.count, compressedBytes: compressed.count)
    }

    // MARK: - 辅助

    /// 把图层 JSON 里对 `images/xxx` 的引用换成**内联 base64**。
    ///
    /// `.sketch` 文件里图片是分开存的（`images/` 目录），图层里只写一个引用：
    ///     {"_class":"MSJSONDataReference","_ref_class":"MSImageData","_ref":"images/ab12.jpg"}
    /// 而剪贴板里 Sketch 会把图片数据直接塞进去（实测 132MB 的剪贴板数据就是这么来的）：
    ///     {"_class":"MSJSONOriginalDataReference", ..., "data":{"_data":"<base64>"}}
    /// 不做这个转换，粘出来的画板里所有图片填充都会变成空白。
    private static func inlineImages(_ node: Any, reader: ZipReader) -> Any {
        if let dictionary = node as? [String: Any] {
            var result: [String: Any] = [:]
            result.reserveCapacity(dictionary.count + 1)
            for (key, value) in dictionary {
                result[key] = inlineImages(value, reader: reader)
            }
            // 不同版本的 Sketch 文件对图片引用的写法不一样（实测有 MSJSONDataReference
            // 和 MSJSONFileReference 两种），所以不看输入类名 —— 只要是指向 images/ 的
            // 图片引用就内联。输出统一成 Sketch 剪贴板里的写法。
            if (result["_ref_class"] as? String) == "MSImageData",
               result["data"] == nil,
               let reference = result["_ref"] as? String,
               reference.hasPrefix("images/"),
               let data = try? reader.read(reference) {
                result["_class"] = "MSJSONOriginalDataReference"
                result["data"] = ["_data": data.base64EncodedString()]
            }
            return result
        }
        if let array = node as? [Any] {
            return array.map { inlineImages($0, reader: reader) }
        }
        return node
    }

    private static func writeTemporaryPayload(_ data: Data) -> String? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sksearch-vector-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let file = directory.appendingPathComponent("\(UUID().uuidString)._sketch_pb")
        guard (try? data.write(to: file)) != nil else { return nil }
        return file.path
    }

    /// 清掉历史遗留的矢量拷贝临时目录（粘贴完成后 Sketch 会读它，所以要等一会再清）
    static func cleanStaleTemporaries(olderThan seconds: TimeInterval = 3600) {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let items = try? manager.contentsOfDirectory(at: base,
                                                           includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for item in items where item.lastPathComponent.hasPrefix("sksearch-vector-") {
            guard let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(date) > seconds else { continue }
            try? manager.removeItem(at: item)
        }
    }

    private static func objects(_ value: Any?) -> [Any] {
        if let dict = value as? [String: Any] { return dict["objects"] as? [Any] ?? [] }
        return value as? [Any] ?? []
    }

    private static func double(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return 0
    }

    /// 递归找 do_objectID 匹配的图层
    private static func findLayer(_ layers: Any?, objectID: String) -> [String: Any]? {
        guard let layers = layers as? [[String: Any]] else { return nil }
        for layer in layers {
            if (layer["do_objectID"] as? String) == objectID { return layer }
            if let found = findLayer(layer["layers"], objectID: objectID) { return found }
        }
        return nil
    }

    /// 收集本文件里所有 symbolMaster，键用实例引用时使用的 symbolID（没有就退回 do_objectID）
    private static func collectSymbolMasters(_ layers: Any?, into result: inout [String: Any]) {
        guard let layers = layers as? [[String: Any]] else { return }
        for layer in layers {
            if (layer["_class"] as? String) == "symbolMaster" {
                if let symbolID = layer["symbolID"] as? String { result[symbolID] = layer }
                if let objectID = layer["do_objectID"] as? String { result[objectID] = layer }
            }
            collectSymbolMasters(layer["layers"], into: &result)
        }
    }
}
