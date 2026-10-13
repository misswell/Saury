import Foundation
import SQLite3

//
//  动用户的库之前，先问 SQLite 本人。
//
//  光看 SwiftData 抛出来的错是分不了级的：实测（macOS 探针，见 Docs/EON_QA.md）
//  它经常只丢一个 `loadIssueModelContainer`，一个字的解释都没有；
//  「文件不是库」和「目录写不进去」在它嘴里是同一条错误。
//  而这两种情况的处置完全相反：一种该换新库，另一种连碰都不该碰。
//  所以判据落在文件上：目录与文件可不可写、`PRAGMA integrity_check` 过不过。
//

enum StoreFileProbe {
    enum Verdict: Equatable {
        /// 库文件根本不在那个位置 —— 谈不上「读不出来」，也就没有挪走它的理由。
        case absent
        /// 打得开、体检也过：文件是好的，问题出在结构或迁移那一侧。
        case intact
        /// 不是库、镜像坏了：只能换新库，旧文件改名留底。
        case corrupted(cause: String)
        /// 只读、空间不足、被别人占着：挪文件帮不上忙，必须原地停手。
        case storageBlocked(cause: String)
    }

    /// 这个库是「老库」还是「已经在本机这一版」的证据。开库时要不要带迁移计划全靠它。
    enum SchemaEvidence: Equatable {
        case absent
        /// CoreData 盖在库里的版本章。
        case stamped(version: String)
        /// 版本章没读到，但库里还躺着只有旧版本才有的表 —— 当成老库，必须带计划开。
        case legacyTables
        /// 版本章没读到，但库里只有当前版本的表 —— 不带计划开，让 CoreData 自己补列。
        case currentTables
        /// 文件在，两样都读不出来（打不开、不是库）。
        case unreadable
    }

    /// 库自己留下的「我是哪一版」的证据，两种读法按可靠性排：
    ///
    /// 为什么要费这个事：当前版本新加的一列**不能**交给声明好的迁移阶段去补
    /// （`VersionedSchema.models` 只能列在用的类型，新旧两版交得出同一份模型，
    /// 建 custom stage 会当场抛异常），只能让 CoreData 的自动轻量迁移补；
    /// 而从旧版本跳上来又必须走那些阶段。两条路必须分开，分开的凭据在文件里，
    /// 不在 SwiftData 的错误文案里（它给不出解释，见文件头）。
    ///
    /// 1. `Z_METADATA.Z_PLIST` 里 CoreData 盖的版本章 —— 最权威，但**新写完的库可能还没落进
    ///    主文件**（那一行此时在 `-wal` 里），只读打开不一定读得到；
    /// 2. 表名：旧版本的表（`ZEXPIRYITEM`、`ZRENEWALITEM`…）只有老库才有，
    ///    `ZSUBSCRIPTION` 只有 V4 之后才有。表结构在主文件里，不受 WAL 影响。
    ///
    /// 为什么非要分清：拿不准就按「不带迁移计划」开库，等于让 CoreData 对着一个老库做自动迁移，
    /// 而旧实体对它来说是要删掉的 —— 实测那样会把老库里的行洗成零（`Docs/DATA_MIGRATION.md`）。
    /// 那是数据事故，不是降级。所以判不清的时候按老库待：带计划开不出来顶多是打不开。
    static func schemaEvidence(at url: URL, fileManager: FileManager = .default) -> SchemaEvidence {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        guard let connection = openForReading(url) else { return .unreadable }
        defer { sqlite3_close_v2(connection) }
        if let stamped = readVersionIdentifier(in: connection) { return .stamped(version: stamped) }
        let tables = readTableNames(in: connection)
        if tables.contains(where: { legacyTables.contains($0) }) { return .legacyTables }
        if tables.contains(where: { currentTables.contains($0) }) { return .currentTables }
        return .unreadable
    }

    /// 只读打开，但**先按可读写谈**：WAL 模式的库在只读连接下要先建/读 `-shm`，
    /// 拿不到就只能退回去。能不能读到版本章差别就在这一下。
    private static func openForReading(_ url: URL) -> OpaquePointer? {
        for flags in [SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX] {
            var handle: OpaquePointer?
            if sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle { return handle }
            if let handle { sqlite3_close_v2(handle) }
        }
        return nil
    }

