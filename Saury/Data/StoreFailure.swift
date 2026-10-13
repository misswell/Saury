import Foundation

/// 打不开本地库时，先分清是哪种打不开 —— 因为「怎么办」完全不一样。
///
/// 只有文件本身读不出来时，把旧库挪走重建才有意义；
/// 权限或磁盘问题下挪库既修不好又白丢一份数据，那种情况必须原地停手。
///
/// 判据以 `StoreFileProbe` 的文件证据为主：实测 SwiftData 抛出的错误
/// 经常一句解释都没有，光读错误文本会把「文件坏了」和「写不进去」混成一堆。
enum StoreFailure: LocalizedError, Equatable, Codable {
    /// 文件是好的，是 schema/迁移读不动它。老库要留着，等能读懂它的版本。
    case migration(String)
    /// 文件在，但 SQLite 说它不是库或镜像坏了。
    case unreadableStore(String)
    /// 目录不可写、沙盒拒绝、磁盘满、被别人占着 —— 挪库帮不上忙。
    case unwritable(String)
    /// 证据凑不出结论：同样不许动用户的文件。
    case other(String)

    init(_ error: Error, storeURLs: [URL] = []) {
        let text = Self.describe(error)
        switch Self.judge(text: text, storeURLs: storeURLs) {
        case .migration: self = .migration(text)
        case .unreadableStore: self = .unreadableStore(text)
        case .unwritable: self = .unwritable(text)
        case .other: self = .other(text)
        }
    }

    /// 分到了哪一类：所有面向用户的文案和「能不能挪库」都由这一条决定。
    var kind: Kind {
        switch self {
        case .migration: return .migration
        case .unreadableStore: return .unreadableStore
        case .unwritable: return .unwritable
        case .other: return .other
        }
    }

    enum Kind: String { case migration, unreadableStore, unwritable, other }

    var detail: String {
        switch self {
        case .migration(let text), .unreadableStore(let text), .unwritable(let text), .other(let text):
            return text
        }
    }

    /// 挪走旧库能不能救回来。判错这一条的代价是用户的账本，所以默认答案是「不能」。
    ///
    /// 只有「文件确实坏了」才允许挪：那种情况下原文件对谁都没有价值，改名留底是唯一出路。
    /// 结构/迁移问题（`.migration`）恰恰说明文件是**好的**、读不懂它的是我们 ——
    /// 把它改名挪走会让下一个版本也找不到它，那是把能救的变成不能救。
    var canRebuildStore: Bool { kind == .unreadableStore }

    var errorDescription: String? { userText }

    /// 下一步该干什么。四种原因的出路不一样，笼统一句「请重试」等于没说。
    var advice: String {
        switch kind {
        case .migration:
            return "原来的文件一个字节都没动，等一个能读懂它的版本还能接着用；这一趟别在临时库里记要紧的账。"
        case .unreadableStore:
            return "旧文件已经改名留在原处。如果手上有备份，现在从备份或导入找回最快。"
        case .unwritable:
            return "腾出空间、或允许访问之后重新打开 App，原来的库还在原处。"
        case .other:
            return "重新打开 App 再试一次；原来的库还在原处，没有被改名或删除。"
        }
    }

    /// 给用户看的那一句。重点是「你的数据现在在哪」，不是「出错了」。
    var userText: String {
        switch kind {
        case .migration:
            return "这个版本读不动本地库的数据结构。旧文件原样留着，没有删。"
        case .unreadableStore:
            return "本地库文件坏了，SQLite 认不出它。"
        case .unwritable:
            return "本机现在写不进这个库（权限、空间或被占用），App 没有动你原来的文件。"
        case .other:
            return "本地库打不开，原因没能认出来。App 没有动你原来的库。"
        }
    }

    // MARK: - 判据

    /// 文件证据优先，其次才是错误文本；两边都说不清就是 `other`。
    static func judge(text: String, storeURLs: [URL]) -> Kind {
        for url in storeURLs {
            switch StoreFileProbe.verdict(forStoreAt: url) {
            case .absent: continue
            case .intact: return .migration
            case .corrupted: return .unreadableStore
            case .storageBlocked: return .unwritable
            }
        }
        return classify(text)
    }

    /// 兜底的文本判据。顺序是从具体到笼统：
    /// 权限的措辞最常和「打不开文件」混在一起，先判权限才不会把不可写当成损坏。
    static func classify(_ text: String) -> Kind {
        let lowered = text.lowercased()
        let unwritableHints = ["permission denied", "operation not permitted", "read-only",
                               "readonly", "not authorized", "resource busy", "no space", "disk full",
                               "database is locked", "errno=13", "errno=30", "eacces",
                               "只读", "没有权限", "权限"]
        if unwritableHints.contains(where: lowered.contains) { return .unwritable }

        let migrationHints = ["migrat", "mapping model", "model is not configured",
                              "entity for entityname", "failed updating preflight",
                              "column", "schema", "迁移", "结构"]
        if migrationHints.contains(where: lowered.contains) { return .migration }

        let corruptHints = ["not a database", "database corrupt", "file is not a database",
                            "sqlite_corrupt", "sqlite_notadb", "nssqliteerrordomain=26",
                            "isn’t in the correct format", "isn't in the correct format",
                            "correct format", "unrecognized", "malformed",
                            "file appears to be empty", "could not be opened", "couldn’t be opened",
                            "无法解析", "损坏"]
        if corruptHints.contains(where: lowered.contains) { return .unreadableStore }
        return .other
    }

    /// Core Data 的错误信息常藏在 `underlyingErrors` 里，只读第一层会全判成 other。
    /// 走到第八层就停：Swift 侧的 error 桥成 AnyObject 每次都是新对象，
    /// 靠「见过没有」根本挡不住自引用的环。
    private static func describe(_ error: Error) -> String {
        var pieces: [String] = []
        var queue: [Error] = [error]
        var depth = 0
        while let current = queue.popLast(), depth < 8 {
            depth += 1
            pieces.append(String(describing: current))
            if let nsError = current as? NSError {
                pieces.append(contentsOf: nsError.userInfo.values.map { String(describing: $0) })
                queue.append(contentsOf: nsError.underlyingErrors)
            }
        }
        return pieces.joined(separator: " ")
    }
}

/// 一次「挪库重建」的留底。App 必须把它说出来 ——
/// 让用户对着一屏空列表猜数据去哪了，比启动失败更糟。
///
/// 这条记录要活到下一次启动：留底的文件还在磁盘上，眼下用的也确实是另建的新库，
/// 这些事实不会因为「这次打开成功了」就消失。只有用户亲口说知道了才撤。
struct StoreRecovery: Equatable, Codable {
    let reason: StoreFailure
    /// 旧库三件套被改名到了哪里。文件还在原目录，手工还能拿回来。
    let keptAside: [URL]
    let happenedAt: Date

    init(reason: StoreFailure, keptAside: [URL], happenedAt: Date = Date()) {
        self.reason = reason
        self.keptAside = keptAside
        self.happenedAt = happenedAt
    }

    var message: String {
        "\(reason.userText)旧库已经改名留在原目录（\(keptAside.count) 个文件），"
            + "现在这个 App 用的是另建的新库。如果手上有备份，从备份或导入找回最快；"
            + "没有备份的话，那些留底文件也还有机会。"
    }
}
