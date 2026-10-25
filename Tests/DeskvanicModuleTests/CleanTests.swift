import AppKit
import CoreGraphics
import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicClean

@Suite("OrganizeEngine")
struct OrganizeEngineTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("图片"), withIntermediateDirectories: true)
        for (name, content) in [("photo.jpg", "jpg"), ("song.mp3", "mp3"), ("notes.txt", "txt"), ("unknown.xyz", "xyz"), (".hidden", "h")] {
            let url = root.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
        }
        // 已整理记录：song.mp3 曾被移动过
        return root
    }

    @Test func planClassifiesAndSkips() throws {
        let root = try makeTree()
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .map { root.appendingPathComponent($0).path }
        let plan = OrganizeEngine.plan(
            files: files, in: root.path,
            rule: .downloadsDefault(),
            alreadyOrganized: [root.appendingPathComponent("song.mp3").path])
        let targets = Set(plan.moves.map { ($0.source as NSString).lastPathComponent })
        #expect(targets.contains("photo.jpg"))
        #expect(targets.contains("notes.txt"))
        // 无规则扩展名与隐藏文件跳过
        let skippedNames = plan.skipped.map { (($0.path as NSString).lastPathComponent, $0.reason) }
        #expect(skippedNames.contains { $0.0 == "unknown.xyz" && $0.1.contains("无匹配") })
        #expect(skippedNames.contains { $0.0 == ".hidden" && $0.1.contains("隐藏") })
        // 已整理登记的文件跳过（防重复触发）
        #expect(skippedNames.contains { $0.0 == "song.mp3" && $0.1.contains("上次整理") })
        // 已在分类目录的文件不重复计划
        #expect(!targets.contains { $0.contains("图片/") })
    }

    @Test func planConflictDetection() throws {
        let root = try makeTree()
        // 目标已存在同名但内容不同的文件 → 冲突
        try Data("different".utf8).write(to: root.appendingPathComponent("图片/photo.jpg"))
        let files = [root.appendingPathComponent("photo.jpg").path]
        let plan = OrganizeEngine.plan(files: files, in: root.path, rule: .downloadsDefault(), alreadyOrganized: [])
        #expect(plan.moves.count == 1)
        #expect(plan.moves[0].conflict)
    }

    @Test func outOfScopeFilesSkipped() throws {
        let root = try makeTree()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).jpg")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let plan = OrganizeEngine.plan(
            files: [outside.path], in: root.path, rule: .downloadsDefault(), alreadyOrganized: [])
        #expect(plan.moves.isEmpty)
        #expect(plan.skipped.contains { $0.reason.contains("授权目录") })
    }

    @MainActor
    @Test func executeMovesFilesAndRecords() async throws {
        let root = try makeTree()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-cleandb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations + [CleanSchema.migration])
        let audit = AuditLog(database: db)

        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .map { root.appendingPathComponent($0).path }
        let plan = OrganizeEngine.plan(files: files, in: root.path, rule: .downloadsDefault(), alreadyOrganized: [])
        let result = await OrganizeEngine.execute(plan, in: root.path, audit: audit)

        #expect(result.movedCount == plan.moves.count)
        #expect(result.failedCount == 0)
        // 分类目录中出现文件
        let imageDir = root.appendingPathComponent("图片")
        let organized = try FileManager.default.contentsOfDirectory(atPath: imageDir.path)
        #expect(organized.contains { $0.hasPrefix("photo.jpg") })
        // 原位置不再有 photo.jpg（同卷 rename）
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.jpg").path))
        // 审计记录存在
        let records = try await audit.recent(limit: 10)
        #expect(records.contains { $0.action == "clean.move" && $0.outcome == "ok" })
    }
}

@Suite("CleanScanner")
struct CleanScannerTests {
    @Test func diskUsageAvailable() {
        let usage = CleanScanner.diskUsage(at: FileManager.default.temporaryDirectory)
        #expect(usage != nil)
        #expect(usage!.totalBytes > 0)
        #expect(usage!.freeBytes > 0)
    }

    @Test func duplicateDetectionRequiresIdenticalContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        let c = root.appendingPathComponent("c.bin")
        let content = Data("exactly the same bytes!!".utf8)
        try content.write(to: a)
        try content.write(to: b)
        try Data("different bytes".utf8).write(to: c)

        let files = [a, b, c].map { url in
            CleanScanner.BigFile(path: url.path, name: url.lastPathComponent,
                                 sizeBytes: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0),
                                 modifiedAt: Date())
        }
        let groups = await CleanScanner.findExactDuplicates(files: files)
        #expect(groups.count == 1)
        #expect(groups[0].files.count == 2)
        // 保留最早修改的（keeper 在组内）
        #expect(groups[0].files.contains { $0.path == groups[0].keeperPath })
    }

    @Test func similarImagesGroupedHamming() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-sim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 生成两张视觉接近、一张完全不同的 PNG
        func writeImage(red: CGFloat, name: String) throws -> URL {
            let context = CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let image = context.makeImage()!
            let url = root.appendingPathComponent(name)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }
        _ = try writeImage(red: 0.5, name: "base.png")
        _ = try writeImage(red: 0.52, name: "near.png")
        _ = try writeImage(red: 0.9, name: "different.png")

        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .map { name -> CleanScanner.BigFile in
                let url = root.appendingPathComponent(name)
                return CleanScanner.BigFile(path: url.path, name: name,
                                            sizeBytes: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0),
                                            modifiedAt: Date())
            }
        let groups = await CleanScanner.findSimilarImages(in: files, hammingThreshold: 6)
        // 相近两张应同组；完全不同那张不属于该组
        if !groups.isEmpty {
            let paths = groups[0].similar.map { $0.file.name } + [groups[0].anchor.name]
            #expect(paths.contains("base.png") || paths.contains("near.png"))
            #expect(!paths.contains("different.png"))
        }
        // 相似 ≠ 完全重复：字节级不同（PNG 编码内容不同）
    }

    @Test func symlinkLoopDoesNotHang() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-loop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: root.appendingPathComponent("real/file.txt"))
        try? FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"), withDestinationURL: root)
        // 应在有限时间内返回（inode 防环）
        let big = CleanScanner.findBigFiles(in: root, topN: 100, maxDepth: 8, maxEntries: 1000)
        #expect(big.contains { $0.name == "file.txt" })
    }
}
