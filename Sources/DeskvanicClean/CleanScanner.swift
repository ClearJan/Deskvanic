import AppKit
import CoreGraphics
import Foundation
import DeskvanicCore

/// Clean Manager：磁盘扫描、重复与相似检测、整理规则。
public enum CleanScanner {

    public struct DiskUsage: Sendable {
        public let volumeName: String
        public let totalBytes: Int64
        public let freeBytes: Int64
    }

    /// 卷信息（用于空间可视化）。
    public static func diskUsage(at url: URL) -> DiskUsage? {
        guard let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]) else {
            return nil
        }
        return DiskUsage(
            volumeName: values.volumeName ?? "未命名卷",
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            freeBytes: Int64(values.volumeAvailableCapacity ?? 0))
    }

    public struct BigFile: Identifiable, Hashable, Sendable {
        public var id: String { path }
        public let path: String
        public let name: String
        public let sizeBytes: Int64
        public let modifiedAt: Date?
    }

    /// 大文件统计（深度受限、不跟随符号链接、跳过隐藏与包内容）。
    public static func findBigFiles(
        in root: URL, topN: Int = 50, maxDepth: Int = 6, maxEntries: Int = 60_000
    ) -> [BigFile] {
        var results: [BigFile] = []
        let fm = FileManager.default
        let visitedInodes = NSHashTable<NSNumber>()

        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth, results.count < maxEntries else { return }
            // 循环防护：记录目录 inode
            if let inode = inodeNumber(dir) {
                if visitedInodes.contains(inode) { return }
                visitedInodes.add(inode)
            }
            guard let children = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for child in children {
                guard results.count < maxEntries else { return }
                let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    walk(child, depth: depth + 1)
                } else {
                    let size = Int64(values?.fileSize ?? 0)
                    if size > 0 {
                        results.append(BigFile(
                            path: child.path, name: child.lastPathComponent,
                            sizeBytes: size, modifiedAt: values?.contentModificationDate))
                    }
                }
            }
        }
        walk(root, depth: 1)
        return Array(results.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(topN))
    }

    private static func inodeNumber(_ url: URL) -> NSNumber? {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0 else { return nil }
        return NSNumber(value: fileStat.st_ino)
    }

    // MARK: - 完全重复检测（定义：逐字节 SHA-256 相同）

    public struct DuplicateGroup: Sendable {
        public let hash: String
        public let files: [BigFile]
        /// 建议保留项（最早修改的）。
        public var keeperPath: String {
            files.min { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }?.path ?? ""
        }
    }

    /// 完全重复：先按大小分组（快），再对同组做全量 SHA-256（不是抽样）。
    public static func findExactDuplicates(
        files: [BigFile], progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [DuplicateGroup] {
        var bySize: [Int64: [BigFile]] = [:]
        for file in files where file.sizeBytes > 0 {
            bySize[file.sizeBytes, default: []].append(file)
        }
        let candidates = bySize.values.filter { $0.count > 1 }
        var groups: [DuplicateGroup] = []
        var hashed = 0
        let total = candidates.reduce(0) { $0 + $1.count }
        for candidateGroup in candidates {
            var byHash: [String: [BigFile]] = [:]
            for file in candidateGroup {
                if let hash = try? FileSafety.sha256(of: URL(fileURLWithPath: file.path)) {
                    byHash[hash, default: []].append(file)
                }
                hashed += 1
                progress?(Double(hashed) / Double(max(total, 1)))
            }
            for (hash, same) in byHash where same.count > 1 {
                groups.append(DuplicateGroup(hash: hash, files: same))
            }
        }
        return groups.sorted { $0.files[0].sizeBytes * Int64($0.files.count) > $1.files[0].sizeBytes * Int64($1.files.count) }
    }

    // MARK: - 相似图片检测（定义：aHash 感知哈希汉明距离 ≤ 阈值）

    public struct SimilarImageGroup: Sendable {
        public let anchor: BigFile
        public let similar: [(file: BigFile, hammingDistance: Int)]
    }

    /// 感知哈希：8×8 灰度均值哈希（64 bit）。
    public static func averageHash(of url: URL, dimension: Int = 8) -> UInt64? {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // 缩放到 dimension×dimension（RGB），按亮度计算（设备灰度位图上下文 data 读取在本 SDK 上不稳定）
        let context = CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        guard let data = context.data else { return nil }
        let rowBytes = context.bytesPerRow
        let buffer = UnsafeRawBufferPointer(start: data, count: rowBytes * dimension)
        var luminance = [Double](repeating: 0, count: dimension * dimension)
        for y in 0..<dimension {
            for x in 0..<dimension {
                let offset = y * rowBytes + x * 4
                let r = Double(buffer[offset])
                let g = Double(buffer[offset + 1])
                let b = Double(buffer[offset + 2])
                luminance[y * dimension + x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }
        let mean = luminance.reduce(0, +) / Double(dimension * dimension)
        var hash: UInt64 = 0
        for (index, value) in luminance.enumerated() where value > mean {
            hash |= (1 << UInt64(index))
        }
        return hash
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 相似图片分组（与完全重复使用不同定义：感知哈希近邻，且必须排除字节级完全相同的重复对——那是重复检测的职责）。
    public static func findSimilarImages(
        in files: [BigFile], hammingThreshold: Int = 8, progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [SimilarImageGroup] {
        let imageExtensions = Set(["png", "jpg", "jpeg", "heic", "tiff", "webp", "bmp"])
        let images = files.filter { imageExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
        var hashes: [(BigFile, UInt64)] = []
        for (index, file) in images.enumerated() {
            if let hash = averageHash(of: URL(fileURLWithPath: file.path)) {
                hashes.append((file, hash))
            }
            progress?(Double(index + 1) / Double(max(images.count, 1)))
        }

        // 完全重复（同哈希+同大小）不作为相似——由重复检测处理
        var used = Set<Int>()
        var groups: [SimilarImageGroup] = []
        for i in hashes.indices where !used.contains(i) {
            var similar: [(BigFile, Int)] = []
            for j in hashes.indices where j > i && !used.contains(j) {
                let distance = hammingDistance(hashes[i].1, hashes[j].1)
                if (1...hammingThreshold).contains(distance) {  // 距离 0 且同大小=完全重复，交由重复检测
                    similar.append((hashes[j].0, distance))
                    used.insert(j)
                }
            }
            if !similar.isEmpty {
                used.insert(i)
                groups.append(SimilarImageGroup(anchor: hashes[i].0, similar: similar))
            }
        }
        return groups.sorted { $0.similar.count > $1.similar.count }
    }
}