    private static let legacyTables: Set<String> = [
        "ZRENEWALITEM", "ZDECISIONRECORD",
        "ZEXPIRYITEM", "ZEXPIRYEVENT", "ZPRODUCTTEMPLATE",
    ]
    private static let currentTables: Set<String> = ["ZSUBSCRIPTION", "ZSUBSCRIPTIONEVENT"]

    private static func readVersionIdentifier(in connection: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, "SELECT Z_PLIST FROM Z_METADATA LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let blob = sqlite3_column_blob(statement, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0 else { return nil }
        let data = Data(bytes: blob, count: length)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let identifiers = dictionary["NSStoreModelVersionIdentifiers"] as? [String] else { return nil }
        return identifiers.first
    }

    private static func readTableNames(in connection: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, "SELECT name FROM sqlite_master WHERE type='table'",
                                 -1, &statement, nil) == SQLITE_OK else { return [] }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            names.insert(String(cString: text).uppercased())
        }
        return names
    }

    static func verdict(forStoreAt url: URL, fileManager: FileManager = .default) -> Verdict {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }

        // 可写性排在体检前面：只读目录里的库体检多半也会失败，
        // 但那种情况把旧库挪走是错的 —— 用户把权限改回来本来就能继续用。
        if let blocked = blockage(for: url, fileManager: fileManager) { return .storageBlocked(cause: blocked) }

        return integrityVerdict(for: url)
    }

    /// 返回一句「为什么现在写不进去」；能写就返回 nil。
    private static func blockage(for url: URL, fileManager: FileManager) -> String? {
        if !fileManager.isWritableFile(atPath: url.path) {
            return "库文件本身不可写（权限或只读卷）：\(url.lastPathComponent)"
        }
        let directory = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path), !fileManager.isWritableFile(atPath: directory.path) {
            return "库文件所在目录不可写：\(directory.lastPathComponent)"
        }
        guard let capacity = availableCapacity(at: directory, fileManager: fileManager), capacity < 8_000_000 else { return nil }
        return "本机可用空间不足 \(ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))，写不进新页"
    }

    private static func availableCapacity(at url: URL, fileManager: FileManager) -> Int64? {
        let attributes = try? fileManager.attributesOfFileSystem(forPath: url.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// 打开一次、跑一次 `PRAGMA integrity_check`，把结果翻译成处置意见。
    private static func integrityVerdict(for url: URL) -> Verdict {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let opened = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard opened == SQLITE_OK, let connection = handle else {
            let outcome = outcome(of: handle, code: opened == SQLITE_OK ? sqlite3_errcode(handle) : opened)
            if let handle { sqlite3_close_v2(handle) }
            return outcome
        }
        defer { sqlite3_close_v2(connection) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(connection, "PRAGMA integrity_check", -1, &statement, nil)
        if prepared != SQLITE_OK {
            return outcome(of: connection, code: sqlite3_errcode(connection))
        }

        var rows: [String] = []
        while true {
            let stepped = sqlite3_step(statement)
            if stepped == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: text))
                if rows.count >= 4 { break }
                continue
            }
            if stepped == SQLITE_DONE { break }
            return outcome(of: connection, code: sqlite3_errcode(connection))
        }
        guard rows.first == "ok" else {
            return .corrupted(cause: "体检没通过：\(rows.joined(separator: "；"))")
        }
        return .intact
    }

    /// SQLite 的错误码已经把「怎么办」说清楚了，直接按码分，不去猜文案。
    private static func outcome(of connection: OpaquePointer?, code: Int32) -> Verdict {
        let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "没有错误信息"
        switch code {
        // 11 = 镜像坏了，26 = 这根本不是个库。
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corrupted(cause: "SQLite 报：\(message)")
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_PERM, SQLITE_AUTH, SQLITE_READONLY,
             SQLITE_NOMEM, SQLITE_FULL, SQLITE_CANTOPEN, SQLITE_IOERR:
            return .storageBlocked(cause: "SQLite 报：\(message)")
        default:
            return .storageBlocked(cause: "SQLite 报（错误码 \(code)）：\(message)")
        }
    }
}
