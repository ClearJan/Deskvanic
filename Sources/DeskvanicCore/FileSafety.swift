import AppKit
import CryptoKit
import Foundation

/// 文件安全工具集：数据可靠性原则（第 9 节）的统一实现。
/// 所有"可能修改用户文件"的操作必须经由这些原语：临时产物 → 校验 → 原子提交；
/// 删除一律进废纸篓（可恢复）；写入前检查磁盘空间。
public enum FileSafety {

    // MARK: - 路径安全

    /// 判断 child 是否真的位于 parent 目录内（逐组件解析符号链接后比较规范路径）。
    /// 用于解压、导出等场景，防止路径穿越与符号链接逃逸。
    /// 注意：URL.resolvingSymlinksInPath 在末段不存在时不会解析中间链接，必须手动逐级解析。
    public static func isContained(_ child: URL, in parent: URL) -> Bool {
        let resolvedChild = fullyResolved(child)
        let resolvedParent = fullyResolved(parent)
        guard resolvedChild != resolvedParent else { return false }
        return resolvedChild.hasPrefix(resolvedParent + "/")
    }

    /// 逐组件解析路径中所有已存在的符号链接（含相对链接目标）。
    /// 注意结尾不得再做 standardizedFileURL——它会把 /private/var 折叠回 /var，
    /// 且对存在/不存在的末段行为不一致，导致误判。
    static func fullyResolved(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        let fm = FileManager.default
        var current = URL(fileURLWithPath: "/")
        for component in standardized.path.split(separator: "/") {
            current.appendPathComponent(String(component))
            if let target = try? fm.destinationOfSymbolicLink(atPath: current.path) {
                if target.hasPrefix("/") {
                    current = URL(fileURLWithPath: target)
                } else {
                    current = current.deletingLastPathComponent().appendingPathComponent(target)
                }
            }
        }
        return current.path
    }

    /// ZIP 条目名等不可信路径的净化：拒绝绝对路径、`..`、驱动器样式前缀。
    public static func validateRelativeEntry(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.hasPrefix("/") || name.hasPrefix("\\") { return false }
        if name.contains(":") && name.drop(while: { $0.isLetter }).first == ":" { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: true)
        for component in components {
            if component == ".." { return false }
        }
        return true
    }

    // MARK: - 命名与冲突

    /// 在目标目录内为首选名生成不冲突的文件名（"name 2.ext" 递增）。
    public static func uniqueDestination(in directory: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let base = directory.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: base.path) { return base }
        let stem = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    // MARK: - 磁盘与卷

    /// 指定路径所在卷的可用空间（字节）；失败返回 nil。
    public static func availableDiskSpace(at url: URL) -> Int64? {
        var stat = statvfs()
        guard statvfs(url.path, &stat) == 0 else { return nil }
        return Int64(stat.f_bavail) * Int64(stat.f_bsize)
    }

    /// 两个路径是否在同一卷（决定 rename 与 copy+delete 的选择），比较 st_dev。
    public static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        var stA = stat()
        var stB = stat()
        guard stat(a.path, &stA) == 0, stat(b.path, &stB) == 0 else { return false }
        return stA.st_dev == stB.st_dev
    }

    // MARK: - 删除（可恢复）

    /// 将文件移入废纸篓并返回废纸篓中的位置（用于撤销）。
    @MainActor
    @discardableResult
    public static func moveToTrash(_ url: URL) async throws -> URL {
        do {
            let results: [URL: URL] = try await NSWorkspace.shared.recycle([url])
            guard let moved = results.values.first else {
                throw DeskvanicError(.fileWriteFailed, "移入废纸篓未返回结果")
            }
            return moved
        } catch let error as DeskvanicError {
            throw error
        } catch {
            throw DeskvanicError(
                .fileWriteFailed, "无法将文件移入废纸篓",
                recovery: "请检查文件是否被其他应用占用。", underlying: String(describing: error))
        }
    }

    // MARK: - 校验

    /// SHA-256 文件哈希（用于重复检测与输出一致性校验）。
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1024 * 1024) } catch {
                throw DeskvanicError(.fileUnreadable, "读取文件失败", underlying: url.path)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 校验输出文件存在、大小 > 0 且（可选）与期望大小一致。处理任务提交结果前必须调用。
    public static func validateOutput(
        at url: URL,
        expectedMinBytes: Int64 = 1,
        expectedExactBytes: Int64? = nil
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw DeskvanicError(.outputValidationFailed, "输出文件不存在: \(url.lastPathComponent)")
        }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if size < expectedMinBytes {
            throw DeskvanicError(.outputValidationFailed, "输出文件为空或过小（\(size) 字节）")
        }
        if let expected = expectedExactBytes, size != expected {
            throw DeskvanicError(.outputValidationFailed, "输出大小不符（期望 \(expected)，实际 \(size)）")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw DeskvanicError(.outputValidationFailed, "输出文件不可读")
        }
    }
}

/// 原子写入器：写到同目录临时文件 → fsync → 原子 rename 替换目标。
public enum AtomicFileWriter {
    public static func write(data: Data, to destination: URL) throws {
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")

        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw DeskvanicError(.fileWriteFailed, "无法创建临时文件", underlying: destination.path)
        }
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw DeskvanicError(.fileWriteFailed, "写入失败: \(String(describing: error))")
        }
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } catch {
            // 目标不存在时 replaceItemAt 会失败，退回到 rename。
            do {
                try FileManager.default.moveItem(at: temp, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw DeskvanicError(.fileWriteFailed, "原子替换失败: \(String(describing: error))")
            }
        }
    }
}
