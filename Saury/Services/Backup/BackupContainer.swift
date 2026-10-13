import Foundation
import Compression
import CryptoKit

/// 完整备份的文件容器：清单 + 分块，每块单独压缩。
///
/// 为什么不是一坨 JSON 字符串：图标是图片，塞进 JSON 只能转 base64，
/// 一份带几十个图标的备份立刻胖三分之一，还得整个读进内存才认得出坏在哪。
/// 这里把「清单」和「内容」分开：清单说清楚有哪几块、每块多大、SHA-256 是多少，
/// 读的时候一块一块校验，哪块坏了报哪块。
///
/// 文件格式：
/// ```
/// "SAURYBAK" | 容器版本 UInt8
/// 清单块：SHA-256(未压缩清单) | u32le 未压缩长度 | u32le 压缩后长度 | 压缩数据
/// 之后按清单里的顺序，每块：u32le 名字长度 | 名字 UTF8 | 同上三样 + 压缩数据
/// ```
///
/// 清单自己的摘要记在文件头而不是清单内部：让清单写自己的 SHA-256 就成了
/// 先有鸡还是先有蛋，填进去的永远是改了值之后的另一份数据。
/// 分块的摘要记在清单里，那是「别的块」的信息，不存在自指。
enum BackupContainer {
    static let magic = Data("SAURYBAK".utf8)
    /// 容器格式版本，和备份内容的 `schemaVersion` 是两回事。
    static let containerVersion: UInt8 = 1

    struct Part {
        let name: String
        let data: Data
    }

    enum Failure: LocalizedError, Equatable {
        case notABackupFile
        case unsupportedContainerVersion(UInt8)
        case manifestUnreadable
        case manifestCorrupted
        case partOrderMismatch(expected: String, found: String)
        case partCorrupted(String)
        case truncated
        case deflateFailed(Int)

        var errorDescription: String? {
            switch self {
            case .notABackupFile: return "这不是 Saury 的备份文件（文件头对不上）"
            case .unsupportedContainerVersion(let version): return "备份容器版本 \(version) 这个版本的 App 读不了"
            case .manifestUnreadable: return "备份清单读不出来，文件可能已经损坏"
            case .manifestCorrupted: return "备份清单校验没过，文件可能已经损坏"
            case .partOrderMismatch(let expected, let found): return "备份里「\(expected)」这一块的位置不对，那个位置上是「\(found)」"
            case .partCorrupted(let name): return "备份里「\(name)」这一块校验没过，内容已经损坏"
            case .truncated: return "备份文件被截断了，后半截不在文件里"
            case .deflateFailed(let length): return "有 \(length) 字节的数据压不出结果，这次备份没打成"
            }
        }
    }

    /// 同一套「读一块」的逻辑给清单和分块共用，只为出错时报对那句话。
    private enum BlockKind {
        case manifest
        case part(String)

        enum Problem { case undecodable, digestMismatch, lengthMismatch }

        func failure(_ problem: Problem) -> Failure {
            switch (self, problem) {
            case (.manifest, .undecodable): return .manifestUnreadable
            case (.manifest, .digestMismatch), (.manifest, .lengthMismatch): return .manifestCorrupted
            case (.part(let name), _): return .partCorrupted(name)
            }
        }
    }

    /// 把清单和分块各自压缩、按上面的格式拼成一个文件。
    /// 任何一块压不动都整体失败：宁可现在报「备份没打成」，
    /// 也不要写出一份自己下次读会报「已损坏」的包。
    static func write(manifest manifestData: Data, parts: [Part]) throws -> Data {
        var out = Data()
        out.append(magic)
        out.append(containerVersion)
        try appendBlock(manifestData, to: &out)
        for part in parts {
            let name = Data(part.name.utf8)
            out.append(lengthOf(name.count))
            out.append(name)
            try appendBlock(part.data, to: &out)
        }
        return out
    }

    private static func appendBlock(_ plain: Data, to out: inout Data) throws {
        let body = try deflate(plain) ?? { throw Failure.deflateFailed(plain.count) }()
        out.append(Data(SHA256.hash(data: plain)))
        out.append(lengthOf(plain.count))
        out.append(lengthOf(body.count))
        out.append(body)
    }

    // MARK: - 解包

    /// 清单和分块都要过校验才返回。任何一块对不上就整个失败 ——
    /// 半套备份恢复进库里，比不恢复更难收拾。
    static func read(_ file: Data) throws -> (manifest: BackupManifest, parts: [String: Data]) {
        let decoded = try decodeManifest(try readManifestBlock(file))

        var cursor = file.startIndex
        cursor = file.index(cursor, offsetBy: magic.count + 1)
        _ = try readBlockHeader(file, from: &cursor)   // 清单已经读过了，把游标推到第一块内容

        var parts: [String: Data] = [:]
        for expected in decoded.parts {
            guard cursor < file.endIndex else { throw Failure.truncated }
            let name = String(decoding: try readBytes(file, count: try readLength(file, from: &cursor), from: &cursor), as: UTF8.self)
            guard name == expected.name else {
                throw Failure.partOrderMismatch(expected: expected.name, found: name)
            }
            let header = try readBlockHeader(file, from: &cursor)
            parts[expected.name] = try decode(header,
                                             sha256: expected.sha256,
                                             byteLength: expected.byteLength,
                                             kind: .part(expected.name))
        }
        return (decoded, parts)
    }

