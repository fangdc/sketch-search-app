import Foundation

/// 极简文件日志：出问题时可以直接看
/// ~/Library/Application Support/SketchSearch/sketchsearch.log
enum Log {
    private static let queue = DispatchQueue(label: "com.sksearch.log")

    static var fileURL: URL {
        AppSettings.supportDirectory.appendingPathComponent("sketchsearch.log")
    }

    static func write(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: AppSettings.supportDirectory,
                                         withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
