import XCTest
@testable import Saury

/// 任务书 §3.2 的解析层：选取文件 → 解析 → 异常与重复。
///
/// 这里测的是「文件里写了什么、这么写行不行」，不测该不该导（那是 `ImportConflictTests`）。
/// 编码那几条用的是真实字节：iconv 产出的 GBK / Big5 文件长什么样就怎么测，
/// 因为「能解码」和「解对了」是两回事 —— 旧中文编码在 Latin-1 下能解出一堆乱码。
final class ImportParserTests: XCTestCase {

    private func parse(_ text: String,
                       fileName: String = "订阅.csv",
                       categories: [SubscriptionCategory] = DefaultCategories.items,
                       defaultCurrency: String = "CNY") throws -> ImportParser.Table {
        try ImportParser.parse(data: Data(text.utf8), fileName: fileName,
                               categories: categories, defaultCurrency: defaultCurrency)
    }

    private func parse(_ data: Data,
                       fileName: String = "订阅.csv",
                       defaultCurrency: String = "CNY") throws -> ImportParser.Table {
        try ImportParser.parse(data: data, fileName: fileName,
                               categories: DefaultCategories.items, defaultCurrency: defaultCurrency)
    }

    private func row(_ table: ImportParser.Table, _ index: Int = 0) -> ImportParser.Row {
        table.rows[index]
    }

    // MARK: - CSV 结构