    /// 只读清单，不碰分块：导入预览要先告诉用户这份备份里有什么，再决定读不读图标。
    static func readManifest(_ file: Data) throws -> BackupManifest {
        try decodeManifest(try readManifestBlock(file))
    }

    private static func readManifestBlock(_ file: Data) throws -> Data {
        var cursor = file.startIndex
        guard file.count >= magic.count + 5, file[cursor..<file.index(cursor, offsetBy: magic.count)] == magic else {
            throw Failure.notABackupFile
        }
        cursor = file.index(cursor, offsetBy: magic.count)
        let version = file[cursor]
        guard version == containerVersion else {
            throw Failure.unsupportedContainerVersion(version)
        }
        cursor = file.index(after: cursor)
        // 清单的摘要在文件头里，块里另两份（清单内的 parts 摘要）由 read 负责。
        return try decode(try readBlockHeader(file, from: &cursor),
                          sha256: nil, byteLength: nil, kind: .manifest)
    }

    private static func decodeManifest(_ data: Data) throws -> BackupManifest {
        do {
            return try JSONDecoder.backup.decode(BackupManifest.self, from: data)
        } catch {
            throw Failure.manifestUnreadable
        }
    }

    private struct BlockHeader {
        let digest: Data
        /// 块头里记的未压缩长度。
        let plainLength: Int
        let body: Data
    }

    private static func readBlockHeader(_ file: Data, from cursor: inout Data.Index) throws -> BlockHeader {
        let digest = try readBytes(file, count: 32, from: &cursor)
        let plainLength = try readLength(file, from: &cursor)
        let body = try readBytes(file, count: try readLength(file, from: &cursor), from: &cursor)
        return BlockHeader(digest: digest, plainLength: plainLength, body: body)
    }

    /// 块头摘要必查；清单里另记了一份十六进制摘要和原始长度，两处都对得上才放行。
    private static func decode(_ block: BlockHeader, sha256: String?, byteLength: Int?,
                               kind: BlockKind) throws -> Data {
        guard let plain = inflate(block.body, expected: block.plainLength) else {
            throw kind.failure(.undecodable)
        }
        guard block.digest == Data(SHA256.hash(data: plain)) else {
            throw kind.failure(.digestMismatch)
        }
        if let byteLength, byteLength != block.plainLength {
            throw kind.failure(.lengthMismatch)
        }
        if let sha256, sha256.lowercased() != Self.sha256(plain) {
            throw kind.failure(.digestMismatch)
        }
        return plain
    }

    // MARK: - 校验和读写的公共件

    static func sha256(_ data: Data) -> String {
        data.withUnsafeBytes { raw in
            SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func lengthOf(_ length: Int) -> Data {
        var value = UInt32(length).littleEndian
        return Data(bytes: &value, count: 4)
    }

    private static func readLength(_ file: Data, from cursor: inout Data.Index) throws -> Int {
        Int(UInt32(littleEndian: try readBytes(file, count: 4, from: &cursor).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }))
    }

    private static func readBytes(_ file: Data, count: Int, from cursor: inout Data.Index) throws -> Data {
        let end = file.index(cursor, offsetBy: count, limitedBy: file.endIndex) ?? file.endIndex
        guard file.distance(from: cursor, to: end) == count else { throw Failure.truncated }
        defer { cursor = end }
        return file.subdata(in: cursor..<end)
    }
}

// MARK: - deflate

extension BackupContainer {
    /// deflate 的最坏情况输出长度。
    ///
    /// SDK 的 `Compression` 模块只暴露 `compression_encode_buffer` / `compression_decode_buffer`，
    /// 那个算上界的 `compression_encode_bound` 在 Swift 里取不到，所以按 zlib 存一块（stored block）
    /// 的开销自己算：每 65535 字节最多多 5 字节，再留固定头的余量。
    private static func encodeBound(_ length: Int) -> Int { length + length / 1000 + 128 }

    /// 压不动或者上界不够时返回 nil：调用方必须把这当成打包失败，
    /// 原样塞进去反而更糟 —— 读的时候按压缩去解，一定报「已损坏」。
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let bound = encodeBound(data.count)
        var out = Data(count: bound)
        let written = data.withUnsafeBytes { source -> Int in
            guard let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return out.withUnsafeMutableBytes { target in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(to, bound, from, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    /// 按块头里记的原始长度解。长度对不上就是坏了，不当「还能凑合读」。
    static func inflate(_ data: Data, expected: Int) -> Data? {
        if expected == 0 { return data.isEmpty ? Data() : nil }
        guard !data.isEmpty else { return nil }
        var out = Data(count: expected)
        let written = data.withUnsafeBytes { source -> Int in
            guard let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return out.withUnsafeMutableBytes { target in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, expected, from, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == expected ? out : nil
    }
}

extension JSONDecoder {
    /// 备份和导出的日期一律 ISO8601：换机器、换语言设置都不该改变读出来的时间。
    static var backup: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var backup: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
