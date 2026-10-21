import Foundation
import zlib

/// gzip 压缩。
///
/// 为什么不用 `NSData.compressed(using: .zlib)`：那个产出的是 **zlib 包装**（带 2 字节头），
/// 而 Sketch 的剪贴板格式要的是 **gzip 包装**（`1f 8b 08 ...`）。两者都用 deflate 压缩数据，
/// 但外层容器不同 —— 给错容器 Sketch 会直接认不出来，表现为"粘贴没反应"。
///
/// zlib 里用 `windowBits = 15 + 16` 即可让它输出 gzip 容器。
enum Gzip {

    /// 压缩为 gzip。失败返回 nil。
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        var stream = z_stream()
        let windowBits = Int32(15 + 16) // MAX_WBITS + 16 → gzip 容器
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8,
                            Z_DEFAULT_STRATEGY, zlibVersion(),
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }

        let bufferSize = 1 << 16
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var output = Data()

        let status: Int32 = data.withUnsafeBytes { raw -> Int32 in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            var result: Int32 = Z_OK
            repeat {
                result = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(bufferSize)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = bufferSize - Int(stream.avail_out)
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
            } while result == Z_OK && stream.avail_out == 0
            return result
        }

        guard status == Z_STREAM_END || status == Z_OK else { return nil }
        return output
    }
}
