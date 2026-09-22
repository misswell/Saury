import Foundation

/// 从快捷指令、快速添加带进来的一条待确认记录：字段已经拆好，直接进添加页。
struct ExternalItemDraft: Codable {
    var name: String
    var priceMinorUnits: Int?
    var currencyCode: String?
    var expiryDate: Date?
    var recurrence: ExpiryRecurrence?
    var category: ExpiryCategory?
    var sourceURL: String?
}

/// 外部入口能递进来的东西（方案 §57）。
enum ExternalPayload: Codable {
    /// 已经拆成字段的（快捷指令、快速添加模板）。
    case fields(ExternalItemDraft)
    /// 分享出来的一段文字：第一行当名字。
    case text(String)
    /// 分享出来的链接：除了名字还要留下来源。
    case url(String)
    /// 图片。图本身落在 App Group 的暂存目录里，这里只带文件名。
    case image(String)

    /// 线上格式自己写死成 `{"kind":"image","value":"<uuid>.jpg"}`。
    ///
    /// 合成的 Codable 会把这一条编成 `{"image":{"_0":…}}`，那是 Swift 的内部形状，
    /// 不适合让分享扩展那个 target 手抄一份 —— 两个 target 之间要留一份能读得懂的契约。
    private enum Wire: CodingKey {
        case kind
        case value
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Wire.self)
        switch try box.decode(String.self, forKey: .kind) {
        case "text": self = .text(try box.decode(String.self, forKey: .value))
        case "url": self = .url(try box.decode(String.self, forKey: .value))
        case "image": self = .image(try box.decode(String.self, forKey: .value))
        case "fields":
            self = .fields(try box.decode(ExternalItemDraft.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: box, debugDescription: "不认识的外部输入类型，留着不动。"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Wire.self)
        switch self {
        case .fields(let draft):
            try box.encode("fields", forKey: .kind)
            try box.encode(draft, forKey: .value)
        case .text(let text):
            try box.encode("text", forKey: .kind)
            try box.encode(text, forKey: .value)
        case .url(let url):
            try box.encode("url", forKey: .kind)
            try box.encode(url, forKey: .value)
        case .image(let fileName):
            try box.encode("image", forKey: .kind)
            try box.encode(fileName, forKey: .value)
        }
    }
}

/// 队列里的一项（方案 §58）。
struct ExternalDraft: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let source: String
    let payload: ExternalPayload
}

/// 外部入口的收件队列。
///
/// 只有一个草稿位的时候，第二次分享会把第一次顶掉（方案 §58），所以这里存的是数组，
/// 按进来的顺序一条一条消费。
///
/// 分享扩展是独立 target，只能靠这份 JSON 传话，所以它那边手写了一份同样的形状，
/// 见 `SauryShare/ShareViewController.swift`。两边新增 `ExternalPayload` 分支必须同步改。
enum ExternalInputStore {
    static let suiteName = "group.com.guofeng.saury"
    static let key = "qijian.externalDrafts"
    /// 只有一个草稿位的老格式：读出来补进队列，不让它凭空消失。
    private static let legacyKey = "qijian.externalItemDraft"

    private static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    static func store(_ payload: ExternalPayload, source: String) {
        var drafts = queue()
        drafts.append(ExternalDraft(id: UUID(), createdAt: Date(), source: source, payload: payload))
        save(drafts)
    }

    /// 取最老的一条（方案 §58 的 FIFO）。剩下的留在队列里，等下一次回到前台再处理。
    @MainActor
    static func consume() -> ExternalDraft? {
        var drafts = queue()
        guard !drafts.isEmpty else { return nil }
        let draft = drafts.removeFirst()
        save(drafts)
        return draft
    }

    static func queue() -> [ExternalDraft] {
        guard let data = defaults.data(forKey: key) else { return legacyDrafts() }
        do {
            return try JSONDecoder().decode([ExternalDraft].self, from: data)
        } catch {
            // 解不开就是解不开，宁可留下原来那份，也不能顺手把它清空。
            SauryLog.saveFailed("读取外部输入队列", error)
            return []
        }
    }

    private static func save(_ drafts: [ExternalDraft]) {
        defaults.removeObject(forKey: legacyKey)
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        defaults.set(data, forKey: key)
    }

    private static func legacyDrafts() -> [ExternalDraft] {
        guard let data = defaults.data(forKey: legacyKey) else { return [] }
        do {
            let draft = try JSONDecoder().decode(ExternalItemDraft.self, from: data)
            defaults.removeObject(forKey: legacyKey)
            return [ExternalDraft(id: UUID(), createdAt: Date(), source: "外部输入", payload: .fields(draft))]
        } catch {
            SauryLog.saveFailed("迁移旧的外部输入", error)
            return []
        }
    }
}