    /// 引号里的逗号、换行、`""` 都是内容不是分隔（RFC 4180）。
    /// 用 `split(separator: ",")` 做不出这一条，所以状态机要自己扛。
    func testCSVKeepsCommasNewlinesAndQuotesInsideFields() throws {
        let csv = #"""
        名称,备注,金额,币种,周期
        "Netflix","家庭, 4 人
        含税",45,CNY,monthly
        "他说的""hi""",带引号的备注,9,USD,yearly
        """#
        let table = try parse(csv)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(row(table).raw[.name], "Netflix")
        XCTAssertEqual(row(table).base.notes, "家庭, 4 人\n含税")
        XCTAssertEqual(row(table).presentExtras, [.notes])
        XCTAssertEqual(row(table).draft.priceMinorUnits, 4500)
        XCTAssertEqual(row(table, 1).raw[.name], "他说的\"hi\"")
        XCTAssertEqual(row(table, 1).base.notes, "带引号的备注")
        XCTAssertTrue(table.notes.contains { $0.contains("备注") }, table.notes.description)
    }

    /// BOM、制表符、分号：Excel 的「Unicode 文本」和欧洲区域设置都长这样。
    func testCSVHandlesBOMTabAndSemicolon() throws {
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(contentsOf: "名称,金额,币种,周期\n百度网盘,45,CNY,每月".utf8)
        let bomTable = try parse(bom)
        XCTAssertEqual(bomTable.encodingName, "UTF-8（带 BOM）")
        XCTAssertEqual(row(bomTable).raw[.name], "百度网盘")
        XCTAssertEqual(row(bomTable).draft.priceMinorUnits, 4500)

        let tabbed = try parse("名称\t金额\t币种\t周期\nNetflix\t45\tCNY\tmonthly")
        XCTAssertEqual(tabbed.delimiter, "制表符")
        XCTAssertEqual(row(tabbed).raw[.amount], "45")
        XCTAssertTrue(tabbed.notes.contains { $0.contains("制表符") })

        let semicolon = try parse("名称;金额;币种;周期\nNetflix;45;CNY;monthly")
        XCTAssertEqual(semicolon.delimiter, "分号")
        XCTAssertEqual(row(semicolon).draft.currencyCode, "CNY")
    }

    /// 老格式没有表头也能读：按「名称,金额,币种,周期」的位置排，并且把这话讲出来。
    func testCSVWithoutHeaderFallsBackToPositionalColumns() throws {
        let table = try parse("Netflix,45,CNY,monthly\niCloud,68,CNY,每月")
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(row(table).raw[.name], "Netflix")
        XCTAssertEqual(row(table).raw[.cycle], "monthly")
        XCTAssertEqual(row(table, 1).draft.cycle, .monthly)
        XCTAssertTrue(table.notes.contains { $0.contains("没认出表头") })
        XCTAssertTrue(table.notes.contains { $0.contains("没有起始日期") })
    }

    /// 表头别名：中英、带括号说明、大小写混着写都要认，认不出来的整列要报出来。
    func testHeaderAliasesAndUnknownColumnReporting() throws {
        let csv = """
        订阅名称,Monthly Price (USD),CCY,Billing Cycle,Next Billing Date,Group,创建者
        Netflix,45,USD,monthly,2026-03-07,video,me
        """
        let table = try parse(csv)
        let raw = row(table).raw
        XCTAssertEqual(raw[.name], "Netflix")
        XCTAssertEqual(raw[.amount], "45")
        XCTAssertEqual(raw[.currency], "USD")
        XCTAssertEqual(raw[.cycle], "monthly")
        XCTAssertEqual(raw[.startDate], "2026-03-07")
        XCTAssertEqual(raw[.category], "video")
        XCTAssertTrue(table.notes.contains { $0.contains("创建者") }, table.notes.description)
    }

    /// 编号列：是 UUID 就当稳定编号，不是就只能按新增处理 —— 不能拿一个「12」去冒充别人的编号。
    func testIdentifierColumnOnlyBecomesStableIDWhenItIsAUUID() throws {
        let uuid = UUID()
        let table = try parse("编号,名称,金额,周期\n\(uuid.uuidString),Netflix,45,monthly\n12,iCloud,68,monthly")
        XCTAssertEqual(row(table).stableID, uuid)
        XCTAssertEqual(row(table).draft.id, uuid)
        XCTAssertNil(row(table, 1).stableID)
        XCTAssertTrue(row(table, 1).advisories.contains { $0.contains("按新增处理") })
    }

    // MARK: - 编码

    /// GBK / Big5 的中文文件读不了要明说。这两个字节串是 `iconv` 真产出的文件，
    /// 不是编的：它们都能被 Latin-1「成功」解码成乱码，所以必须靠内容拦下来。
    func testLegacyChineseEncodingsAreRejectedNotMisread() {
        // 「名称,金额,币种,周期\nNetflix,45,CNY,每月\n腾讯会议,198,CNY,每月」的 GB18030 字节
        let gbk: [UInt8] = [0xC3, 0xFB, 0xB3, 0xC6, 0x2C, 0xBD, 0xF0, 0xB6, 0xEE, 0x2C, 0xB1, 0xD2,
                            0xD6, 0xD6, 0x2C, 0xD6, 0xDC, 0xC6, 0xDA, 0x0A, 0x4E, 0x65, 0x74, 0x66,
                            0x6C, 0x69, 0x78, 0x2C, 0x34, 0x35, 0x2C, 0x43, 0x4E, 0x59, 0x2C, 0xC3,
                            0xBF, 0xD4, 0xC2, 0x0A, 0xCC, 0xDA, 0xD1, 0xB6, 0xBB, 0xE1, 0xD2, 0xE9,
                            0x2C, 0x31, 0x39, 0x38, 0x2C, 0x43, 0x4E, 0x59, 0x2C, 0xC3, 0xBF, 0xD4,
                            0xC2, 0x0A]
        // 「名稱,金額\nNetflix,45」的 Big5 字节
        let big5: [UInt8] = [0xA6, 0x57, 0xBA, 0xD9, 0x2C, 0xAA, 0xF7, 0xC3, 0x42, 0x0A,
                             0x4E, 0x65, 0x74, 0x66, 0x6C, 0x69, 0x78, 0x2C, 0x34, 0x35, 0x0A]

        for (name, bytes) in [("GB18030", gbk), ("Big5", big5)] {
            XCTAssertThrowsError(try parse(Data(bytes), fileName: "\(name).csv"), name) { error in
                XCTAssertEqual(error as? ImportParser.Failure, .undecodableText, name)
                let text = (error as? ImportParser.Failure)?.errorDescription ?? ""
                XCTAssertTrue(text.contains("UTF-8"), text)
                XCTAssertTrue(text.contains("GBK"), text)
            }
        }
    }

    /// 反过来：西欧单字节文件要放进来，不能一并拒掉。é 和 €（CP1252 的 0x80）都是合法内容。
    func testWesternSingleByteFilesDecode() throws {
        let latin: [UInt8] = [0x43, 0x61, 0x66, 0xE9, 0x2C, 0x35, 0x2C, 0x55, 0x53, 0x44, 0x0A]  // Café,5,USD
        let table = try parse(Data(latin))
        XCTAssertEqual(table.encodingName, "Windows-1252")
        XCTAssertEqual(row(table).raw[.name], "Café")
        XCTAssertTrue(table.notes.contains { $0.contains("Windows-1252") })

        let euro: [UInt8] = [0x50, 0x61, 0x79, 0x70, 0x61, 0x6C, 0x2C, 0x35, 0x2C, 0x80, 0x0A]  // PayPal,5,<CP1252 €>
        XCTAssertEqual(try parse(Data(euro)).encodingName, "Windows-1252")
    }

    /// 带 BOM 的 UTF-16（Excel「Unicode 文本」）要读对，而且不能把 BOM 当成第一个字段的一部分。
    func testUTF16WithBOMDecodes() throws {
        let text = "名称,金额,币种,周期\n百度网盘,68,CNY,每月"
        for (bom, encoding, label) in [(Data([0xFF, 0xFE]), String.Encoding.utf16LittleEndian, "UTF-16 LE"),
                                       (Data([0xFE, 0xFF]), String.Encoding.utf16BigEndian, "UTF-16 BE")] {
            var data = bom
            data.append(text.data(using: encoding)!)
            let table = try parse(data)
            XCTAssertEqual(table.encodingName, label)
            XCTAssertEqual(row(table).raw[.name], "百度网盘")   // BOM 没混进名字
            XCTAssertEqual(row(table).draft.priceMinorUnits, 6800)
        }
    }

    // MARK: - 字段级校验

    /// 读不出来的字段要挡住这一行，并且说清是哪一行的哪个值。
    func testUnreadableValuesBlockTheirRowAndNameTheOffendingText() throws {
        let csv = """
        名称,金额,币种,周期,起始日期,分类
        坏金额,abc,CNY,monthly,2026-01-01,video
        坏币种,45,RMB,monthly,2026-01-01,video
        坏周期,45,CNY,biweekly,2026-01-01,video
        坏日期,45,CNY,monthly,2026-13-45,video
        ,45,CNY,monthly,2026-01-01,video
        好行,45,CNY,monthly,2026-01-01,video
        """
        let table = try parse(csv)
        XCTAssertEqual(table.rows.count, 6)
        XCTAssertTrue(row(table, 0).issues.contains { $0.contains("abc") }, row(table, 0).issues.description)
        XCTAssertTrue(row(table, 1).issues.contains { $0.contains("RMB") })
        XCTAssertTrue(row(table, 2).issues.contains { $0.contains("biweekly") })
        XCTAssertTrue(row(table, 3).issues.contains { $0.contains("2026-13-45") })
        XCTAssertTrue(row(table, 4).issues.contains { $0.contains("没有名字") })
        XCTAssertTrue(row(table, 5).issues.isEmpty, row(table, 5).issues.description)
        for index in 0..<5 { XCTAssertTrue(row(table, index).isBlocked) }
    }

    /// `failedFields` 是界面用的判据：哪一列没读出来，不能靠 `issues` 的措辞去猜。
    /// 预览页拿它决定金额/周期宁可印「—」，也不拿 draft 里那个 0 冒充文件写过的数。
    func testFailedFieldsNameExactlyTheColumnsThatDidNotParse() throws {
        let csv = """
        名称,金额,币种,周期,起始日期,分类
        坏金额和坏周期,abc,CNY,biweekly,2026-01-01,video
        坏币种,45,RMB,monthly,2026-13-45,video
        好行,45,CNY,monthly,2026-01-01,video
        """
        let table = try parse(csv)
        XCTAssertEqual(row(table, 0).failedFields, [.amount, .cycle])
        XCTAssertEqual(row(table, 1).failedFields, [.currency, .startDate])
        XCTAssertTrue(row(table, 2).failedFields.isEmpty, row(table, 2).failedFields.description)

        // 改好一列，那一列就不该还挂着「读不出来」。
        let fixed = table.editing(rowID: row(table, 0).id, field: .amount, to: "30")
        XCTAssertEqual(row(fixed, 0).failedFields, [.cycle])
    }

    /// 能读但意思要提醒的：欧洲千分位写法、一次性、文件里的分类本机没有。
    func testAdvisoriesForValuesThatReadButDeserveANote() throws {
        let csv = """
        名称,金额,币种,周期,分类
        欧洲写法,1.234,EUR,monthly,video
        一次性买断,300,CNY,一次性,健身
        """
        let table = try parse(csv)
        XCTAssertEqual(row(table).draft.priceMinorUnits, 123400)
        XCTAssertTrue(row(table).advisories.contains { $0.contains("欧洲写法") }, row(table).advisories.description)
        XCTAssertTrue(row(table, 1).advisories.contains { $0.contains("不进月均") })
        XCTAssertEqual(row(table, 1).draft.category, DefaultCategories.fallback.id)
        XCTAssertTrue(row(table, 1).advisories.contains { $0.contains("健身") })
        for index in 0..<2 { XCTAssertTrue(row(table, index).issues.isEmpty, row(table, index).issues.description) }
    }

    /// 默认币种跟着本机设置走：同一份没有币种列的文件，在改成 USD 的设备上读成 USD。
    func testDefaultCurrencyComesFromPreferences() throws {
        let table = try parse("名称,金额,周期\nNetflix,45,monthly", defaultCurrency: "USD")
        XCTAssertEqual(row(table).draft.currencyCode, "USD")
        XCTAssertEqual(row(table).draft.priceMinorUnits, 4500)
    }

    /// 改一个字段只重算那一行；文件原文留在 `base` / `raw` 里，纠错界面两个都还要能显示。
    func testEditingOneFieldRevalidatesOnlyThatRow() throws {
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let id = UUID()
        let item = SubscriptionImportExport.ExportedSubscription(
            id: id, name: "iCloud", plan: "50GB", iconSymbolName: "icloud.fill", iconImageFile: nil,
            iconColorHex: nil, colorHexes: [], priceMinorUnits: -4500, currencyCode: "CNY",
            cycle: "monthly", customMonths: 1, category: "cloud", state: "autoRenew",
            startDate: created, endDate: nil, reminderDays: 3, shareEnabled: false, shareHeadcount: 1,
            shareMode: "even", shareMyMinorUnits: 0, paymentMethod: "支付宝", notes: "全家共用", createdAt: created)
        let payload = SubscriptionImportExport.ExportPayload(exportedAt: created, subscriptions: [item], events: [])
        let table = try parse(JSONEncoder.backup.encode(payload), fileName: "导出.json")

        XCTAssertTrue(row(table).isBlocked, "负数金额必须挡住，不能悄悄抹成 0 或转正数")
        XCTAssertEqual(row(table).base.priceMinorUnits, -4500, "原文里那个负数要留着")

        let fixed = table.editing(rowID: row(table).id, field: .amount, to: "45")
        XCTAssertTrue(row(fixed).issues.isEmpty, row(fixed).issues.description)
        XCTAssertEqual(row(fixed).draft.priceMinorUnits, 4500)
        XCTAssertEqual(row(fixed).raw[.amount], "45")
        XCTAssertEqual(row(fixed).base.priceMinorUnits, -4500, "纠错不改动文件原文")
        XCTAssertEqual(row(fixed).base.notes, "全家共用", "改金额不该把别的字段冲掉")
        XCTAssertEqual(row(fixed).draft.notes, "全家共用")
        XCTAssertEqual(fixed.rows.count, 1)
    }

    /// 把字段清空就是「这一列没写」：名字空掉要重新挡住。
    func testClearingAFieldRevalidatesAsMissing() throws {
        let table = try parse("名称,金额,币种,周期\nNetflix,45,CNY,monthly")
        let cleared = table.editing(rowID: row(table).id, field: .name, to: "   ")
        XCTAssertTrue(cleared.rows[0].issues.contains { $0.contains("没有名字") })
        XCTAssertNil(cleared.rows[0].raw[.name])
    }

    // MARK: - 值解析

    func testCycleTextVariants() throws {
        let cases: [(String, BillingCycle, Int?)] = [
            ("每月", .monthly, nil), ("monthly", .monthly, nil), ("MONTHLY", .monthly, nil),
            ("包年", .yearly, nil), ("annual", .yearly, nil), ("每季度", .quarterly, nil),
            ("半年", .semiannual, nil), ("每周", .weekly, nil), ("7天", .weekly, nil),
            ("每3个月", .quarterly, nil), ("every 3 months", .quarterly, nil),
            ("每 2 个月", .custom, 2), ("一次性", .oneTime, nil), ("买断", .oneTime, nil),
        ]
        for (text, cycle, months) in cases {
            let parsed = try XCTUnwrap(ImportParser.cycle(from: text), text)
            XCTAssertEqual(parsed.cycle, cycle, text)
            XCTAssertEqual(parsed.customMonths, months, text)
        }
        XCTAssertNil(ImportParser.cycle(from: "biweekly"))
        XCTAssertNil(ImportParser.cycle(from: "看情况"))
    }

    /// 日期歧义不猜：`7/3/2026` 是 US 还是 CN 导的没人说得清，宁可报读不出来。
    func testDateVariantsAndAmbiguity() {
        XCTAssertEqual(ImportParser.date(from: "2026-03-07"), ImportParser.date(from: "2026年3月7日"))
        XCTAssertEqual(ImportParser.date(from: "2026/3/7"), ImportParser.date(from: "2026-03-07"))
        XCTAssertEqual(ImportParser.date(from: "2561472000"), Date(timeIntervalSince1970: 2_561_472_000))
        XCTAssertEqual(ImportParser.date(from: "2026-03-07T00:00:00Z"),
                       Date(timeIntervalSince1970: 1_772_841_600))
        XCTAssertNil(ImportParser.date(from: "7/3/2026"))
        XCTAssertNil(ImportParser.date(from: "昨天"))
        XCTAssertNil(ImportParser.date(from: ""))
    }

    func testStateTextVariants() {
        XCTAssertEqual(ImportParser.state(from: "已停用"), .inactive)
        XCTAssertEqual(ImportParser.state(from: "cancelled"), .inactive)
        XCTAssertEqual(ImportParser.state(from: "自动续费"), .autoRenew)
        XCTAssertNil(ImportParser.state(from: "看不懂"))
    }

    // MARK: - JSON

    /// App 自己导出的 V1 JSON 要能原样读回来：编号、创建时间、事件都在。
    func testLegacyJSONKeepsIdentifierTimestampsAndEvents() throws {
        let id = UUID(), eventID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let item = SubscriptionImportExport.ExportedSubscription(
            id: id, name: "iCloud", plan: "200GB", iconSymbolName: nil, iconImageFile: nil, iconColorHex: nil,
            colorHexes: [], priceMinorUnits: 2100, currencyCode: "CNY", cycle: "yearly", customMonths: 1,
            category: "cloud", state: "autoRenew", startDate: start, endDate: nil, reminderDays: 3,
            shareEnabled: true, shareHeadcount: 4, shareMode: "even", shareMyMinorUnits: 525,
            paymentMethod: "支付宝", notes: "全家共用", createdAt: start)
        let event = SubscriptionImportExport.ExportedEvent(
            id: eventID, subscriptionID: id, subscriptionName: "iCloud", type: "charged",
            amountMinorUnits: 2100, currencyCode: "CNY", note: "去年那笔", happenedAt: start)
        let orphan = SubscriptionImportExport.ExportedEvent(
            id: UUID(), subscriptionID: nil, subscriptionName: "已经不存在的订阅", type: "note",
            amountMinorUnits: 0, currencyCode: "CNY", note: "", happenedAt: start)
        let payload = SubscriptionImportExport.ExportPayload(exportedAt: start,
                                                            subscriptions: [item],
                                                            events: [event, orphan])
        let table = try parse(JSONEncoder.backup.encode(payload), fileName: "导出.json")

        XCTAssertEqual(table.format, .legacyJSON)
        let parsed = row(table)
        XCTAssertEqual(parsed.stableID, id)
        XCTAssertEqual(parsed.draft.id, id)
        XCTAssertEqual(parsed.draft.priceMinorUnits, 2100)
        XCTAssertEqual(parsed.draft.cycle, .yearly)
        XCTAssertEqual(parsed.draft.shareHeadcount, 4)
        XCTAssertEqual(parsed.createdAt, start)
        XCTAssertTrue(parsed.carriesWholeRecord)
        XCTAssertEqual(parsed.events.count, 1)
        XCTAssertEqual(parsed.events.first?.id, eventID)
        XCTAssertEqual(parsed.events.first?.subscriptionID, id)
        XCTAssertEqual(parsed.events.first?.note, "去年那笔")
        XCTAssertEqual(table.unmatchedEventOwners, ["已经不存在的订阅"])
        XCTAssertTrue(table.eventLossSummary?.contains("已经不存在的订阅") == true)
    }

    /// 外部 JSON 键名各家不同：按别名尽量搬，认不出的字段留在订阅默认值上而不是编一个。
    func testExternalObjectJSONMapsAliasedKeys() throws {
        let id = UUID()
        let json = """
        {"subscriptions":[
          {"service":"ChatGPT","monthly price (usd)":20,"currency":"USD","frequency":"monthly","plan":"Plus"},
          {"name":"百度网盘","price":"25","id":"\(id.uuidString)","cycle":"每月","icon":"cloud","status":true}
        ]}
        """
        let table = try parse(json, fileName: "外部.json")
        XCTAssertEqual(table.format, .objectJSON)
        XCTAssertEqual(row(table).raw[.name], "ChatGPT")
        XCTAssertEqual(row(table).draft.priceMinorUnits, 2000)
        XCTAssertEqual(row(table).draft.currencyCode, "USD")
        XCTAssertEqual(row(table).base.plan, "Plus")
        XCTAssertEqual(row(table, 1).stableID, id)
        XCTAssertEqual(row(table, 1).draft.cycle, .monthly)
        XCTAssertEqual(row(table, 1).draft.iconSymbolName, "cloud")
        XCTAssertFalse(row(table, 1).presentExtras.contains(.state), "布尔值不该被当成「状态」文字")
        XCTAssertTrue(table.notes.contains { $0.contains("通用 JSON") })
    }

    /// 整份文件就是一条订阅的 JSON 也认；但没有业务键的字典不能装作读出来了。
    func testSingleObjectJSONFileAndKeylessDictionary() throws {
        let table = try parse(#"{"name":"Netflix","price":"45","currency":"CNY","cycle":"monthly"}"#,
                              fileName: "一条.json")
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(row(table).draft.priceMinorUnits, 4500)
        XCTAssertEqual(row(table).draft.cycle, .monthly)
        XCTAssertThrowsError(try parse(#"{"foo":1,"bar":"x"}"#, fileName: "键值.json")) {
            XCTAssertEqual($0 as? ImportParser.Failure, .notCSVOrJSON)
        }
    }

    // MARK: - 坏文件

    func testEmptyAndJunkAndBackupFilesFailWithSpecificReasons() {
        XCTAssertThrowsError(try parse("")) { XCTAssertEqual($0 as? ImportParser.Failure, .emptyFile) }
        XCTAssertThrowsError(try parse("   \n\n  \n")) { XCTAssertEqual($0 as? ImportParser.Failure, .emptyFile) }
        XCTAssertThrowsError(try parse(Data())) { XCTAssertEqual($0 as? ImportParser.Failure, .emptyFile) }
        XCTAssertThrowsError(try parse("{这不是 JSON")) {
            XCTAssertEqual($0 as? ImportParser.Failure, .notCSVOrJSON)
        }
        XCTAssertThrowsError(try parse("[1,2,3]")) {
            XCTAssertEqual($0 as? ImportParser.Failure, .notCSVOrJSON)
        }
        // 一列的散文不是订阅表：与其导一条 0 元的「hello world」，不如直接说这不是表格。
        XCTAssertThrowsError(try parse("hello world\nsecond line")) {
            XCTAssertEqual($0 as? ImportParser.Failure, .notCSVOrJSON)
        }
        // 完整备份包走的是另一条路，误选要指对方向。
        XCTAssertThrowsError(try parse(Data(BackupContainer.magic + [0x00, 0x01]))) {
            let failure = $0 as? ImportParser.Failure
            XCTAssertEqual(failure, .fullBackupFile)
            XCTAssertTrue(failure?.errorDescription?.contains("从备份恢复") == true)
        }
    }
}
