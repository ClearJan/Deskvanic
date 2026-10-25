import Foundation
import Testing
@testable import DeskvanicCore

@Suite("Database")
struct DatabaseTests {
    private func makeDB() async throws -> (Database, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.sqlite")
        let db = Database(url: url)
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations)
        return (db, dir)
    }

    @Test func migrateAppliesOnceAndIsIdempotent() async throws {
        let (db, _) = try await makeDB()
        let versions = try await db.currentVersions()
        #expect(versions == Set([1, 2]))
        // 重复执行不报错、不重复
        try await db.migrate(DeskvanicSchema.migrations)
        let again = try await db.currentVersions()
        #expect(again == Set([1, 2]))
    }

    @Test func kvRoundtrip() async throws {
        let (db, _) = try await makeDB()
        _ = try await db.runUpdate("INSERT INTO kv_store(key, value) VALUES(?, ?)", [.text("a"), .text("1")])
        let rows = try await db.run("SELECT value FROM kv_store WHERE key = ?", [.text("a")])
        #expect(rows.first?["value"]?.stringValue == "1")
        let changed = try await db.runUpdate("UPDATE kv_store SET value = ? WHERE key = ?", [.text("2"), .text("a")])
        #expect(changed == 1)
        let updated = try await db.run("SELECT value FROM kv_store WHERE key = ?", [.text("a")])
        #expect(updated.first?["value"]?.stringValue == "2")
    }

    @Test func failedMigrationRollsBack() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()

        let good = DBMigration(version: 1, name: "good", statements: [
            "CREATE TABLE t1(id INTEGER PRIMARY KEY)",
        ])
        let bad = DBMigration(version: 2, name: "bad", statements: [
            "CREATE TABLE t2(id INTEGER PRIMARY KEY)",
            "THIS IS NOT VALID SQL",
        ])
        try await db.migrate([good])
        await #expect(throws: Database.DBError.self) {
            try await db.migrate([bad])
        }
        // v2 未登记为已应用；t2 在事务回滚后不存在
        let versions = try await db.currentVersions()
        #expect(versions == Set([1]))
        let tables = try await db.run("SELECT name FROM sqlite_master WHERE type='table' AND name='t2'")
        #expect(tables.isEmpty)
    }

    @Test func backupAndIntegrity() async throws {
        let (db, dir) = try await makeDB()
        _ = try await db.runUpdate("INSERT INTO kv_store(key, value) VALUES('k', 'v')")
        let backupURL = dir.appendingPathComponent("backup.sqlite")
        try await db.backup(to: backupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        let restored = Database(url: backupURL)
        try await restored.open()
        try await restored.migrate(DeskvanicSchema.migrations)
        let rows = try await restored.run("SELECT value FROM kv_store WHERE key='k'")
        #expect(rows.first?["value"]?.stringValue == "v")
        let integrity = try await restored.integrityCheck()
        #expect(integrity)
    }

    @Test func blobAndNullParameters() async throws {
        let (db, _) = try await makeDB()
        _ = try await db.runUpdate(
            "INSERT INTO audit_log(actor, action, subject, outcome, detail) VALUES(?,?,?,?,?)",
            [.text("tester"), .text("unit.test"), .null, .text("ok"), .blob(Data([9, 9, 9]))])
        let rows = try await db.run("SELECT subject, detail FROM audit_log WHERE actor = ?", [.text("tester")])
        #expect(rows.first?["subject"] == .null)
        #expect(rows.first?["detail"]?.blobValue == Data([9, 9, 9]))
    }
}

@Suite("SearchIndex")
struct SearchIndexTests {
    private func makeIndex() async throws -> SearchIndex {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskvanic-fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = Database(url: dir.appendingPathComponent("t.sqlite"))
        try await db.open()
        try await db.migrate(DeskvanicSchema.migrations)
        return SearchIndex(database: db)
    }

    @Test func upsertSearchRemove() async throws {
        let index = try await makeIndex()
        try await index.upsert(type: "clip", ref: "1", text: "Deskvanic 剪贴板历史记录 alpha")
        try await index.upsert(type: "vault", ref: "2", text: "项目周报 记录 beta")
        var results = try await index.search("记录")
        #expect(results.count == 2)
        results = try await index.search("剪贴板")
        #expect(results.count == 1 && results[0].ref == "1")
        results = try await index.search("不存在的词")
        #expect(results.isEmpty)
        try await index.remove(type: "clip", ref: "1")
        let count = try await index.count()
        #expect(count == 1)
    }

    @Test func upsertDoesNotDuplicate() async throws {
        let index = try await makeIndex()
        try await index.upsert(type: "clip", ref: "x", text: "hello world")
        try await index.upsert(type: "clip", ref: "x", text: "hello world updated")
        let count = try await index.count()
        #expect(count == 1)
        let results = try await index.search("updated")
        #expect(results.count == 1)
        #expect(results[0].text.contains("updated"))
    }

    @Test func queryInjectionIsNeutralized() async throws {
        let index = try await makeIndex()
        try await index.upsert(type: "clip", ref: "1", text: "normal content")
        // 引号与 FTS 运算符被当作普通文本，不会语法报错也不会误删
        let results = try await index.search("\"DROP TABLE\" OR NOT *")
        #expect(results.isEmpty)
    }
}
