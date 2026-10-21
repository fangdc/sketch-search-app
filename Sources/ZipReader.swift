import Foundation
import zlib

/// .sketch 文件本质是 zip 包，只需要读出里面几个 JSON 成员。
/// 这里实现一个最小可用的 zip 读取器：解析中央目录 + 用 zlib 原始 deflate 解压，
/// 不依赖任何第三方库，也不调用外部进程。

struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
}

enum ZipError: LocalizedError {
    case notZip
    case truncated(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notZip: return "不是有效的 .sketch 包（找不到 zip 中央目录）"
        case .truncated(let detail): return "文件读取失败：\(detail)"
        case .unsupported(let detail): return "不支持的压缩格式：\(detail)"
        }
    }
}

final class ZipReader {
    private let handle: FileHandle
    private let fileSize: UInt64
    private(set) var entries: [String: ZipEntry] = [:]

    init(url: URL) throws {
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ZipError.truncated("无法打开文件（\(error.localizedDescription)）")
        }
        let size: UInt64
        do {
            size = try fileHandle.seekToEnd()
        } catch {
            try? fileHandle.close()
            throw ZipError.truncated("无法读取文件长度")
        }
        self.handle = fileHandle
        self.fileSize = size
        try loadCentralDirectory()
    }

    deinit {
        try? handle.close()
    }

    // MARK: - 小端读取

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = (value << 8) | UInt64(b[o + i])
        }
        return value
    }

    private func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0, offset + UInt64(count) <= fileSize else {
            throw ZipError.truncated("读取越界（offset=\(offset), count=\(count), size=\(fileSize)）")
        }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw ZipError.truncated("实际读取字节数不足")
            }
            return [UInt8](data)
        } catch let error as ZipError {
            throw error
        } catch {
            throw ZipError.truncated(error.localizedDescription)
        }
    }

    // MARK: - 中央目录

    private func loadCentralDirectory() throws {
        guard fileSize >= 22 else { throw ZipError.notZip }

        // 结尾记录（EOCD）位于文件末尾，注释最长 64KB
        let tailSize = Int(min(fileSize, 66_000))
        let tailStart = fileSize - UInt64(tailSize)
        let tail = try read(at: tailStart, count: tailSize)

        var eocdOffset = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.notZip }

        var entryCount = UInt64(ZipReader.u16(tail, eocdOffset + 10))
        var cdSize = UInt64(ZipReader.u32(tail, eocdOffset + 12))
        var cdOffset = UInt64(ZipReader.u32(tail, eocdOffset + 16))

        // ZIP64：Sketch 的大文件会用这种格式
        let needsZip64 = entryCount == 0xFFFF || cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF
        if needsZip64, eocdOffset >= 20 {
            let locator = eocdOffset - 20
            if tail[locator] == 0x50, tail[locator + 1] == 0x4B,
               tail[locator + 2] == 0x06, tail[locator + 3] == 0x07 {
                let z64Offset = ZipReader.u64(tail, locator + 8)
                let z = try read(at: z64Offset, count: 56)
                entryCount = ZipReader.u64(z, 32)
                cdSize = ZipReader.u64(z, 40)
                cdOffset = ZipReader.u64(z, 48)
            }
        }

        guard cdSize > 0, cdOffset < fileSize else { throw ZipError.notZip }
        let cd = try read(at: cdOffset, count: Int(min(cdSize, UInt64(fileSize - cdOffset))))

        var cursor = 0
        var parsed: UInt64 = 0
        while cursor + 46 <= cd.count, parsed < entryCount {
            guard ZipReader.u32(cd, cursor) == 0x02014B50 else { break }
            let method = ZipReader.u16(cd, cursor + 10)
            var compressedSize = UInt64(ZipReader.u32(cd, cursor + 20))
            var uncompressedSize = UInt64(ZipReader.u32(cd, cursor + 24))
            let nameLength = Int(ZipReader.u16(cd, cursor + 28))
            let extraLength = Int(ZipReader.u16(cd, cursor + 30))
            let commentLength = Int(ZipReader.u16(cd, cursor + 32))
            var localOffset = UInt64(ZipReader.u32(cd, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= cd.count else { break }
            let nameBytes = Array(cd[nameStart..<(nameStart + nameLength)])
            let name = String(decoding: nameBytes, as: UTF8.self)

            // ZIP64 扩展字段里存放超出 4GB / 65535 的真实值
            if uncompressedSize == 0xFFFFFFFF || compressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                var extra = nameStart + nameLength
                let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd, extra + 4 <= cd.count {
                    let fieldID = ZipReader.u16(cd, extra)
                    let fieldSize = Int(ZipReader.u16(cd, extra + 2))
                    if fieldID == 0x0001 {
                        var p = extra + 4
                        if uncompressedSize == 0xFFFFFFFF, p + 8 <= cd.count {
                            uncompressedSize = ZipReader.u64(cd, p); p += 8
                        }
                        if compressedSize == 0xFFFFFFFF, p + 8 <= cd.count {
                            compressedSize = ZipReader.u64(cd, p); p += 8
                        }
                        if localOffset == 0xFFFFFFFF, p + 8 <= cd.count {
                            localOffset = ZipReader.u64(cd, p); p += 8
                        }
                        break
                    }
                    extra += 4 + fieldSize
                }
            }

            entries[name] = ZipEntry(name: name, method: method,
                                     compressedSize: compressedSize,
                                     uncompressedSize: uncompressedSize,
                                     localHeaderOffset: localOffset)
            parsed += 1
            cursor = nameStart + nameLength + extraLength + commentLength
        }
    }

    // MARK: - 读取成员

    func contains(_ name: String) -> Bool {
        entries[name] != nil
    }

    func memberNames(prefix: String, suffix: String) -> [String] {
        entries.keys.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.sorted()
    }

    func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else {
            throw ZipError.truncated("包内没有成员 \(name)")
        }
        // 本地文件头长度可能与中央目录不同，必须按本地头部重新计算数据起点
        let header = try read(at: entry.localHeaderOffset, count: 30)
        guard ZipReader.u32(header, 0) == 0x04034B50 else {
            throw ZipError.truncated("成员 \(name) 的本地文件头无效")
        }
        let nameLength = Int(ZipReader.u16(header, 26))
        let extraLength = Int(ZipReader.u16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)

        guard entry.compressedSize <= UInt64(Int.max) else {
            throw ZipError.unsupported("成员过大")
        }
        let raw = try read(at: dataOffset, count: Int(entry.compressedSize))

        switch entry.method {
        case 0:
            return Data(raw)
        case 8:
            return try ZipReader.inflateRaw(raw, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError.unsupported("压缩方式 \(entry.method)（仅支持 store / deflate）")
        }
    }

    /// 原始 deflate（没有 zlib 头），窗口位固定 -15
    static func inflateRaw(_ input: [UInt8], expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }

        var stream = z_stream()
        guard inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ZipError.unsupported("inflateInit2 初始化失败")
        }
        defer { inflateEnd(&stream) }

        let inBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(input.count, 1))
        defer { inBuffer.deallocate() }
        if !input.isEmpty {
            input.withUnsafeBufferPointer { source in
                inBuffer.update(from: source.baseAddress!, count: input.count)
            }
        }

        let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { outBuffer.deallocate() }

        stream.next_in = inBuffer
        stream.avail_in = uInt(input.count)
        stream.next_out = outBuffer
        stream.avail_out = uInt(expectedSize)

        let status = inflate(&stream, Z_FINISH)
        guard status == Z_STREAM_END || status == Z_OK else {
            throw ZipError.unsupported("deflate 解压失败（zlib code \(status)）")
        }
        let produced = expectedSize - Int(stream.avail_out)
        return Data(bytes: outBuffer, count: produced)
    }
}
