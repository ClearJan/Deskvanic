import Compression
import Foundation
import DeskvanicCore

/// 自研 ZIP 归档读写（无第三方依赖）。
/// 支持：store(0)/deflate(8)、UTF-8 文件名、目录条目、CRC 校验、路径穿越防护、
/// 符号链接拒绝、炸弹防护、同名冲突不覆盖。
/// 明确不支持：ZIP64（>4GB 单文件/条目数 > 65535 时如实报错）、加密归档。
public enum ZIPArchive {

    // MARK: - 条目模型

    public struct Entry: Sendable {
        public let name: String
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let crc32: UInt32
        public let method: UInt16      // 0=store, 8=deflate
        public let isDirectory: Bool
        public let isSymlink: Bool
        public let isEncrypted: Bool
        public let isZip64: Bool
        public let localHeaderOffset: UInt64
    }

    public struct ExtractOptions: Sendable {
        /// 单文件解压上限（炸弹防护）。
        public var maxUncompressedSize: UInt64 = 2 * 1024 * 1024 * 1024
        /// 总解压上限。
        public var maxTotalSize: UInt64 = 10 * 1024 * 1024 * 1024

        public init() {}
    }

    public struct ExtractReport: Sendable {
        public let extracted: [URL]
        /// 被拒绝的条目及原因（symlink / 路径穿越 / ZIP64 等）。
        public let rejected: [(name: String, reason: String)]
    }

    // MARK: - 错误

    enum ZIPError: Error, CustomStringConvertible {
        case notAZIPFile
        case eocdNotFound
        case unsupportedMethod(UInt16, name: String)
        case encrypted(name: String)
        case zip64NotSupported(name: String)
        case crcMismatch(name: String, expected: UInt32, actual: UInt32)
        case sizeMismatch(name: String)
        case diskCountNotOne

        var description: String {
            switch self {
            case .notAZIPFile: return "不是有效的 ZIP 文件"
            case .eocdNotFound: return "找不到归档目录（EOCD），文件可能损坏"
            case .unsupportedMethod(let m, let name): return "条目 \(name) 使用了不支持的压缩方法 \(m)"
            case .encrypted(let name): return "条目 \(name) 已加密，本应用不支持解密归档"
            case .zip64NotSupported(let name): return "条目 \(name) 使用 ZIP64 扩展（>4GB），暂不支持"
            case .crcMismatch(let name, let e, let a): return "条目 \(name) CRC 校验失败（期望 \(e)，实际 \(a)）"
            case .sizeMismatch(let name): return "条目 \(name) 解压后大小与声明不符"
            case .diskCountNotOne: return "归档声明多磁盘（损坏或不支持的格式）"
            }
        }
    }

    // MARK: - 常量

    private static let localHeaderSignature: UInt32 = 0x0403_4B50   // PK\x03\x04
    private static let centralSignature: UInt32 = 0x0201_4B50       // PK\x01\x02
    private static let eocdSignature: UInt32 = 0x0605_4B50          // PK\x05\x06

    // MARK: - 读取

