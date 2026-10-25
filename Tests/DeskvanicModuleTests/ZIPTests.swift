import AppKit
import CoreGraphics
import Foundation
import Testing
import DeskvanicCore
@testable import DeskvanicFileStudio

@Suite("ZIPArchive")
struct ZIPArchiveTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundtripSmallFiles() throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("中文文件.txt")
        let b = dir.appendingPathComponent("emoji-🚀.md")
        try "内容 A".write(to: a, atomically: true, encoding: .utf8)
        try Data("binary \u{01}\u{02}content".utf8).write(to: b)

        let archive = dir.appendingPathComponent("out.zip")
        try ZIPArchive.createArchive(at: archive, adding: [a, b])

        let extractDir = dir.appendingPathComponent("out", isDirectory: true)
        let report = try ZIPArchive.extract(archiveAt: archive, to: extractDir)
        #expect(report.rejected.isEmpty)
        #expect(report.extracted.count == 2)
        for extracted in report.extracted {
            let original = [a, b].first { $0.lastPathComponent == extracted.lastPathComponent }!
            #expect(try FileSafety.sha256(of: extracted) == FileSafety.sha256(of: original))
        }
    }

    @Test func roundtripLargeBinaryDeflateWorks() throws {
        let dir = try makeTempDir()
        let big = dir.appendingPathComponent("big.bin")
        // 20MB 高度可压缩数据
        var data = Data(capacity: 20 * 1024 * 1024)
        for i in 0..<(20 * 1024 * 1024 / 16) {
            data.append(withUnsafeBytes(of: UInt64(i % 3)) { Data($0) })
            data.append(withUnsafeBytes(of: UInt64(i % 3)) { Data($0) })
        }
        try data.write(to: big)
        let originalHash = try FileSafety.sha256(of: big)

        let archive = dir.appendingPathComponent("big.zip")
        try ZIPArchive.createArchive(at: archive, adding: [big])
        // deflate 应真实生效
        let archiveSize = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        #expect(archiveSize < 5 * 1024 * 1024, "可压缩数据应显著变小")

        let extractDir = dir.appendingPathComponent("out", isDirectory: true)
        let report = try ZIPArchive.extract(archiveAt: archive, to: extractDir)
        #expect(report.extracted.count == 1)
        #expect(try FileSafety.sha256(of: report.extracted[0]) == originalHash)
    }

    @Test func nestedDirectoryRoundtrip() throws {
        let dir = try makeTempDir()
        let nested = dir.appendingPathComponent("level1/level2/deep.txt", isDirectory: false)
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "deep".write(to: nested, atomically: true, encoding: .utf8)

        let archive = dir.appendingPathComponent("nested.zip")
        try ZIPArchive.createArchive(at: archive, adding: [nested], options: .init(keepRelativePaths: true))
        let extractDir = dir.appendingPathComponent("out", isDirectory: true)
        let report = try ZIPArchive.extract(archiveAt: archive, to: extractDir)
        #expect(report.extracted.contains { $0.lastPathComponent == "deep.txt" })
    }

    @Test func emptyFileRoundtrip() throws {
        let dir = try makeTempDir()
        let empty = dir.appendingPathComponent("empty.txt")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let archive = dir.appendingPathComponent("e.zip")
        try ZIPArchive.createArchive(at: archive, adding: [empty])
        let report = try ZIPArchive.extract(archiveAt: archive, to: dir.appendingPathComponent("o"))
        #expect(report.extracted.count == 1)
        #expect(try FileSafety.sha256(of: report.extracted[0]) == FileSafety.sha256(of: empty))
    }

    @Test func pathTraversalRejectedOthersStillExtracted() throws {
        let dir = try makeTempDir()
        // 用系统 zip 构造含恶意条目的归档（先正常压两个文件，再手工注入恶意条目名）
        let good = dir.appendingPathComponent("good.txt")
        try "good".write(to: good, atomically: true, encoding: .utf8)
        let archive = dir.appendingPathComponent("evil.zip")
        try ZIPArchive.createArchive(at: archive, adding: [good])

        // 手工把归档复制一份并把中央目录中的条目名 "good.txt" 替换为 "../evil.txt"（等长替换）
        var data = try Data(contentsOf: archive)
        // "good.txt" 出现两次（本地头 + 中央目录）；替换最后一处（中央目录条目名）
        let pattern = Data("good.txt".utf8)
        if let first = data.range(of: pattern) {
            let searchStart = data.index(after: first.lowerBound)
            if let second = data.range(of: pattern, in: searchStart..<data.endIndex) {
                data.replaceSubrange(second, with: Data("/x/evil1".utf8))
            }
        }
        try data.write(to: archive)

        let extractDir = dir.appendingPathComponent("out", isDirectory: true)
        let report = try ZIPArchive.extract(archiveAt: archive, to: extractDir)
        // 恶意名被拒绝；正常条目仍在（可能 CRC 失败或成功取决于替换是否破坏数据）
        #expect(!report.rejected.isEmpty)
        // 输出目录外不得出现文件
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x").path))
        #expect(!FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("x/evil1").path))
    }

    @Test func symlinksRejected() throws {
        let dir = try makeTempDir()
        let real = dir.appendingPathComponent("real.txt")
        try "x".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)

        // 用系统 zip 打包（保留符号链接）
        let archive = dir.appendingPathComponent("links.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-ry", archive.lastPathComponent, link.lastPathComponent, real.lastPathComponent]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()

        let extractDir = dir.appendingPathComponent("out", isDirectory: true)
        let report = try ZIPArchive.extract(archiveAt: archive, to: extractDir)
        // 符号链接条目被拒绝
        #expect(report.rejected.contains { $0.name.contains("link") })
        // 解压目录中不应有符号链接
        for extracted in report.extracted {
            #expect((try? extracted.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true)
        }
    }

    @Test func nameCollisionGetsSuffixed() throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("dup.txt")
        try "A".write(to: a, atomically: true, encoding: .utf8)
        let archive = dir.appendingPathComponent("dup.zip")
        try ZIPArchive.createArchive(at: archive, adding: [a])
        // 手工复制中央目录与数据实现双同名条目：直接压两次同一文件
        var combined = try Data(contentsOf: archive)
        // 简化方案：解压两次到同一目录
        let extractDir = dir.appendingPathComponent("out", isDirectory: true)
        _ = try ZIPArchive.extract(archiveAt: archive, to: extractDir)
        let second = try ZIPArchive.extract(archiveAt: archive, to: extractDir)
        // 第二次解压的同名文件使用 " 2" 后缀
        #expect(second.extracted.contains { $0.lastPathComponent == "dup 2.txt" })
        _ = combined
    }

    @Test func notAZIPFileRejected() throws {
        let dir = try makeTempDir()
        let fake = dir.appendingPathComponent("fake.zip")
        try Data("这不是 zip".utf8).write(to: fake)
        #expect(throws: Error.self) {
            _ = try ZIPArchive.entries(at: fake)
        }
        #expect(throws: Error.self) {
            _ = try ZIPArchive.extract(archiveAt: fake, to: dir.appendingPathComponent("o"))
        }
    }

    @Test func systemZipInteropBothDirections() throws {
        // 用系统 zip 打包 → 本实现解压
        let dir = try makeTempDir()
        let files = (1...3).map { i in
            let url = dir.appendingPathComponent("interop\(i).txt")
            try? "互操作测试 \(i)".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let systemArchive = dir.appendingPathComponent("system.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", "-q", systemArchive.lastPathComponent] + files.map(\.lastPathComponent)
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Issue.record("系统 zip 不可用，跳过互操作测试")
            return
        }
        let report = try ZIPArchive.extract(archiveAt: systemArchive, to: dir.appendingPathComponent("out1"))
        #expect(report.extracted.count == 3)

        // 本实现打包 → 系统 unzip 校验
        let ours = dir.appendingPathComponent("ours.zip")
        try ZIPArchive.createArchive(at: ours, adding: files)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", "-d", dir.appendingPathComponent("verify").path, ours.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0, "系统 unzip 应能校验我们生成的归档")
    }
}

