import AppKit
import EventKit
import Foundation
import DeskvanicCore
import DeskvanicUIShared
import SwiftUI

/// PaperTrail：生活文件管家（发票/合同/保修单）。
/// OCR 自动抽取的金额/日期一律进入"待确认"状态，人工核实后才视为有效记录。
public struct PaperRecord: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case invoice = "发票"
        case contract = "合同"
        case warranty = "保修单"
        case receipt = "购物凭证"
        case other = "其他"
    }

    public let id: String
    public var kind: Kind
    public var title: String
    /// OCR 预填、人工确认后的字段。
    public var merchant: String
    public var purchaseDate: Date?
    public var amountDecimal: Double?
    /// 人工确认标志：false = OCR 预填待核实。
    public var fieldsConfirmed: Bool
    public var dueDate: Date?          // 保修/合同到期
    public var reminderCreated: Bool
    public var tags: [String]
    public var filePath: String        // 原始文件（复制进库）
    public var ocrText: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, kind: Kind = .receipt, title: String,
                merchant: String = "", purchaseDate: Date? = nil, amountDecimal: Double? = nil,
                fieldsConfirmed: Bool = false, dueDate: Date? = nil, reminderCreated: Bool = false,
                tags: [String] = [], filePath: String, ocrText: String = "", createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.merchant = merchant
        self.purchaseDate = purchaseDate
        self.amountDecimal = amountDecimal
        self.fieldsConfirmed = fieldsConfirmed
        self.dueDate = dueDate
        self.reminderCreated = reminderCreated
        self.tags = tags
        self.filePath = filePath
        self.ocrText = ocrText
        self.createdAt = createdAt
    }
}

/// 字段抽取（纯函数，供人工确认——抽取结果只作为预填建议，不作为事实）。
public enum PaperFieldExtractor {

    public struct Extracted: Sendable, Equatable {
        public let amount: Double?
        public let date: Date?
        public let merchant: String?
    }

    /// 从 OCR 文本抽取候选字段。
    public static func extract(from ocrText: String, now: Date = Date()) -> Extracted {
        let text = ocrText.replacingOccurrences(of: "\n", with: " ")

        // 金额：¥ / ￥ / 元 / RMB / CNY + 数字（取最大合理值，跳过电话号码形态）
        var amount: Double?
        let amountPatterns = [
            "[¥￥]\\s*([0-9]{1,8}(?:,[0-9]{3})*(?:\\.[0-9]{1,2})?)",
            "(?:金额|合计|总计|total)[:：\\s]*([0-9]{1,8}(?:,[0-9]{3})*(?:\\.[0-9]{1,2})?)\\s*(?:元|圆|RMB|CNY)?",
            "([0-9]{1,8}(?:,[0-9]{3})*(?:\\.[0-9]{1,2})?)\\s*(?:元|圆|RMB|CNY)",
        ]
        var candidates: [Double] = []
        for pattern in amountPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let captureRange = Range(match.range(at: 1), in: text) {
                    let digits = text[captureRange].replacingOccurrences(of: ",", with: "")
                    if let value = Double(digits), value > 0, value < 10_000_000 {
                        candidates.append(value)
                    }
                }
            }
        }
        amount = candidates.max()

        // 日期：2024-01-31 / 2024/1/31 / 2024年1月31日 / Jan 31, 2024
        var date: Date?
        let datePatterns = [
            "(20[0-9]{2})[-/.年]\\s*([0-9]{1,2})[-/.月]\\s*([0-9]{1,2})",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for pattern in datePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range) {
                guard let yearR = Range(match.range(at: 1), in: text),
                      let monthR = Range(match.range(at: 2), in: text),
                      let dayR = Range(match.range(at: 3), in: text),
                      let year = Int(text[yearR]),
                      let month = Int(text[monthR]),
                      let day = Int(text[dayR]),
                      (1...12).contains(month), (1...31).contains(day) else { continue }
                var components = DateComponents()
                components.year = year
                components.month = month
                components.day = day
                date = Calendar(identifier: .gregorian).date(from: components)
                break
            }
        }

        // 商户：常见品牌词启发 + "有限公司/商店/店/超市" 结尾短语
        var merchant: String?
        for keyword in ["有限公司", "商店", "超市", "便利店", "餐厅", "酒店", "银行"] {
            if let range = text.range(of: keyword) {
                let start = text.index(range.upperBound, offsetBy: -min(14, text.distance(from: text.startIndex, to: range.upperBound)), limitedBy: text.startIndex) ?? text.startIndex
                let candidate = String(text[start..<range.upperBound])
                    .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                if candidate.count >= 4 {
                    merchant = candidate
                    break
                }
            }
        }
        return Extracted(amount: amount, date: date, merchant: merchant)
    }
}

