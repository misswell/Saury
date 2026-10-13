import Foundation

/// 交换格式（CSV / JSON）的解析层（任务书 §3.2）。
///
/// 这一层只回答「文件里写了什么、这么写行不行」，不判断该不该导 ——
/// 那是 `ImportConflictResolver` 的事。分开的理由是预览界面要同时说清三件事：
/// 文件本身的问题、和本机比对的问题、用户自己勾选的问题；
/// 揉在一个函数里迟早互相顶掉。
enum ImportParser {
    enum Failure: LocalizedError, Equatable {
        case emptyFile
        case undecodableText
        case notCSVOrJSON
        case fullBackupFile

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "这个文件是空的"
            case .undecodableText:
                return "这份文本的编码读不出来（认 UTF-8、带 BOM 的 UTF-16、Windows-1252、Latin-1）。GBK / Big5 等旧中文编码请先用表格软件另存为「CSV UTF-8」再导"
            case .notCSVOrJSON: return "这个文件既不是能读的 CSV，也不是 JSON"
            case .fullBackupFile: return "这是完整备份包（.saurybackup），请用设置里的「从备份恢复」打开，那里能带图标和设置一起恢复"
            }
        }
    }

    enum Format: String {
        case csv = "CSV"
        case legacyJSON = "旧版 JSON"
        case objectJSON = "JSON 列表"
    }

    /// 可编辑、可参与比对的业务字段。预览里的字段级纠错按这几个键走。
    enum Field: String, CaseIterable, Hashable {
        case name = "名称"
        case amount = "金额"
        case currency = "币种"
        case cycle = "周期"
        case startDate = "起始日期"
        case category = "分类"

        /// 编辑面板上的顺序：先认错的名字和金额，再排后面的可选项。
        static let editorOrder: [Field] = [.name, .amount, .currency, .cycle, .startDate, .category]
    }

    /// 一行订阅的解析结果。`issues` 是会挡住导入的问题，`advisories` 只是提醒。
    ///
    /// 文件原文（`base` + `raw`）和校验结果（`draft` / `issues`）分开存：
    /// 预览里改一个字段只要重跑一遍校验，不用回到文件重新解析，
    /// 也不会把「文件里本来写了什么」改掉 —— 纠错界面两个都得显示。
    struct Row: Identifiable, Equatable {
        let id: UUID
        /// 文件里带的稳定编号；没有就是 nil，写入时才现发一个。
        var stableID: UUID?
        var sourceLabel: String
        /// 文件给出的完整快照。六个可编辑字段以 `raw` 为准，其余（图标、分摊、提醒…）原样保留。
        var base: SubscriptionDraft
        /// 文件里各列的原文。
        var raw: [Field: String]
        var createdAt: Date?
        var events: [SubscriptionEventDraft]
        /// 写库用的那一份：`base` 按 `raw` 覆盖并校验后的结果。
        var draft: SubscriptionDraft
        var issues: [String]
        var advisories: [String]
        /// 这一行里读不出来的那几个字段。`issues` 是给人读的句子，判据不能靠句子里的词，
        /// 所以单独记一份：界面用它决定哪里宁可空着，也不印一个没 parse 出来的默认数。
        var failedFields: Set<Field> = []

        init(id: UUID = UUID(),
             sourceLabel: String,
             base: SubscriptionDraft? = nil,
             raw: [Field: String] = [:],
             stableID: UUID? = nil,
             createdAt: Date? = nil,
             events: [SubscriptionEventDraft] = [],
             presentExtras: Set<ExtraColumn> = [],
             carriesWholeRecord: Bool = false,
             categories: [SubscriptionCategory] = DefaultCategories.items,
             defaultCurrency: String = "CNY") {
            self.id = id
            self.sourceLabel = sourceLabel
            self.stableID = stableID
            var start = base ?? SubscriptionDraft(id: id)
            // 写库用的编号跟界面用的行号对齐：有稳定编号就用编号，
            // 没有就用这一行的 id，免得预览点和落库对不上是同一条。
            start.id = stableID ?? id
            self.base = start
            self.raw = raw
            self.createdAt = createdAt
            self.events = events
            self.presentExtras = presentExtras
            self.carriesWholeRecord = carriesWholeRecord
            self.draft = self.base
            self.issues = []
            self.advisories = []
            reparse(categories: categories, defaultCurrency: defaultCurrency)
        }

        /// 文件里实际给了哪几列。更新本机那一条时只用这几列覆盖，其余保留本机原值。
        var presentFields: Set<Field> { Set(raw.keys) }
        /// 附加列（套餐 / 备注 / 支付方式 / 状态）里文件真正给了值的那些。
        var presentExtras: Set<ExtraColumn>
        /// 旧版 JSON 导出是这条订阅的完整快照：更新它时整份覆盖才是本来的意思。
        var carriesWholeRecord: Bool
        var isBlocked: Bool { issues.isEmpty == false }
        /// 界面上叫得出口的名字：问题清单要指得到具体那一行。
        var displayName: String {
            let text = base.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? draft.name.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }

        mutating func reparse(categories: [SubscriptionCategory], defaultCurrency: String) {
            var made = base
            if let stableID { made.id = stableID }
            var problems: [String] = []
            var tips: [String] = []
            var failed: Set<Field> = []

            let currency = raw[.currency]
            // 币种列没写就按本机默认币种；写了但不认识就挡住这一行，不替用户猜一个。
            var effectiveCurrency = defaultCurrency
            if made.currencyCode.isEmpty { made.currencyCode = defaultCurrency }
            if let text = currency {
                let code = String(text.filter { $0.isASCII && $0.isLetter }.uppercased())
                if code.count == 3, CurrencyCatalog.entry(for: code) != nil {
                    effectiveCurrency = code
                } else {
                    problems.append("币种「\(text)」不是 App 认识的货币代码，选一个再导")
                    failed.insert(.currency)
                }
            }

            if let text = raw[.name] {
                made.name = text
            } else if made.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("没有名字：得先有个能认出来的名字才能导进来")
                failed.insert(.name)
            }

            if let text = raw[.amount] {
                let before = problems.count
                made.priceMinorUnits = amount(from: text, currencyCode: effectiveCurrency,
                                              problems: &problems, tips: &tips)
                if problems.count > before { failed.insert(.amount) }
            } else if made.priceMinorUnits < 0 {
                problems.append("金额是负数（\(made.priceMinorUnits) 分），得改成实际数字")
                failed.insert(.amount)
            }

            if let text = raw[.cycle] {
                if let parsed = cycle(from: text) {
                    made.cycle = parsed.cycle
                    made.customMonths = parsed.customMonths ?? made.customMonths
                    if parsed.cycle == .oneTime { tips.append("一次性支出没有下一次扣费，不进月均") }
                } else {
                    problems.append("周期「\(text)」认不出来，选一个周期")
                    failed.insert(.cycle)
                }
            }

            if let text = raw[.startDate] {
                if let date = date(from: text) { made.startDate = date }
                else {
                    problems.append("日期「\(text)」读不出来，格式改成 2026-03-07 这样再导")
                    failed.insert(.startDate)
                }
            }

            if let text = raw[.category] {
                let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = categories.first(where: { $0.id == key || $0.name == key }) {
                    made.category = match.id
                } else {
                    made.category = DefaultCategories.fallback.id
                    tips.append("分类「\(text)」在本机的分类表里没有，先记到「\(DefaultCategories.fallback.name)」")
                }
            } else if made.category.isEmpty == false,
                      categories.first(where: { $0.id == made.category }) == nil {
                tips.append("分类「\(made.category)」不在本机分类表里，导入后按「\(DefaultCategories.fallback.name)」显示")
            }

            made.currencyCode = effectiveCurrency
            made.priceMinorUnits = max(made.priceMinorUnits, 0)
            draft = made
            issues = problems
            advisories = tips
            failedFields = failed
        }
    }

    /// 一份文件解析完的全部结果。
    struct Table: Identifiable {
        /// 每次解析生成一个，只用来让 SwiftUI 认得出「这是新的一份文件」，不参与数据比较。
        /// 行内纠错不会换掉它：`editing` 复制自身，行 id 和这个 id 都保持稳定。
        let id = UUID()
        var fileName: String
        var format: Format
        var encodingName: String
        var delimiter: String
        var rows: [Row]
        /// 整份文件级的说明：忽略的列、按默认值补的东西、没跟上的历史记录。
        var notes: [String]
        /// 文件里识别出来的表头，预览页要照着它排版，不能自己另起一套。
        var headers: [String]
        /// 校验用的本机快照：分类表改了，编辑后的行要按新的认。
        var categories: [SubscriptionCategory]
        var defaultCurrency: String
        /// 文件里带历史记录、但认不出属于哪条订阅的那些（按订阅名记）。
        /// 单独存一份而不是只写在 `notes` 里：导入结果要把「历史少了」这条报给外面。
        var unmatchedEventOwners: [String] = []

        var eventLossSummary: String? {
            guard unmatchedEventOwners.isEmpty == false else { return nil }
            let head = Array(Set(unmatchedEventOwners)).prefix(3).joined(separator: "、")
            return "\(unmatchedEventOwners.count) 条历史记录找不到属于哪条订阅（\(head)），没导"
        }

        /// 预览里改某个字段：只重算这一行，文件原文留在 `base` / `raw` 里。
        func editing(rowID: UUID, field: Field, to text: String?) -> Table {
            var updated = self
            guard let index = updated.rows.firstIndex(where: { $0.id == rowID }) else { return updated }
            var row = updated.rows[index]
            if let text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                row.raw[field] = text
            } else {
                row.raw[field] = nil
            }
            row.reparse(categories: categories, defaultCurrency: defaultCurrency)
            updated.rows[index] = row
            return updated
        }
    }

    // MARK: - 入口

    /// `categories` / `defaultCurrency` 来自本机设置：解析要按用户自己的分类表和默认币种来认，
    /// 而不是硬编码一套「中文表头 + CNY」。
    static func parse(data: Data,
                      fileName: String,
                      categories: [SubscriptionCategory],
                      defaultCurrency: String) throws -> Table {
        guard data.isEmpty == false else { throw Failure.emptyFile }
        if data.starts(with: BackupContainer.magic) { throw Failure.fullBackupFile }

        // JSON 的判定只看第一个有效字符：BOM 和缩进都不该把它挡在外面。
        let head = firstMeaningfulByte(of: data)
        if head == UInt8(ascii: "{") || head == UInt8(ascii: "[") {
            return try parseJSON(data: data,
                                 fileName: fileName,
                                 categories: categories,
                                 defaultCurrency: defaultCurrency)
        }
        let (text, encodingName) = try decodeText(data)
        return try parseCSV(text: text,
                            fileName: fileName,
                            encodingName: encodingName,
                            categories: categories,
                            defaultCurrency: defaultCurrency)
    }

    /// 跳过 BOM 和前导空白后的第一个字节。
    private static func firstMeaningfulByte(of data: Data) -> UInt8? {
        var index = data.startIndex
        let skipped: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF, 0xFF, 0xFE, 0x00]
        while index < data.endIndex, skipped.contains(data[index]) { index = data.index(after: index) }
        return index < data.endIndex ? data[index] : nil
    }

    // MARK: - CSV

    /// BOM、常见编码都在这一层处理干净：界面不该再去猜编码。
    ///
    /// 只用「有证据」的读法：BOM 说了算，没 BOM 就只承认 UTF-8 和单字节西欧编码，
    /// 而且单字节那份还要过内容检查。GBK / Big5 这类旧中文编码 Foundation 读不了，
    /// 但它们在 Latin-1 下能「成功」读出一堆乱码 —— 那种成功比失败更糟，
    /// 所以宁可停下来说清楚，也不把「ÀÖ」当订阅名导进库。
    static func decodeText(_ data: Data) throws -> (text: String, encodingName: String) {
        guard data.isEmpty == false else { throw Failure.emptyFile }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = decoded(Data(data.dropFirst(3)), as: .utf8) {
            return (text, "UTF-8（带 BOM）")
        }
        // UTF-16 只认带 BOM 的：Excel「Unicode 文本」就是这么写的。
        // 没 BOM 时不猜 —— 任意字节都能被 UTF-16 拼成「看着像文字」的乱码。
        if data.starts(with: [0xFF, 0xFE]), let text = decoded(Data(data.dropFirst(2)), as: .utf16LittleEndian) {
            return (text, "UTF-16 LE")
        }
        if data.starts(with: [0xFE, 0xFF]), let text = decoded(Data(data.dropFirst(2)), as: .utf16BigEndian) {
            return (text, "UTF-16 BE")
        }
        if let text = decoded(data, as: .utf8) { return (text, "UTF-8") }
        for (name, encoding) in [("Windows-1252", String.Encoding.windowsCP1252),
                                 ("Latin-1", String.Encoding.isoLatin1)] {
            if let text = decoded(data, as: encoding), looksLikeMisreadCJK(text) == false {
                return (text, name)
            }
        }
        throw Failure.undecodableText
    }

    private static func decoded(_ data: Data, as encoding: String.Encoding) -> String? {
        String(data: data, encoding: encoding)
    }

    /// 单字节读法的内容检查：GBK / GB2312 一个汉字是两个高位字节，Big5 是「高位 + 低位」两字节，
    /// 所以乱码里必有连续的 U+00A0–U+00FF；真正的西欧文本（Café、Zürich、€）这些字母都是零散夹在 ASCII 里的。
    private static func looksLikeMisreadCJK(_ text: String) -> Bool {
        var run = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x80...0x9F: return true                 // Latin-1 里的控制字符：正常文本不会有
            case 0xA0...0xFF: run += 1                    // Latin-1 补充区，连着两个就说明是双字节中文
            default: run = 0
            }
            if run >= 2 { return true }
        }
        return false
    }

    /// 一条 CSV 记录：引号内允许逗号、换行、`""` 转义（RFC 4180）。
    /// 用 `split(separator:)` 是造不出这些的，所以这里自己走一遍字符状态机。
    static func csvRecords(from text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var quoted = false
        var index = text.startIndex
        let newlines: Set<Character> = ["\n", "\r", "\u{2028}", "\u{2029}"]

        func endField() {
            record.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            // 整行空白（含只有一个空字段的尾行）不进表：那是文件里的空行，不是一条订阅。
            if record.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }) { records.append(record) }
            record = []
        }

        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {   // "" 表示一个字面引号
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    quoted = false
                } else {
                    field.append(character)          // 引号内的换行就是内容，不当行尾
                }
                index = text.index(after: index)
                continue
            }
            switch character {
            case "\"" where field.trimmingCharacters(in: .whitespaces).isEmpty:
                quoted = true
            case delimiter:
                endField()
            case let c where newlines.contains(c):
                // CRLF 当一个换行用掉
                let next = text.index(after: index)
                if c == "\r", next < text.endIndex, text[next] == "\n" { index = next }
                endRecord()
            default:
                field.append(character)
            }
            index = text.index(after: index)
        }
        if quoted { endRecord() } else if field.isEmpty == false || record.isEmpty == false { endRecord() }
        return records
    }

    /// 分隔符探测：表头行里没有逗号时，才承认制表符或分号。
    static func detectedDelimiter(in text: String) -> Character {
        let firstLine = String(text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first ?? "")
        if firstLine.contains(",") { return "," }
        if firstLine.contains("\t") { return "\t" }
        if firstLine.contains(";") { return ";" }
        return ","
    }

    private static func parseCSV(text: String,
                                 fileName: String,
                                 encodingName: String,
                                 categories: [SubscriptionCategory],
                                 defaultCurrency: String) throws -> Table {
        let delimiter = detectedDelimiter(in: text)
        let records = csvRecords(from: text, delimiter: delimiter)
        guard records.isEmpty == false else { throw Failure.emptyFile }

        var notes: [String] = []
        if delimiter != "," { notes.append("这份文件用的是「\(delimiterName(delimiter))」分隔，已按它切开") }
        if encodingName != "UTF-8" { notes.append("文本编码按 \(encodingName) 读的，如果中文有乱码请改用 UTF-8 再导") }

        let headerCells = records[0]
        // 第一行是不是表头：认得出别名才算，否则那本来就是一条数据。
        let mapped = mapHeader(headerCells)
        let hasHeader = mapped.fields.contains(where: { $0 != nil })
        let columns: [Field?]
        let idColumn: Int?
        let extraColumns: [(Int, ExtraColumn)]
        let dataRecords: [[String]]
        if hasHeader {
            columns = mapped.fields
            idColumn = mapped.idColumn
            extraColumns = mapped.extras
            dataRecords = Array(records.dropFirst())
            let ignored = zip(headerCells, columns).compactMap { name, field in
                (field == nil
                    && name.trimmingCharacters(in: .whitespaces).isEmpty == false
                    && identifierKeys.contains(normalizeHeader(name)) == false
                    && extraColumn(name) == nil) ? name : nil
            }
            if ignored.isEmpty == false { notes.append("这几列对不上已知字段，整列忽略：\(ignored.joined(separator: "、"))") }
            let carried = extraColumns.map { "「\(headerCells[$0.0])」→\($0.1.title)" }
            if carried.isEmpty == false {
                notes.append("这几列会原样带进订阅，但预览里不能改：\(carried.joined(separator: "、"))")
            }
        } else {
            // 没表头就按老格式的固定顺序：名称,金额,币种,周期。
            // 只有一列的文本更可能是一段说明而不是一张订阅表 —— 与其导进一条 0 元的
            // 「hello world」，不如直接说这不是表格（任务书 §12.1 的「损坏文件」）。
            guard records[0].count >= 2 else { throw Failure.notCSVOrJSON }
            columns = positionalColumns(records[0].count)
            idColumn = nil
            extraColumns = []
            dataRecords = records
            notes.append("第一行没认出表头，按「名称,金额,币种,周期」的顺序读")
        }
        if columns.contains(where: { $0 == .amount }) == false {
            notes.append("这份文件没有金额列，导进来的订阅都会记成 0 元 —— 想按实际价格就补一列再导")
        }
        if columns.contains(where: { $0 == .startDate }) == false {
            notes.append("这份文件没有起始日期，订阅按导入当天开始算扣费")
        }

        var rows: [Row] = []
        for (offset, record) in dataRecords.enumerated() {
            var base = SubscriptionDraft()
            var raw: [Field: String] = [:]
            for (index, field) in columns.enumerated() {
                guard let field, index < record.count else { continue }
                let value = record[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty == false { raw[field] = value }
            }

            var stableID: UUID?
            var unreadableIdentifier: String?
            if let idColumn, idColumn < record.count {
                let value = record[idColumn].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty == false {
                    if let uuid = UUID(uuidString: value) {
                        stableID = uuid
                        base.id = uuid
                    } else {
                        unreadableIdentifier = value
                    }
                }
            }
            let presentExtras = applyExtras(extraColumns, record: record, to: &base)

            var row = Row(sourceLabel: "第 \(offset + 1 + (hasHeader ? 1 : 0)) 行",
                          base: base,
                          raw: raw,
                          stableID: stableID,
                          presentExtras: presentExtras,
                          categories: categories,
                          defaultCurrency: defaultCurrency)
            // 编号列写了东西但不是 UUID：这一行照样能导，但不能冒充别人的稳定编号。
            if let unreadableIdentifier {
                row.advisories.append("编号「\(unreadableIdentifier)」不是 UUID，这条按新增处理")
            }
            rows.append(row)
        }
        guard rows.isEmpty == false else { throw Failure.emptyFile }
        return Table(fileName: fileName,
                     format: .csv,
                     encodingName: encodingName,
                     delimiter: delimiterName(delimiter),
                     rows: rows,
                     notes: notes,
                     headers: headerCells,
                     categories: categories,
                     defaultCurrency: defaultCurrency)
    }

    private static func delimiterName(_ delimiter: Character) -> String {
        switch delimiter {
        case "\t": return "制表符"
        case ";": return "分号"
        default: return String(delimiter)
        }
    }

    private static func positionalColumns(_ count: Int) -> [Field?] {
        let defaults: [Field?] = [.name, .amount, .currency, .cycle, .startDate, .category]
        return (0..<count).map { defaults.indices.contains($0) ? defaults[$0] : nil }
    }

    /// 表头别名表。中英都收，因为「从别的账本搬过来」的文件两种都有。
    private static let aliases: [Field: [String]] = [
        .name: ["名称", "订阅名称", "订阅", "项目", "服务", "name", "subscription", "service", "title", "app"],
        .amount: ["金额", "价格", "费用", "花费", "amount", "price", "cost", "fee"],
        .currency: ["币种", "货币", "currency", "ccy"],
        .cycle: ["周期", "计费周期", "扣费周期", "频率", "cycle", "period", "frequency", "interval", "billing"],
        .startDate: ["起始日期", "开始日期", "生效日期", "首次扣费", "下次扣费", "到期日期",
                     "date", "start", "start date", "next billing date", "renewal date", "due date"],
        .category: ["分类", "类别", "分组", "category", "group", "tag"],
    ]

    /// 精确别名认不出时的关键字。每个字段只认自己那几个词，
    /// 「备注」「支付方式」这类列不在这里抢，走 `ExtraColumn`。
    private static let keywords: [Field: [String]] = [
        .name: ["名称", "订阅", "项目", "服务", "name", "title", "service"],
        .amount: ["金额", "价格", "费用", "amount", "price", "cost", "fee"],
        .currency: ["币种", "货币", "currency", "ccy"],
        .cycle: ["周期", "频率", "cycle", "period", "frequency", "interval", "billing"],
        .startDate: ["日期", "起始", "开始", "生效", "扣费", "到期", "date", "start", "renewal", "next"],
        .category: ["分类", "类别", "分组", "category", "group", "tag"],
    ]

    /// 会带进订阅、但不在预览里编辑的列。
    enum ExtraColumn: String, CaseIterable {
        case plan = "套餐"
        case notes = "备注"
        case paymentMethod = "支付方式"
        case state = "状态"

        var title: String {
            switch self {
            case .plan: return "套餐"
            case .notes: return "备注"
            case .paymentMethod: return "支付方式"
            case .state: return "状态"
            }
        }

        var keys: [String] {
            switch self {
            case .plan: return ["套餐", "方案", "plan", "tier", "package"]
            case .notes: return ["备注", "说明", "note", "notes", "comment", "description"]
            case .paymentMethod: return ["支付方式", "付款方式", "payment method", "payment", "method"]
            case .state: return ["状态", "续费状态", "status", "state"]
            }
        }
    }

    private static func extraColumn(_ cell: String) -> ExtraColumn? {
        let key = normalizeHeader(cell)
        guard key.isEmpty == false else { return nil }
        return ExtraColumn.allCases.first { column in columnMatches(column: column, key: key) }
    }

    private struct HeaderMapping {
        var fields: [Field?]
        var extras: [(Int, ExtraColumn)]
        var idColumn: Int?
    }

    /// 认领顺序：编号列 → 精确业务字段 → 精确附加列 → 关键字。
    /// 一个字段只认领一列，免得「开始日期」「结束日期」两列抢同一个 `startDate`
    /// 把后面的列全吃掉；认领错了比认不出来更难被发现。
    private static func mapHeader(_ cells: [String]) -> HeaderMapping {
        var used = Set<Field>()
        var usedExtra = Set<ExtraColumn>()
        var fields: [Field?] = []
        var extras: [(Int, ExtraColumn)] = []
        var idColumn: Int?

        for (index, cell) in cells.enumerated() {
            let key = normalizeHeader(cell)
            guard key.isEmpty == false else {
                fields.append(nil)
                continue
            }
            if idColumn == nil, identifierKeys.contains(key) {
                idColumn = index
                fields.append(nil)
                continue
            }
            if let field = fieldForExact(key), used.contains(field) == false {
                used.insert(field)
                fields.append(field)
                continue
            }
            if let column = ExtraColumn.allCases.first(where: { candidate in
                usedExtra.contains(candidate) == false && columnMatches(column: candidate, key: key)
            }) {
                usedExtra.insert(column)
                extras.append((index, column))
                fields.append(nil)
                continue
            }
            if let field = fieldByKeyword(key), used.contains(field) == false {
                used.insert(field)
                fields.append(field)
                continue
            }
            fields.append(nil)
        }
        return HeaderMapping(fields: fields, extras: extras, idColumn: idColumn)
    }

    private static let identifierKeys: Set<String> = ["id", "uuid", "编号", "稳定编号", "identifier", "订阅编号"]

    private static func columnMatches(column: ExtraColumn, key: String) -> Bool {
        if column.keys.contains(key) { return true }
        // 中文列名可以包含关键字（「支付方式」「备注说明」）；
        // ASCII 只做整词比对，否则「width」会被「id」这类短键抢走。
        return column.keys.contains { alias in
            alias.count >= 2 && alias.contains(where: { !$0.isASCII }) && key.contains(alias)
        }
    }

    private static func fieldForExact(_ key: String) -> Field? {
        aliases.first { pair in pair.value.contains(where: { $0.lowercased() == key }) }?.key
    }

    private static func fieldByKeyword(_ key: String) -> Field? {
        // 按固定顺序问：名称优先于其他，避免「订阅名称」被别的列抢走。
        for field in Field.editorOrder {
            if fieldForExact(key) == field { return field }
            if keywords[field]?.contains(where: { key.contains($0.lowercased()) }) == true { return field }
        }
        return nil
    }

    /// 表头里常混着全角、括号说明（「金额（元）」），归一化后才好比对。
    static func normalizeHeader(_ cell: String) -> String {
        var text = cell.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                locale: Locale(identifier: "en_US_POSIX"))
        for pair in [("（", "）"), ("(", ")"), ("［", "］"), ("[", "]")] {
            while let open = text.range(of: pair.0),
                  let close = text.range(of: pair.1, range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        return text
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// 套餐、备注、支付方式、状态：文件里带着就照搬，不带就留订阅的默认值。
    /// 返回「文件真给了值的那些列」，更新本机那一条时只覆盖这几列。
    private static func applyExtras(_ extraColumns: [(Int, ExtraColumn)],
                                    record: [String],
                                    to draft: inout SubscriptionDraft) -> Set<ExtraColumn> {
        var applied: Set<ExtraColumn> = []
        for (index, column) in extraColumns where index < record.count {
            let text = record[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { continue }
            applied.insert(column)
            switch column {
            case .plan: draft.plan = text
            case .notes: draft.notes = text
            case .paymentMethod: draft.paymentMethod = text
            case .state: draft.state = state(from: text) ?? .autoRenew
            }
        }
        return applied
    }

    static func state(from text: String) -> SubscriptionState? {
        let key = normalizeHeader(text)
        switch key {
        case "自动续费", "auto", "autorenew", "active", "正常": return .autoRenew
        case "手动续费", "manual", "手动": return .manualRenew
        case "已停用", "停用", "inactive", "canceled", "cancelled", "paused": return .inactive
        default: return SubscriptionState(rawValue: key)
        }
    }

    // MARK: - 字段文本

    /// 金额：小数点写法不跟着手机设置走，先按 `.` 试，不行再按 `,` 试。
    private static func amount(from text: String,
                               currencyCode: String,
                               problems: inout [String],
                               tips: inout [String]) -> Int {
        switch MoneyParsing.parse(text, currencyCode: currencyCode, separators: .english) {
        case .success(let money):
            return money.minorUnits
        case .failure(let englishFailure):
            switch MoneyParsing.parse(text, currencyCode: currencyCode, separators: .continental) {
            case .success(let money):
                tips.append("金额「\(text)」是按欧洲写法（逗号当小数点）读成 \(money.amountText) 的")
                return money.minorUnits
            case .failure(let continentalFailure):
                problems.append("金额「\(text)」读不出来：\(preferredAmountFailure(englishFailure, continentalFailure).message)")
                return 0
            }
        }
    }

    /// 「1200.5 日元」的真原因是这个币种没有小数位，不是「只能填数字」：
    /// 两次尝试里挑离用户能改的东西更近的那条原因。
    private static func preferredAmountFailure(_ english: MoneyParsing.Failure,
                                              _ continental: MoneyParsing.Failure) -> MoneyParsing.Failure {
        if case .tooManyFractionDigits = english { return english }
        if case .tooManyFractionDigits = continental { return continental }
        return english
    }

    /// 周期文本：中文标题、rawValue、常见英文和「每 3 个月」这类数量写法都收。
    static func cycle(from text: String) -> (cycle: BillingCycle, customMonths: Int?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let cycle = BillingCycle(rawValue: trimmed.lowercased()) { return (cycle, nil) }
        for cycle in BillingCycle.allCases where cycle.title == trimmed { return (cycle, nil) }
        let compact = trimmed.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        if let cycle = BillingCycle(rawValue: compact) { return (cycle, nil) }
        // 「3 个月 / every 3 months / 每 3 月」：模型里的自定义周期只有月这一个单位。
        if let months = countBefore(compact, units: ["个月", "months", "month", "mo", "月"]) {
            switch months {
            case 1: return (.monthly, nil)
            case 3: return (.quarterly, nil)
            case 6: return (.semiannual, nil)
            case 12: return (.yearly, nil)
            default: return (.custom, max(months, 1))
            }
        }
        if let days = countBefore(compact, units: ["days", "day", "天"]) {
            return days == 7 ? (.weekly, nil) : (.custom, max(1, Int(round(Double(days) / 30.44))))
        }
        if let weeks = countBefore(compact, units: ["weeks", "week", "星期", "周"]) {
            return weeks == 1 ? (.weekly, nil) : (.custom, max(1, Int(round(Double(weeks) / 4.35))))
        }
        let wordAliases: [(String, BillingCycle)] = [
            ("weekly", .weekly), ("week", .weekly), ("每周", .weekly), ("周付", .weekly),
            ("monthly", .monthly), ("month", .monthly), ("每月", .monthly), ("月付", .monthly), ("包月", .monthly),
            ("quarterly", .quarterly), ("quarter", .quarterly), ("每季度", .quarterly), ("每季", .quarterly),
            ("季付", .quarterly), ("包季", .quarterly),
            ("semiannual", .semiannual), ("semiyear", .semiannual), ("halfyear", .semiannual),
            ("每半年", .semiannual), ("半年", .semiannual),
            ("yearly", .yearly), ("annual", .yearly), ("peryear", .yearly), ("year", .yearly),
            ("每年", .yearly), ("年付", .yearly), ("包年", .yearly), ("一年", .yearly),
            ("onetime", .oneTime), ("once", .oneTime), ("一次性", .oneTime), ("单次", .oneTime), ("买断", .oneTime),
        ]
        for (token, cycle) in wordAliases where compact == token || compact.hasPrefix(token) {
            return (cycle, nil)
        }
        return nil
    }

    private static func countBefore(_ text: String, units: [String]) -> Int? {
        for unit in units {
            guard let range = text.range(of: unit), range.lowerBound != text.startIndex else { continue }
            let digits = String(text[..<range.lowerBound]).filter { $0.isASCII && $0.isNumber }
            if let value = Int(digits), value > 0 { return value }
        }
        return nil
    }

    /// 文件里的日期写法：ISO8601、`2026-03-07`、`2026/3/7`、`2026年3月7日`、10/13 位时间戳。
    static func date(from text: String) -> Date? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return nil }
        if key.count == 10 || key.count == 13, key.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let seconds = Double(key) ?? 0
            return Date(timeIntervalSince1970: key.count == 13 ? seconds / 1000 : seconds)
        }
        // 只有带时间段的写法才交给 ISO8601：`2026-03-07` 是「哪一天」，
        // 按 UTC 零点读会让东八区的订阅整整错开一天。
        if key.contains("T"), let date = iso8601(key) { return date }
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.calendar = BillingMath.calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: key) { return date }
        }
        return dayMonthYear(key)
    }

    private static func iso8601(_ text: String) -> Date? {
        let withTime = ISO8601DateFormatter()
        if let date = withTime.date(from: text) { return date }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: text)
    }

    private static let dateFormats: [String] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        "yyyy/M/d HH:mm", "yyyy/M/d", "yyyy.M.d", "yyyyMMdd",
        "yyyy年M月d日 HH:mm", "yyyy年M月d日",
        "d MMM yyyy", "MMM d, yyyy",
    ]

    /// `7/3/2026` 这种两头都 ≤12 的写法本身有歧义：文件是 US 还是 CN 导的猜不出来。
    /// 这里只按「有一个超过 12 就能定序」的规则解，剩下的一律不猜、当读不出来报给用户。
    private static func dayMonthYear(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." }).map { Int($0) }
        guard parts.count == 3, let first = parts[0], let second = parts[1], let year = parts[2], year > 1000 else { return nil }
        let day: Int, month: Int
        if first > 12, second <= 12 { (day, month) = (first, second) }
        else if second > 12, first <= 12 { (day, month) = (second, first) }
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return BillingMath.calendar.date(from: components)
    }

    // MARK: - JSON

    private static func parseJSON(data: Data,
                                  fileName: String,
                                  categories: [SubscriptionCategory],
                                  defaultCurrency: String) throws -> Table {
        if let payload = try? JSONDecoder.backup.decode(SubscriptionImportExport.ExportPayload.self, from: data) {
            return try legacyTable(payload: payload,
                                   fileName: fileName,
                                   categories: categories,
                                   defaultCurrency: defaultCurrency)
        }
        // 外部 JSON 十有八九是「一个对象数组」，键名跟着各家 App 走，这里按别名尽量搬。
        if let objects = looseJSONObjects(data) {
            return try objectTable(objects: objects,
                                   fileName: fileName,
                                   categories: categories,
                                   defaultCurrency: defaultCurrency)
        }
        throw Failure.notCSVOrJSON
    }

    /// 旧版导出格式：字段名是 App 自己定的，直接映射进统一模型。
    private static func legacyTable(payload: SubscriptionImportExport.ExportPayload,
                                    fileName: String,
                                    categories: [SubscriptionCategory],
                                    defaultCurrency: String) throws -> Table {
        guard payload.subscriptions.isEmpty == false else { throw Failure.emptyFile }
        var rows: [Row] = []
        for (index, item) in payload.subscriptions.enumerated() {
            var draft = SubscriptionDraft(id: item.id ?? UUID())
            draft.name = item.name
            draft.plan = item.plan
            draft.iconSymbolName = item.iconSymbolName
            draft.iconImageFile = item.iconImageFile
            draft.iconColorHex = item.iconColorHex
            draft.colorSpec = CardColorSpec(hexes: item.colorHexes)
            draft.priceMinorUnits = item.priceMinorUnits
            draft.currencyCode = item.currencyCode
            draft.cycle = BillingCycle(rawValue: item.cycle) ?? .monthly
            draft.customMonths = max(item.customMonths, 1)
            draft.category = item.category
            draft.state = SubscriptionState(rawValue: item.state) ?? .autoRenew
            draft.startDate = item.startDate
            draft.endDate = item.endDate
            draft.remindersEnabled = item.resolvedRemindersEnabled
            draft.reminderDays = item.reminderDays
            draft.shareEnabled = item.shareEnabled
            draft.shareHeadcount = max(item.shareHeadcount, 1)
            draft.shareMode = ShareMode(rawValue: item.shareMode) ?? .even
            draft.shareMyMinorUnits = item.shareMyMinorUnits
            draft.paymentMethod = item.paymentMethod
            draft.notes = item.notes

            // 原文照抄文件里的数（含负数）：校验要能看见「-45」这种东西，
            // 不能先把负号抹掉再假装没问题。
            let money = Money(minorUnits: item.priceMinorUnits, currencyCode: item.currencyCode)
            let row = Row(sourceLabel: "JSON 第 \(index + 1) 条",
                          base: draft,
                          raw: [.name: item.name,
                                .amount: money.amountText,
                                .currency: item.currencyCode,
                                .cycle: item.cycle,
                                .startDate: QJFormat.longDate(item.startDate),
                                .category: item.category],
                          stableID: item.id,
                          createdAt: item.createdAt,
                          carriesWholeRecord: true,
                          categories: categories,
                          defaultCurrency: defaultCurrency)
            rows.append(row)
        }

        var notes: [String] = []
        var unmatchedNames: [String] = []
        // 归属先认编号，认不到才退回名字；两边都对不上的如实记下来，不硬塞给某条订阅。
        let idsInFile = Set(rows.map(\.draft.id))
        let firstByName = Dictionary(rows.map { ($0.draft.name, $0.draft.id) }) { first, _ in first }
        var eventsByOwner: [UUID: [SubscriptionEventDraft]] = [:]
        for event in payload.events {
            let owner = event.subscriptionID.flatMap { idsInFile.contains($0) ? $0 : nil }
                ?? firstByName[event.subscriptionName]
            guard let owner else {
                unmatchedNames.append(event.subscriptionName)
                continue
            }
            eventsByOwner[owner, default: []].append(SubscriptionEventDraft(
                id: event.id ?? UUID(),
                subscriptionID: owner,
                type: SubscriptionEventType(rawValue: event.type) ?? .note,
                amountMinorUnits: max(event.amountMinorUnits, 0),
                currencyCode: event.currencyCode,
                note: event.note,
                happenedAt: event.happenedAt))
        }
        // 事件挂回行上要走 `Row` 的存储，不重新解析 —— 否则用户的编辑会被冲掉。
        for index in rows.indices {
            rows[index].events = eventsByOwner[rows[index].draft.id] ?? []
        }
        if unmatchedNames.isEmpty == false {
            notes.append(unmatchedSummary(unmatchedNames))
        }
        return Table(fileName: fileName,
                     format: .legacyJSON,
                     encodingName: "UTF-8",
                     delimiter: "—",
                     rows: rows,
                     notes: notes,
                     headers: [],
                     categories: categories,
                     defaultCurrency: defaultCurrency,
                     unmatchedEventOwners: unmatchedNames)
    }

    static func unmatchedSummary(_ names: [String]) -> String {
        let head = Array(Set(names)).prefix(3).joined(separator: "、")
        return "\(names.count) 条历史记录找不到属于哪条订阅（\(head)），没导"
    }

    private static func looseJSONObjects(_ data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        switch object {
        case let array as [[String: Any]]:
            return array
        case let dictionary as [String: Any]:
            for key in ["subscriptions", "items", "data", "list", "records"] {
                if let array = dictionary[key] as? [[String: Any]] { return array }
            }
            // 整份文件就是一条订阅（`{"name":"Netflix","price":45}`）也认，
            // 但要有业务键 —— 否则一份坏掉的备份包会被当成「一条没名字的订阅」而不是「读不出来」。
            let keys = Set(dictionary.keys.map { normalizeHeader($0) })
            return keys.contains(where: { fieldForExact($0) != nil || fieldByKeyword($0) != nil }) ? [dictionary] : nil
        default:
            return nil
        }
    }

    private static func objectTable(objects: [[String: Any]],
                                    fileName: String,
                                    categories: [SubscriptionCategory],
                                    defaultCurrency: String) throws -> Table {
        var rows: [Row] = []
        for (index, object) in objects.enumerated() {
            // 「Name」和「name」同时存在是可能的，归一化后撞键不能崩，保留先出现的那个值。
            var normalized: [String: Any] = [:]
            for (key, value) in object where normalized[normalizeHeader(key)] == nil {
                normalized[normalizeHeader(key)] = value
            }
            var values: [Field: String] = [:]
            for field in Field.allCases {
                if let text = normalizedField(field, in: normalized) { values[field] = text }
            }
            var draft = SubscriptionDraft()
            draft.currencyCode = defaultCurrency
            var stableID: UUID?
            if let value = normalized["id"] ?? normalized["uuid"] ?? normalized["编号"],
               let text = looseText(value), let uuid = UUID(uuidString: text) {
                stableID = uuid
                draft.id = uuid
            }
            var presentExtras: Set<ExtraColumn> = []
            if let text = firstText(in: normalized, keys: ExtraColumn.plan.keys) {
                draft.plan = text
                presentExtras.insert(.plan)
            }
            if let text = firstText(in: normalized, keys: ExtraColumn.notes.keys) {
                draft.notes = text
                presentExtras.insert(.notes)
            }
            if let text = firstText(in: normalized, keys: ExtraColumn.paymentMethod.keys) {
                draft.paymentMethod = text
                presentExtras.insert(.paymentMethod)
            }
            if let text = firstText(in: normalized, keys: ExtraColumn.state.keys), let state = state(from: text) {
                draft.state = state
                presentExtras.insert(.state)
            }
            if let text = firstText(in: normalized, keys: ["icon", "图标", "sf symbol"]), draft.iconSymbolName == nil {
                draft.iconSymbolName = text
            }
            rows.append(Row(sourceLabel: "JSON 第 \(index + 1) 条",
                            base: draft,
                            raw: values,
                            stableID: stableID,
                            presentExtras: presentExtras,
                            categories: categories,
                            defaultCurrency: defaultCurrency))
        }
        guard rows.isEmpty == false else { throw Failure.emptyFile }
        return Table(fileName: fileName,
                     format: .objectJSON,
                     encodingName: "UTF-8",
                     delimiter: "—",
                     rows: rows,
                     notes: ["这是通用 JSON：只认名称、金额、币种、周期、日期、分类和套餐/备注这几类键，其余字段原样留着不导"],
                     headers: objects.first?.keys.sorted() ?? [],
                     categories: categories,
                     defaultCurrency: defaultCurrency)
    }

    private static func normalizedField(_ field: Field, in object: [String: Any]) -> String? {
        for name in aliases[field] ?? [] where object[name] != nil {
            if let text = looseText(object[name]) { return text }
        }
        // 键名带说明或大小写混着写（「Monthly Price (USD)」）时退到关键字。
        for (key, value) in object {
            guard fieldByKeyword(key) == field, let text = looseText(value) else { continue }
            return text
        }
        return nil
    }

    private static func firstText(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key], let text = looseText(value) { return text }
        }
        return nil
    }

    private static func looseText(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : string
        case let number as NSNumber:
            // JSON 里的布尔值会被桥成 NSNumber，别把 `true` 当文字塞进套餐名。
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.stringValue
        default:
            return nil
        }
    }
}
