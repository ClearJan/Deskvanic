import Foundation
import Testing
@testable import DeskvanicCore

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test func exactMatchScoresHighest() {
        #expect(FuzzyMatcher.score(query: "截图", candidate: "截图") == 1)
        #expect(FuzzyMatcher.score(query: "capture", candidate: "Capture") == 1)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatcher.score(query: "", candidate: "anything") == 1)
    }

    @Test func prefixBeatsScattered() {
        let prefix = FuzzyMatcher.score(query: "cap", candidate: "Capture Studio")
        let scattered = FuzzyMatcher.score(query: "cap", candidate: "Clip Analysis Paster")
        #expect(prefix > scattered)
        #expect(prefix > 0)
    }

    @Test func missingCharactersNeverMatch() {
        #expect(FuzzyMatcher.score(query: "abcxyz", candidate: "ab") == 0)
        #expect(FuzzyMatcher.score(query: "zzz", candidate: "Capture") == 0)
    }

    @Test func diacriticAndCaseFolding() {
        #expect(FuzzyMatcher.score(query: "cafe", candidate: "Café") > 0)
        #expect(FuzzyMatcher.score(query: "CAFÉ", candidate: "cafe") > 0)
    }

    @Test func chineseSubsequence() {
        #expect(FuzzyMatcher.score(query: "截图", candidate: "Capture Studio 截图与识别") > 0)
        #expect(FuzzyMatcher.score(query: "图截", candidate: "截图") == 0)
    }

    @Test func rankingIsStableAndSorted() {
        let items = ["zip", "zoo", "zipper", "azure"]
        let ranked = FuzzyMatcher.rank(items, query: "z") { $0 }
        #expect(ranked.first?.item == "zip" || ranked.first?.item == "zoo")
        #expect(ranked.allSatisfy { $0.score > 0 })
        let scores = ranked.map(\.score)
        #expect(scores == scores.sorted(by: >) || scores == scores.sorted(by: >=))
        // azure 含 z（a-z-u-r-e），合法匹配；前缀命中应排在它之前
        let zipIndex = ranked.firstIndex { $0.item == "zip" }!
        let azureIndex = ranked.firstIndex { $0.item == "azure" }!
        #expect(zipIndex < azureIndex)
        // 完全不含查询字符的候选才被过滤
        let filtered = FuzzyMatcher.rank(["kilo", "moon"], query: "z") { $0 }
        #expect(filtered.isEmpty)
    }
}

@Suite("EventBus")
struct EventBusTests {
    @Test func publishSubscribeAndFilter() async {
        let bus = EventBus()
        let received = AtomicArray<EventBus.Event>()
        let stream = bus.events(matching: "topic.a")
        let task = Task {
            for await event in stream { received.append(event) }
        }
        // 等待订阅生效
        try? await Task.sleep(nanoseconds: 100_000_000)
        await bus.publish("topic.a", ["k": "v"])
        await bus.publish("topic.b", ["k": "other"])
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        #expect(received.values.count == 1)
        #expect(received.values.first?.data["k"] == "v")
    }
}

@Suite("UniversalModels")
struct UniversalModelsTests {
    @Test func portTypeCompatibility() {
        #expect(PortType.text.accepts(.text))
        #expect(!PortType.text.accepts(.file))
        #expect(PortType.file.accepts(.image))
        #expect(PortType.files.accepts(.file))
        #expect(PortType.any.accepts(.pdf))
        #expect(PortType.pdf.accepts(.any))
        #expect(!PortType.image.accepts(.pdf))
    }

    @Test func parameterValidation() {
        let range = ParameterDescriptor(
            key: "size", label: "尺寸", kind: .int, defaultValue: .int(1024),
            min: 16, max: 8192)
        #expect(ParameterValue.int(512).validate(against: range))
        #expect(!ParameterValue.int(4).validate(against: range))
        #expect(!ParameterValue.int(99999).validate(against: range))
        #expect(!ParameterValue.string("512").validate(against: range))

        let option = ParameterDescriptor(
            key: "format", label: "格式", kind: .option, defaultValue: .string("jpeg"),
            allowedOptions: ["jpeg", "png", "heic"])
        #expect(ParameterValue.string("png").validate(against: option))
        #expect(!ParameterValue.string("bmp").validate(against: option))
    }