/// PaperTrail 存储（数据库 v11）。
public actor PaperStore {
    private let db: Database

    public init(database: Database) {
        self.db = database
    }

    public func save(_ record: PaperRecord) async throws {
        let data = try JSONEncoder().encode(record)
        _ = try await db.runUpdate(
            "INSERT OR REPLACE INTO paper_records(id, kind, title, data, updated_at) VALUES(?,?,?,?,?)",
            [.text(record.id), .text(record.kind.rawValue), .text(record.title),
             .blob(data), .text(DateCodec.encode(Date()))])
        // 全文索引（OCR + 标题 + 商户 + 标签）
        let searchText = [record.title, record.merchant, record.ocrText, record.tags.joined(separator: " ")]
            .joined(separator: "\n")
        let index = SearchIndex(database: db)
        try await index.upsert(type: "paper", ref: record.id, text: searchText)
    }

    public func delete(id: String) async throws {
        _ = try await db.runUpdate("DELETE FROM paper_records WHERE id = ?", [.text(id)])
        try await SearchIndex(database: db).remove(type: "paper", ref: id)
    }

    public func all() async throws -> [PaperRecord] {
        let rows = try await db.run("SELECT data FROM paper_records ORDER BY updated_at DESC")
        return rows.compactMap { row in
            guard let data = row["data"]?.blobValue else { return nil }
            return try? JSONDecoder().decode(PaperRecord.self, from: data)
        }
    }

    public func upcoming(dueWithinDays: Int = 30) async throws -> [PaperRecord] {
        let all = try await all()
        let deadline = Date().addingTimeInterval(Double(dueWithinDays) * 86_400)
        return all
            .filter { record in
                guard let due = record.dueDate else { return false }
                return due < deadline && !record.reminderCreated
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }
}

/// PaperTrail 数据库迁移（版本 11）。
public enum PaperSchema {
    public static let migration = DBMigration(version: 11, name: "paper-trail", statements: [
        """
        CREATE TABLE paper_records(
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            data BLOB NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_paper_kind ON paper_records(kind)",
    ])
}

/// PaperTrail 主界面。
public struct PaperTrailView: View {
    @State private var records: [PaperRecord] = []
    @State private var upcoming: [PaperRecord] = []
    @State private var statusMessage: String?
    @State private var searchQuery = ""
    @State private var kindFilter: PaperRecord.Kind?
    @State private var editingRecord: PaperRecord?

    public init() {}

    public var body: some View {
        ToolContainer("生活文件管家", subtitle: "PaperTrail · OCR 预填 → 人工核实 → 到期提醒") {
            VStack(alignment: .leading, spacing: 14) {
                toolbar
                if !upcoming.isEmpty {
                    upcomingBanner
                }
                recordList
                if let message = statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await reload() }
        .sheet(item: $editingRecord) { record in
            RecordEditor(record: record) { updated in
                var final = updated
                final.fieldsConfirmed = true  // 编辑保存即视为人工确认
                try? await PaperServices.store.save(final)
                editingRecord = nil
                await reload()
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索标题、商户、OCR 全文", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await reload() } }
                .onChange(of: searchQuery) { _, _ in Task { await reload() } }
            Picker("类型", selection: Binding(
                get: { kindFilter },
                set: { kindFilter = $0; Task { await reload() } })) {
                Text("全部").tag(PaperRecord.Kind?.none)
                ForEach(PaperRecord.Kind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(PaperRecord.Kind?.some(kind))
                }
            }
            .frame(width: 110)
            Button("导入凭证…") { importFile() }
        }
    }

    private var upcomingBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("即将到期（30 天内）", systemImage: "bell.badge").font(.headline)
            ForEach(upcoming) { record in
                HStack {
                    Text(record.title).font(.callout)
                    Spacer()
                    if let due = record.dueDate {
                        Text("到期：\(due.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("创建提醒") { Task { await createReminder(record) } }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var recordList: some View {
        GroupBox("记录（\(records.count)）") {
            VStack(alignment: .leading, spacing: 8) {
                if records.isEmpty {
                    Text("暂无记录。导入发票/合同/保修单图片或 PDF，OCR 自动预填字段后人工核实。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(records) { record in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.plaintext")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(record.title).lineLimit(1)
                                if !record.fieldsConfirmed {
                                    Label("待核实", systemImage: "checkmark.seal")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            HStack(spacing: 8) {
                                Text(record.kind.rawValue)
                                if let amount = record.amountDecimal {
                                    Text(String(format: "¥%.2f", amount))
                                }
                                if let date = record.purchaseDate {
                                    Text(date.formatted(date: .numeric, time: .omitted))
                                }
                                ForEach(record.tags, id: \.self) { tag in
                                    Text("#\(tag)").foregroundStyle(.teal)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑核实") { editingRecord = record }
                            .buttonStyle(.link).font(.caption)
                        Button("删除", role: .destructive) {
                            Task {
                                try? await PaperServices.store.delete(id: record.id)
                                await reload()
                            }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                    .padding(6)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 动作

    private func reload() async {
        records = (try? await PaperServices.store.all())?.filter { record in
            (kindFilter == nil || record.kind == kindFilter)
        } ?? []
        upcoming = (try? await PaperServices.store.upcoming()) ?? []
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.message = "选择凭证图片或 PDF（复制进库，原文件不动）"
        panel.begin { response in
            guard response == .OK else { return }
            Task { await importFiles(panel.urls) }
        }
    }

    private func importFiles(_ urls: [URL]) async {
        var imported = 0
        for url in urls {
            do {
                // 复制进库
                let itemDir = AppEnvironment.transfersDirectory.appendingPathComponent("PaperTrail", isDirectory: true)
                try? FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
                let dest = FileSafety.uniqueDestination(in: itemDir, preferredName: url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
                try FileSafety.validateOutput(at: dest)

                // OCR 预填（图片直接识别；PDF 取第一页渲染后识别）
                var ocrText = ""
                var image: CGImage?
                if dest.pathExtension.lowercased() == "pdf" {
                    if let doc = PDFKitDocument(url: dest), let page = doc.page(at: 0) {
                        image = page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox)
                            .cgImage(forProposedRect: nil, context: nil, hints: nil)
                    }
                } else if let nsImage = NSImage(contentsOf: dest) {
                    image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
                if let image {
                    ocrText = (try? await OCREngine.recognizeText(in: image))?.fullText ?? ""
                }

                let extracted = PaperFieldExtractor.extract(from: ocrText)
                let record = PaperRecord(
                    kind: .receipt,
                    title: url.deletingPathExtension().lastPathComponent,
                    merchant: extracted.merchant ?? "",
                    purchaseDate: extracted.date,
                    amountDecimal: extracted.amount,
                    fieldsConfirmed: false,
                    tags: ["待核实"],
                    filePath: dest.path,
                    ocrText: ocrText)
                try await PaperServices.store.save(record)
                imported += 1
                statusMessage = "已导入 \(imported) 个（OCR 预填完成，请逐条核实）"
            } catch {
                statusMessage = "导入失败：\(String(describing: error))"
            }
        }
        await reload()
    }

    private func createReminder(_ record: PaperRecord) async {
        guard let due = record.dueDate else { return }
        let granted = await Permissions.request(.notifications) == .granted
        if !granted {
            statusMessage = "通知权限被拒绝；可在系统设置开启后重试（数据已保留到期列表）"
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "到期提醒：\(record.title)"
        content.body = "该记录将于 \(due.formatted(date: .long, time: .omitted)) 到期"
        content.sound = .default
        let fireDate = Calendar.current.date(byAdding: .day, value: -3, to: due) ?? due
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: "paper-\(record.id)", content: content, trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
            var updated = record
            updated.reminderCreated = true
            try? await PaperServices.store.save(updated)
            statusMessage = "已创建到期前 3 天的系统提醒"
            await reload()
        } catch {
            statusMessage = "提醒创建失败：\(String(describing: error))"
        }
    }
}

import PDFKit
import UserNotifications

/// 记录编辑器（人工核实入口）。
struct RecordEditor: View {
    @State var record: PaperRecord
    let onSave: (PaperRecord) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("核实记录（保存即确认）").font(.headline)
            HStack {
                Picker("类型", selection: $record.kind) {
                    ForEach(PaperRecord.Kind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                TextField("标题", text: $record.title)
                    .textFieldStyle(.roundedBorder)
            }
            TextField("商户", text: $record.merchant)
                .textFieldStyle(.roundedBorder)
            HStack {
                DatePicker("购买日期", selection: Binding(
                    get: { record.purchaseDate ?? Date() },
                    set: { record.purchaseDate = $0 }), displayedComponents: .date)
                DatePicker("到期日", selection: Binding(
                    get: { record.dueDate ?? Date().addingTimeInterval(365 * 86_400) },
                    set: { record.dueDate = $0 }), displayedComponents: .date)
            }
            TextField("金额（元）", text: Binding(
                get: { record.amountDecimal.map { String(format: "%.2f", $0) } ?? "" },
                set: { record.amountDecimal = Double($0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            TextField("标签（逗号分隔）", text: Binding(
                get: { record.tags.joined(separator: ",") },
                set: { record.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                .textFieldStyle(.roundedBorder)
            if !record.ocrText.isEmpty {
                DisclosureGroup("OCR 原文（预填来源）") {
                    ScrollView {
                        Text(record.ocrText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("确认并保存") {
                    Task {
                        await onSave(record)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// PaperTrail 服务装配点。
@MainActor
public enum PaperServices {
    public static var store = PaperStore(database: Database(url: AppEnvironment.databaseURL))

    public static func inject(store newStore: PaperStore) {
        store = newStore
    }
}

import PDFKit

/// PDFKit 文档便捷构造（避免与 SwiftUI PDFKit 命名冲突）。
struct PDFKitDocument {
    let document: PDFKit.PDFDocument
    init?(url: URL) {
        guard let document = PDFKit.PDFDocument(url: url) else { return nil }
        self.document = document
    }
    func page(at index: Int) -> PDFKit.PDFPage? {
        document.page(at: index)
    }
}