    /// 解析中央目录。
    public static func entries(at url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { throw ZIPError.notAZIPFile }
        let eocd = try findEOCD(in: data)
        guard eocd.diskNumber == 0, eocd.diskWithCentralDirectory == 0 else {
            throw ZIPError.diskCountNotOne
        }
        var entries: [Entry] = []
        var offset = Int(eocd.centralDirectoryOffset)
        for _ in 0..<eocd.entryCount {
            guard offset + 46 <= data.count else { throw ZIPError.eocdNotFound }
            guard readUInt32(data, offset) == centralSignature else { throw ZIPError.eocdNotFound }
            let flags = readUInt16(data, offset + 8)
            let method = readUInt16(data, offset + 10)
            let crc = readUInt32(data, offset + 16)
            let compressedSize = UInt64(readUInt32(data, offset + 20))
            let uncompressedSize = UInt64(readUInt32(data, offset + 24))
            let nameLength = Int(readUInt16(data, offset + 28))
            let extraLength = Int(readUInt16(data, offset + 30))
            let commentLength = Int(readUInt16(data, offset + 32))
            let externalAttributes = readUInt32(data, offset + 38)
            let localOffset = UInt64(readUInt32(data, offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw ZIPError.eocdNotFound }

            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""

            let unixMode = (externalAttributes >> 16) & 0o170000
            let isSymlink = unixMode == 0o120000
            let isDirectory = name.hasSuffix("/") || unixMode == 0o040000
            // ZIP64 探测：0xFFFFFFFF 哨兵值——标记而非中断，解压阶段逐条目拒绝（审计 #13）
            let isZip64 = compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF
                || localOffset == 0xFFFF_FFFF
            let isEncrypted = flags & 0x0001 != 0

            entries.append(Entry(
                name: name, compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                crc32: crc, method: method, isDirectory: isDirectory, isSymlink: isSymlink,
                isEncrypted: isEncrypted, isZip64: isZip64,
                localHeaderOffset: localOffset))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// 解压到指定目录。安全策略：穿越/绝对路径/symlink 条目拒绝并记录，其余继续。
    public static func extract(
        archiveAt url: URL, to directory: URL, options: ExtractOptions = ExtractOptions()
    ) throws -> ExtractReport {
        guard FileSafety.isContained(directory.appendingPathComponent("x"), in: directory) else {
            throw DeskvanicError(.invalidInput, "目标目录无效")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try entries(at: url)

        var extracted: [URL] = []
        var rejected: [(String, String)] = []
        var totalUncompressed: UInt64 = 0

        for entry in entries {
            // 路径安全
            guard FileSafety.validateRelativeEntry(entry.name) else {
                rejected.append((entry.name, "路径穿越或非法路径"))
                continue
            }
            if entry.isSymlink {
                rejected.append((entry.name, "拒绝符号链接条目"))
                continue
            }
            if entry.isEncrypted {
                rejected.append((entry.name, "不支持加密条目"))
                continue
            }
            if entry.isZip64 {
                rejected.append((entry.name, "不支持 ZIP64 条目（>4GB）"))
                continue
            }
            if entry.uncompressedSize > options.maxUncompressedSize {
                rejected.append((entry.name, "超出单文件大小上限"))
                continue
            }
            totalUncompressed += entry.uncompressedSize
            if totalUncompressed > options.maxTotalSize {
                throw DeskvanicError(.outputValidationFailed, "总解压大小超出安全上限，已中止")
            }

            let target = directory.appendingPathComponent(entry.name)

            // 目标不得逃逸（二次复核，防 8.3 短名等边界）
            guard FileSafety.isContained(target, in: directory) else {
                rejected.append((entry.name, "解析后路径逃逸"))
                continue
            }

            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                extracted.append(target)
                continue
            }

            // 读取本地头中的数据
            let localOffset = Int(entry.localHeaderOffset)
            guard localOffset + 30 <= data.count,
                  readUInt32(data, localOffset) == localHeaderSignature else {
                throw DeskvanicError(.fileUnreadable, "条目 \(entry.name) 本地头损坏")
            }
            let localNameLength = Int(readUInt16(data, localOffset + 26))
            let localExtraLength = Int(readUInt16(data, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + Int(entry.compressedSize) <= data.count else {
                throw DeskvanicError(.fileUnreadable, "条目 \(entry.name) 数据越界")
            }
            let compressed = data.subdata(in: dataStart..<(dataStart + Int(entry.compressedSize)))

            let uncompressed: Data
            switch entry.method {
            case 0:
                uncompressed = compressed
            case 8:
                uncompressed = try inflate(compressed, expectedSize: entry.uncompressedSize, name: entry.name)
            case let method:
                throw ZIPError.unsupportedMethod(method, name: entry.name)
            }

            // 大小与 CRC 校验
            guard UInt64(uncompressed.count) == entry.uncompressedSize else {
                throw ZIPError.sizeMismatch(name: entry.name)
            }
            let actualCRC = CRC32.checksum(uncompressed)
            guard actualCRC == entry.crc32 else {
                throw ZIPError.crcMismatch(name: entry.name, expected: entry.crc32, actual: actualCRC)
            }

            // 同名冲突：不覆盖
            let finalTarget = FileSafety.uniqueDestination(
                in: target.deletingLastPathComponent(), preferredName: target.lastPathComponent)
            try FileManager.default.createDirectory(
                at: finalTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
            try uncompressed.write(to: finalTarget, options: .atomic)
            extracted.append(finalTarget)
        }
        return ExtractReport(extracted: extracted, rejected: rejected)
    }

    // MARK: - 写入

    public struct CreateOptions: Sendable {
        /// true：保留传入路径的相对结构；false：全部放在根目录（仅文件名）。
        public var keepRelativePaths: Bool = false
        public init(keepRelativePaths: Bool = false) {
            self.keepRelativePaths = keepRelativePaths
        }
    }

    /// 创建 ZIP（先写临时文件，成功并重读校验后原子改名）。
    public static func createArchive(
        at destination: URL, adding files: [URL], options: CreateOptions = CreateOptions()
    ) throws {
        guard !files.isEmpty else {
            throw DeskvanicError(.invalidInput, "未提供要压缩的文件")
        }
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            throw DeskvanicError(.fileNotFound, "文件不存在：\(file.lastPathComponent)")
        }

        let tempDestination = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempDestination.path, contents: nil)

        var centralRecords: [Data] = []
        var entryCount: UInt16 = 0
        var currentOffset: UInt32 = 0

        let output = FileHandle(forWritingAtPath: tempDestination.path)
        guard let output else {
            throw DeskvanicError(.fileWriteFailed, "无法创建临时归档文件")
        }
        defer { try? output.close() }

        // 公共前缀（用于相对路径）
        let commonPrefix: String?
        if options.keepRelativePaths, files.count > 1 {
            let components = files.map { $0.deletingLastPathComponent().standardizedFileURL.path }
            commonPrefix = commonPathPrefix(components)
        } else {
            commonPrefix = nil
        }

        for file in files {
            let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let entryName: String
            if isDirectory {
                entryName = relativeName(for: file, prefix: commonPrefix) + "/"
            } else {
                entryName = relativeName(for: file, prefix: commonPrefix)
            }
            guard FileSafety.validateRelativeEntry(entryName) else {
                throw DeskvanicError(.invalidInput, "生成的条目名非法：\(entryName)")
            }

            let content: Data
            let crc: UInt32
            let uncompressedSize: UInt32
            if isDirectory {
                content = Data()
                crc = 0
                uncompressedSize = 0
            } else {
                content = try Data(contentsOf: file, options: .mappedIfSafe)
                guard content.count < Int(UInt32.max) else {
                    throw DeskvanicError(.invalidInput, "文件超过 4GB，暂不支持（ZIP64）：\(file.lastPathComponent)")
                }
                crc = CRC32.checksum(content)
                uncompressedSize = UInt32(content.count)
            }

            let compressed: Data
            let method: UInt16
            if uncompressedSize == 0 {
                compressed = content
                method = 0
            } else {
                let deflated = try deflate(content)
                if deflated.count < content.count {
                    compressed = deflated
                    method = 8
                } else {
                    compressed = content
                    method = 0
                }
            }
            guard compressed.count < Int(UInt32.max) else {
                throw DeskvanicError(.invalidInput, "压缩后数据超限：\(file.lastPathComponent)")
            }

            let nameData = Data(entryName.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw DeskvanicError(.invalidInput, "文件名过长：\(entryName)")
            }
            let (dosTime, dosDate) = dosTimestamp(for: file)

            // 本地文件头
            var lfh = Data()
            lfh.appendLE(localHeaderSignature)
            lfh.appendLE(UInt16(20))            // version needed
            lfh.appendLE(UInt16(0x0800))        // UTF-8 flag
            lfh.appendLE(method)
            lfh.appendLE(dosTime)
            lfh.appendLE(dosDate)
            lfh.appendLE(crc)
            lfh.appendLE(UInt32(compressed.count))
            lfh.appendLE(uncompressedSize)
            lfh.appendLE(UInt16(nameData.count))
            lfh.appendLE(UInt16(0))             // extra length
            lfh.append(nameData)
            try output.write(contentsOf: lfh)
            try output.write(contentsOf: compressed)

            // 中央目录记录
            var cd = Data()
            cd.appendLE(centralSignature)
            cd.appendLE(UInt16(0x031E))         // version made by (Unix)
            cd.appendLE(UInt16(20))
            cd.appendLE(UInt16(0x0800))
            cd.appendLE(method)
            cd.appendLE(dosTime)
            cd.appendLE(dosDate)
            cd.appendLE(crc)
            cd.appendLE(UInt32(compressed.count))
            cd.appendLE(uncompressedSize)
            cd.appendLE(UInt16(nameData.count))
            cd.appendLE(UInt16(0))              // extra
            cd.appendLE(UInt16(0))              // comment
            cd.appendLE(UInt16(0))              // disk number
            cd.appendLE(UInt16(0))              // internal attrs
            cd.appendLE(UInt32(isDirectory ? (0o040755 << 16) : (0o100644 << 16)))
            cd.appendLE(currentOffset)
            cd.append(nameData)
            centralRecords.append(cd)

            let recordSize = lfh.count + compressed.count
            guard currentOffset <= UInt32.max - UInt32(recordSize) else {
                try? FileManager.default.removeItem(at: tempDestination)
                throw DeskvanicError(.invalidInput, "归档总体积超过 4GB（ZIP64 暂不支持），已清理临时文件")
            }
            currentOffset += UInt32(recordSize)
            entryCount += 1
        }

        // 中央目录 + EOCD
        let centralStart = currentOffset
        var centralSize: UInt32 = 0
        for record in centralRecords {
            try output.write(contentsOf: record)
            centralSize += UInt32(record.count)
        }
        var eocd = Data()
        eocd.appendLE(eocdSignature)
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(entryCount)
        eocd.appendLE(entryCount)
        eocd.appendLE(centralSize)
        eocd.appendLE(centralStart)
        eocd.appendLE(UInt16(0))   // comment length
        try output.write(contentsOf: eocd)
        try output.synchronize()

        // 重读校验：EOCD 可解析且条目数一致
        let verifyEntries = try entries(at: tempDestination)
        guard verifyEntries.count == Int(entryCount) else {
            try? FileManager.default.removeItem(at: tempDestination)
            throw DeskvanicError(.outputValidationFailed, "归档校验失败，已清理临时文件")
        }

        // 原子提交
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempDestination)
        } else {
            try FileManager.default.moveItem(at: tempDestination, to: destination)
        }
    }

    // MARK: - 压缩/解压（raw deflate）

    static func deflate(_ data: Data) throws -> Data {
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count + 64)
        defer { destinationBuffer.deallocate() }
        let written = compression_encode_buffer(
            destinationBuffer, data.count + 64,
            (data as NSData).bytes.bindMemory(to: UInt8.self, capacity: data.count),
            data.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else {
            // 压缩失败时回退 store（由调用方处理）
            return data
        }
        return Data(bytes: destinationBuffer, count: written)
    }

    static func inflate(_ data: Data, expectedSize: UInt64, name: String) throws -> Data {
        var output = Data()
        var bufferSize = max(64 * 1024, Int(expectedSize))
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        let written = compression_decode_buffer(
            destination, bufferSize,
            (data as NSData).bytes.bindMemory(to: UInt8.self, capacity: data.count),
            data.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else {
            throw DeskvanicError(.fileUnreadable, "条目 \(name) 解压失败（数据损坏）")
        }
        output.append(destination, count: written)
        return output
    }

    // MARK: - EOCD

    private struct EOCD {
        let diskNumber: UInt16
        let diskWithCentralDirectory: UInt16
        let entryCount: UInt16
        let centralDirectoryOffset: UInt32
    }

    /// 从文件尾向前搜索 EOCD（注释最长 65535 字节）。
    private static func findEOCD(in data: Data) throws -> EOCD {
        let searchLimit = min(data.count, 22 + 65_535)
        var offset = data.count - 22
        let lowerBound = data.count - searchLimit
        while offset >= lowerBound {
            if readUInt32(data, offset) == eocdSignature {
                let eocd = EOCD(
                    diskNumber: readUInt16(data, offset + 4),
                    diskWithCentralDirectory: readUInt16(data, offset + 6),
                    entryCount: readUInt16(data, offset + 10),
                    centralDirectoryOffset: readUInt32(data, offset + 16))
                return eocd
            }
            offset -= 1
        }
        throw ZIPError.eocdNotFound
    }

    // MARK: - 工具

    static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let bytes = data.subdata(in: offset..<(offset + 2))
        return UInt16(bytes[bytes.startIndex]) | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = data.subdata(in: offset..<(offset + 4))
        return UInt32(bytes[bytes.startIndex])
            | (UInt32(bytes[bytes.startIndex + 1]) << 8)
            | (UInt32(bytes[bytes.startIndex + 2]) << 16)
            | (UInt32(bytes[bytes.startIndex + 3]) << 24)
    }

    private static func relativeName(for file: URL, prefix: String?) -> String {
        if let prefix, file.path.hasPrefix(prefix + "/") {
            return String(file.path.dropFirst(prefix.count + 1))
        }
        return file.lastPathComponent
    }

    static func commonPathPrefix(_ paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        var prefix = first
        for path in paths {
            while !path.hasPrefix(prefix) {
                guard let lastSlash = prefix.lastIndex(of: "/") else { return nil }
                prefix = String(prefix[..<lastSlash])
            }
        }
        return prefix.isEmpty ? nil : prefix
    }

    private static func dosTimestamp(for url: URL) -> (UInt16, UInt16) {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, components.year ?? 1980))
        let dosDate = UInt16(((year - 1980) << 9)
            | ((components.month ?? 1) << 5)
            | (components.day ?? 1))
        let dosTime = UInt16(((components.hour ?? 0) << 11)
            | ((components.minute ?? 0) << 5)
            | ((components.second ?? 0) / 2))
        return (dosTime, dosDate)
    }
}

/// CRC-32（标准查表实现）。
public enum CRC32 {
    private static let table: [UInt32] = {
        (0...255).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<raw.count {
                crc = table[Int((crc ^ UInt32(base[i])) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