    @Test func resourceRefCodableRoundtrip() throws {
        let ref = ResourceRef(kind: .image, filePayload: "/tmp/a.png", originModule: "capture")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(ResourceRef.self, from: data)
        #expect(decoded == ref)
    }
}

@Suite("FileSafety")
struct FileSafetyTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func pathContainment() throws {
        let root = try makeTempDir()
        #expect(FileSafety.isContained(root.appendingPathComponent("a/b.txt"), in: root))
        #expect(!FileSafety.isContained(root.deletingLastPathComponent(), in: root))
        // "../" 通过标准化后逃逸到父目录，必须被拒绝
        #expect(!FileSafety.isContained(root.appendingPathComponent("../escape.txt"), in: root))
    }

    @Test func pathContainmentSymlinkEscape() throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!FileSafety.isContained(link.appendingPathComponent("file"), in: root))
    }

    @Test func zipEntryValidation() {
        #expect(FileSafety.validateRelativeEntry("docs/a.txt"))
        #expect(!FileSafety.validateRelativeEntry("/etc/passwd"))
        #expect(!FileSafety.validateRelativeEntry("../up.txt"))
        #expect(!FileSafety.validateRelativeEntry("a/../../up.txt"))
        #expect(!FileSafety.validateRelativeEntry("C:\\win.txt"))
        #expect(!FileSafety.validateRelativeEntry(""))
    }

    @Test func uniqueDestinationAvoidsCollisions() throws {
        let dir = try makeTempDir()
        let first = dir.appendingPathComponent("photo.png")
        FileManager.default.createFile(atPath: first.path, contents: Data([1]))
        let second = FileSafety.uniqueDestination(in: dir, preferredName: "photo.png")
        #expect(second.lastPathComponent == "photo 2.png")
        FileManager.default.createFile(atPath: second.path, contents: Data([1]))
        let third = FileSafety.uniqueDestination(in: dir, preferredName: "photo.png")
        #expect(third.lastPathComponent == "photo 3.png")
    }

    @Test func sha256KnownVector() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("hello.txt")
        try "hello".data(using: .utf8)!.write(to: file)
        // SHA-256("hello")
        let digest = try FileSafety.sha256(of: file)
        #expect(digest == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func outputValidationRejectsBadOutputs() throws {
        let dir = try makeTempDir()
        let empty = dir.appendingPathComponent("empty.png")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(throws: DeskvanicError.self) { try FileSafety.validateOutput(at: empty) }
        #expect(throws: DeskvanicError.self) {
            try FileSafety.validateOutput(at: dir.appendingPathComponent("missing.png"))
        }
        let good = dir.appendingPathComponent("good.png")
        try Data(repeating: 7, count: 128).write(to: good)
        do {
            try FileSafety.validateOutput(at: good)
            #expect(true)
        } catch {
            Issue.record("有效输出不应校验失败: \(error)")
        }
    }

    @Test func atomicWriterRoundtripAndReplace() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("config.json")
        try AtomicFileWriter.write(data: Data("v1".utf8), to: target)
        try AtomicFileWriter.write(data: Data("v2".utf8), to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "v2")
        // 无残留临时文件
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func diskSpaceAndVolume() throws {
        let dir = try makeTempDir()
        #expect(FileSafety.availableDiskSpace(at: dir) ?? 0 > 1_000_000)
        #expect(FileSafety.isSameVolume(dir, FileManager.default.temporaryDirectory))
    }
}

@Suite("SettingsStore")
struct SettingsStoreTests {
    @Test func defaultsWhenMissingThenPersistAndUpdate() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.json")
        let store = SettingsStore(defaults: AppSettings(), url: url)
        #expect(store.snapshot.clipVault.maxItems == 500)

        store.update { $0.clipVault.maxItems = 300 }
        // 防抖写入
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // 新实例从磁盘恢复
        let reloaded = SettingsStore(defaults: AppSettings(), url: url)
        #expect(reloaded.snapshot.clipVault.maxItems == 300)
    }

    @Test func corruptFileFallsBackToDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("bad.json")
        try Data("not-json{{{".utf8).write(to: url)
        let store = SettingsStore(defaults: AppSettings(), url: url)
        #expect(store.snapshot.general.language == "system")
    }
}
