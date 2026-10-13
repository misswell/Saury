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
///
/// 读的时候一条一条解：扩展那边可能比主 App 先更新、写下主 App 看不懂的 `kind`。
/// 整份一起解的话那一条会把整条队列判成解不开 —— 用户后头分享的每一条都进不来，
/// 这就是「不丢失」的反面。看不懂的留在队里，看得懂的照旧按顺序消费。
enum ExternalInputStore {
    static let suiteName = "group.com.guofeng.saury"
    static let key = "qijian.externalDrafts"
    /// 只有一个草稿位的老格式：读出来补进队列，不让它凭空消失。
    private static let legacyKey = "qijian.externalItemDraft"

    /// 队列存在哪儿。生产就是 App Group 那份 defaults；测试把它换成一个独立 suite，
    /// 免得跑一次单测就在真机上留一条待办。
    nonisolated(unsafe) static var storage: UserDefaults =
        UserDefaults(suiteName: suiteName) ?? .standard

    /// 队列里的一项。看得懂的就是草稿，看不懂的留着原始字节，等下一版认识它的人来读。
    private enum Item {
        case known(ExternalDraft)
        case unreadable(Data)
    }

    static func store(_ payload: ExternalPayload, source: String) {
        var items = read()
        items.append(.known(ExternalDraft(id: UUID(), createdAt: Date(), source: source, payload: payload)))
        save(items)
    }

    /// 取最早的那一条看得懂的（方案 §58 的 FIFO）。
    /// 剩下的 —— 包括看不懂的那些 —— 原样留在队列里。
    @MainActor
    static func consume() -> ExternalDraft? {
        var items = read()
        guard let index = items.firstIndex(where: { if case .known = $0 { return true }; return false })
        else { return nil }
        guard case .known(let draft) = items[index] else { return nil }
        items.remove(at: index)
        save(items)
        return draft
    }

    static func queue() -> [ExternalDraft] {
        read().compactMap { item in
            if case .known(let draft) = item { return draft }
            return nil
        }
    }

    /// 队列里有几条是这一版看不懂的。页面用它说明「有一条带不过来」，
    /// 而不是让用户以为分享没生效。
    static func unreadableCount() -> Int {
        read().filter { if case .unreadable = $0 { return true }; return false }.count
    }

    private static func read() -> [Item] {
        guard let data = storage.data(forKey: key) else { return legacyItems() }
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // 整份都不是数组了：留着不动，只报告。写一次就是把用户的东西抹掉一次。
            SauryLog.saveFailed("读取外部输入队列", JSONError.notAnArray)
            return []
        }
        return objects.compactMap { object in
            guard let encoded = try? JSONSerialization.data(withJSONObject: object) else {
                SauryLog.saveFailed("外部输入里有一条转不回 JSON", JSONError.notAnArray)
                return nil
            }
            guard let draft = try? JSONDecoder().decode(ExternalDraft.self, from: encoded) else {
                return .unreadable(encoded)
            }
            return .known(draft)
        }
    }

    private static func save(_ items: [Item]) {
        storage.removeObject(forKey: legacyKey)
        let objects: [[String: Any]] = items.compactMap { item in
            switch item {
            case .known(let draft):
                guard let encoded = try? JSONEncoder().encode(draft),
                      let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                else { return nil }
                return object
            case .unreadable(let data):
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects) else { return }
        storage.set(data, forKey: key)
    }

    /// 老格式那一条每次读都照原样递出来，**不在读的时候删**。
    /// 只看一眼就把老草稿抹掉的话，用户那一条再也不会进来 —— 「不丢失」的反面。
    /// 真正把它换掉的是 `save`：队列第一次落盘时老那一格才被清走。
    private static func legacyItems() -> [Item] {
        guard let data = storage.data(forKey: legacyKey) else { return [] }
        do {
            let draft = try JSONDecoder().decode(ExternalItemDraft.self, from: data)
            return [.known(ExternalDraft(id: UUID(), createdAt: .distantPast, source: "外部输入",
                                         payload: .fields(draft)))]
        } catch {
            SauryLog.saveFailed("迁移旧的外部输入", error)
            return []
        }
    }

    private enum JSONError: LocalizedError {
        case notAnArray
        var errorDescription: String? { "队列里存的不是外部输入数组那个形状" }
    }
}

/// 队列里的一条外部输入 → 添加表单的初值。
///
/// 这一层是纯函数（只有图片那一支把「搬文件」注入进来），所以 §10.5 那几条
/// —— 文字取第一行当名字、链接把来源留下、图片不许静默丢 ——
/// 都能不问 UI 直接问出来。
enum ExternalIntake {
    enum Problem: LocalizedError, Equatable {
        /// 这一条压根没有能当名字的东西。丢掉它必须说，不能当没收到。
        case nothingUsable(source: String)

        var errorDescription: String? {
            switch self {
            case .nothingUsable(let source): return "\(source)递过来的内容里没有能当名字的文字。"
            }
        }
    }

    static func prefill(for draft: ExternalDraft,
                        promoting: (String) throws -> String = { try SharedImageIngest.promote($0) }) throws -> AddPrefill {
        switch draft.payload {
        case .text(let text):
            // 第一行有内容的当名字：分享过来的文字经常顶着一个空行，
            // 照字面只认第一行的话那条就会被判成「没有能用的」，用户白分享一次。
            let lines = nonEmptyLines(of: text)
            guard let name = lines.first else { throw Problem.nothingUsable(source: draft.source) }
            // 剩下的行留在备注里。用户给的东西不能读一行就扔掉剩下的。
            let rest = lines.dropFirst().joined(separator: "\n")
            return AddPrefill(name: name, note: rest.isEmpty ? nil : rest)

        case .url(let string):
            // 名字取域名，整条链接落在备注里 —— 订阅这一层没有独立的来源字段，
            // 说「记在来源里」而哪儿都不写，就是 §10.5 讲的「静默丢弃」。
            let name = host(of: string)
            return AddPrefill(name: name.isEmpty ? string : name, note: string)

        case .fields(let fields):
            // 只取名字和来源。老「到期物品」那套价格 / 保质期 / 周期不能顺手变成订阅的默认值。
            let name = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { throw Problem.nothingUsable(source: draft.source) }
            let source = fields.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AddPrefill(name: name, note: (source?.isEmpty ?? true) ? nil : source)

        case .image(let fileName):
            // 搬不进图标库就抛出去：一张图被悄悄扔掉，比弹一条错误难查得多。
            return AddPrefill(iconImageFile: try promoting(fileName))
        }
    }

    private static func nonEmptyLines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func host(of string: String) -> String {
        guard let host = URL(string: string)?.host?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