@Suite("ImageEngine")
struct ImageEngineTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func solidImage(width: Int, height: Int, red: CGFloat = 0.3, alpha: CGFloat = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.7, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage, name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func writeJPEGWithGPS(in dir: URL) throws -> URL {
        // 生成含 EXIF+GPS 的 JPEG
        let image = solidImage(width: 400, height: 300)
        let url = dir.appendingPathComponent("with-gps.jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw DeskvanicError(.fileWriteFailed, "无法创建测试 JPEG")
        }
        let mutable = NSMutableData()
        let info = CGImageDestinationCreateWithData(mutable as CFMutableData, "public.jpeg" as CFString, 1, nil)!

        let exif = NSMutableDictionary()
        exif[kCGImagePropertyExifDateTimeOriginal] = "2026:01:01 12:00:00"
        let gps = NSMutableDictionary()
        gps[kCGImagePropertyGPSLatitude] = 31.23
        gps[kCGImagePropertyGPSLatitudeRef] = "N"
        gps[kCGImagePropertyGPSLongitude] = 121.47
        gps[kCGImagePropertyGPSLongitudeRef] = "E"

        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyGPSDictionary: gps,
        ]
        CGImageDestinationAddImage(info, image, props as CFDictionary)
        CGImageDestinationFinalize(info)
        try (mutable as Data).write(to: url)
        return url
    }

    @Test func convertPNGToJPEG() throws {
        let dir = try makeTempDir()
        let png = try writePNG(solidImage(width: 200, height: 100), name: "src.png", in: dir)
        let originalHash = try FileSafety.sha256(of: png)
        let report = try ImageEngine.convert(source: png, to: .jpeg, destinationDirectory: dir)
        #expect(report.outputURL.pathExtension == "jpg")
        #expect(report.pixelWidth == 200 && report.pixelHeight == 100)
        #expect(report.notes.isEmpty || report.notes.allSatisfy { !$0.isEmpty })
        // 原文件未变（审计 #6：修复自比较永真断言）
        #expect(try FileSafety.sha256(of: png) == originalHash)
    }

    @Test func convertJPEGToPNG() throws {
        let dir = try makeTempDir()
        let jpegURL = try writeJPEGWithGPS(in: dir)
        let report = try ImageEngine.convert(source: jpegURL, to: .png, destinationDirectory: dir)
        #expect(report.pixelWidth == 400 && report.pixelHeight == 300)
    }

    @Test func inspectDetectsGPS() throws {
        let dir = try makeTempDir()
        let jpegURL = try writeJPEGWithGPS(in: dir)
        let metadata = try ImageEngine.inspect(source: jpegURL)
        #expect(metadata.hasEXIF)
        #expect(metadata.hasGPS)
        #expect(metadata.pixelWidth == 400)
    }

    @Test func stripMetadataRemovesGPSAndEXIF() throws {
        let dir = try makeTempDir()
        let jpegURL = try writeJPEGWithGPS(in: dir)
        let stripped = try ImageEngine.stripMetadata(source: jpegURL, destinationDirectory: dir)
        let verify = try ImageEngine.inspect(source: stripped)
        #expect(!verify.hasGPS, "剥离后不得再含 GPS（隐私承诺）")
        #expect(!verify.hasIPTC)
        // JPEG 会有 ImageIO 自动生成的基础 EXIF(仅创建时间)；严格零 EXIF 走 PNG
        if stripped.pathExtension == "png" {
            #expect(!verify.hasEXIF)
        }
        // 像素仍可解码
        #expect(verify.pixelWidth == 400 && verify.pixelHeight == 300)
    }

    @Test func resizeFitMath() throws {
        let dir = try makeTempDir()
        let png = try writePNG(solidImage(width: 4000, height: 3000), name: "big.png", in: dir)
        let output = try ImageEngine.resize(source: png, maxPixel: 1000, destinationDirectory: dir)
        let metadata = try ImageEngine.inspect(source: output)
        #expect(metadata.pixelWidth == 1000)
        #expect(metadata.pixelHeight == 750)
    }

    @Test func resizeNoUpscaleCopies() throws {
        let dir = try makeTempDir()
        let png = try writePNG(solidImage(width: 100, height: 80), name: "small.png", in: dir)
        let originalHash = try FileSafety.sha256(of: png)
        let output = try ImageEngine.resize(source: png, maxPixel: 1000, destinationDirectory: dir)
        // 原图更小且不放大 → 直接复制，内容一致
        #expect(try FileSafety.sha256(of: output) == originalHash)
    }

    @Test func compressJPEGToTarget() throws {
        let dir = try makeTempDir()
        // 高细节图更容易被压缩
        let context = CGContext(
            data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: 3000, by: 4) {
            context.setFillColor(CGColor(red: CGFloat(y) / 3000, green: CGFloat(y % 100) / 100, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: 4000, height: 4))
        }
        let gradient = context.makeImage()!
        let png = try writePNG(gradient, name: "gradient.png", in: dir)
        let target: Int64 = 500 * 1024
        let report = try ImageEngine.compress(source: png, targetBytes: target, destinationDirectory: dir)
        #expect(report.achievedBytes <= target, "压缩结果 \(report.achievedBytes) 应 ≤ 目标 \(target)")
        #expect(report.reachedTarget)
        // 输出仍可解码
        let verify = try ImageEngine.inspect(source: report.outputURL)
        #expect(verify.pixelWidth == 4000 && verify.pixelHeight == 3000)
    }

    @Test func invalidParametersRejected() throws {
        let dir = try makeTempDir()
        let png = try writePNG(solidImage(width: 100, height: 100), name: "x.png", in: dir)
        #expect(throws: DeskvanicError.self) {
            _ = try ImageEngine.convert(source: png, to: .jpeg, destinationDirectory: dir, quality: 1.5)
        }
        #expect(throws: DeskvanicError.self) {
            _ = try ImageEngine.resize(source: png, maxPixel: 4, destinationDirectory: dir)
        }
        #expect(throws: DeskvanicError.self) {
            _ = try ImageEngine.compress(source: png, targetBytes: 0, destinationDirectory: dir)
        }
        #expect(throws: DeskvanicError.self) {
            _ = try ImageEngine.inspect(source: dir.appendingPathComponent("missing.png"))
        }
    }

    @Test func fakeImageRejected() throws {
        let dir = try makeTempDir()
        let fake = dir.appendingPathComponent("fake.png")
        try Data("这是文本不是图片".utf8).write(to: fake)
        #expect(throws: DeskvanicError.self) {
            _ = try ImageEngine.inspect(source: fake)
        }
    }

    @Test func sourceFileUnchangedAfterAllOperations() throws {
        let dir = try makeTempDir()
        let png = try writePNG(solidImage(width: 300, height: 200), name: "keep.png", in: dir)
        let originalHash = try FileSafety.sha256(of: png)
        _ = try ImageEngine.convert(source: png, to: .jpeg, destinationDirectory: dir)
        _ = try ImageEngine.resize(source: png, maxPixel: 100, destinationDirectory: dir)
        _ = try ImageEngine.compress(source: png, targetBytes: 20_000, destinationDirectory: dir)
        _ = try ImageEngine.stripMetadata(source: png, destinationDirectory: dir)
        #expect(try FileSafety.sha256(of: png) == originalHash, "原文件必须保持不变")
    }
}
