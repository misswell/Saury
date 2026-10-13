import Foundation
import CloudKit

/// `CloudRecordStore` 的 CloudKit 实现。私有库、单容器，不做共享库。
///
/// 这个类里的每一行都只有在签名给了 iCloud 能力之后才会被执行到 ——
/// 调用方必须先过 `CloudAccess.current`。本机的描述文件没有这个能力，
/// 所以这一份属于「已编码、未经运行验证」，写清楚在 `Docs/CLOUD_SYNC.md` 里。
final class CloudKitRecordStore: CloudRecordStore {
    /// 图标超过这个大小改用 CKAsset 存。CloudKit 对单个字段值有 1 MB 上限、
    /// 整条记录 1.5 MB；512 边长的 PNG 正常几十 KB，但纯色大图能顶到几百 KB，
    /// 再加上 payload 就危险了。小图留在字段里是为了省一次资产下载。
    static let inlineIconLimit = 100_000

    /// 清单要的字段。**不含图标**：desiredKeys 里没有它，资产就不会被下载。
    private static let indexKeys = ["updatedAt", "deletedAt", "payload", "iconChecksum"]
    private static let detailKeys = CloudKitRecordStore.indexKeys + ["icon", "iconAsset"]

    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }

    /// identifier 来自签名，不是这里写死的字符串。
    init(containerIdentifier: String) {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    // MARK: - 清单与详情

    func index(of kind: CloudRecordKind) async throws -> [CloudRecord] {
        var collected: [CloudRecord] = []
        var cursor: CKQueryOperation.Cursor?
        var query: CKQuery? = CKQuery(recordType: kind.cloudKitType, predicate: NSPredicate(value: true))
        repeat {
            // 一页一页地读：CloudKit 单次最多 `maximumResults` 条，多的部分靠游标接着要。
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
                       queryCursor: CKQueryOperation.Cursor?)
            if let cursor {
                page = try await database.records(continuingMatchFrom: cursor,
                                                  desiredKeys: Self.indexKeys,
                                                  resultsLimit: CKQueryOperation.maximumResults)
            } else if let query {
                page = try await database.records(matching: query,
                                                  desiredKeys: Self.indexKeys,
                                                  resultsLimit: CKQueryOperation.maximumResults)
            } else {
                break
            }
            query = nil
            // 单条读失败不能当成「云端没有这一条」：清单少一条，下一轮就会把那条
            // 判成「本机独有」重新上传，或者该收下的没收下。所以直接报出去。
            var firstFailure: Error?
            for (_, result) in page.matchResults {
                switch result {
                case .success(let record): collected.append(Self.unpack(record, kind: kind))
                case .failure(let error): if firstFailure == nil { firstFailure = error }
                }
            }
            if let firstFailure {
                throw CloudStoreError.requestFailed(cloudKitReason(firstFailure))
            }
            cursor = page.queryCursor
        } while cursor != nil
        return collected
    }

    func records(of kind: CloudRecordKind, names: [String]) async throws -> [CloudRecord] {
        guard names.isEmpty == false else { return [] }
        let ids = names.map(CKRecord.ID.init(recordName:))
        let fetched = try await database.records(for: ids, desiredKeys: Self.detailKeys)
        // 云端没有这一条时 CK 不报错，只是不返回；单条读失败也一样按「没有」处理。
        // 少了就是少了：调用方拿返回的条数和请求的条数比，图标补没补上、差几条都会说出来。
        return names.compactMap { name -> CloudRecord? in
            guard case .success(let record)? = fetched[CKRecord.ID(recordName: name)] else { return nil }
            return Self.unpack(record, kind: kind)
        }
    }

    // MARK: - 写入与删除

    /// 按 record type 分开存：`unpack` 要把服务端回来的记录还原成对应种类的形状，
    /// 一批里混着四种类型就只能反过来猜。
    /// 一批是一个原子事务：其中一条没存进去，整批报错、一条都不算成功 ——
    /// 任务书 §4.3「批量失败可安全重试」要的就是这个（重推同样的名字和同样的内容，结果一样）。
    @discardableResult
    func save(_ records: [CloudRecord]) async throws -> [CloudRecord] {
        guard records.isEmpty == false else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saury-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 资产文件要在 modifyRecords 回来之后才清：CKAsset 是按需读盘的。
        defer { try? FileManager.default.removeItem(at: directory) }

        var saved: [CloudRecord] = []
        for kind in CloudRecordKind.allCases {
            let group = records.filter { $0.kind == kind }
            guard group.isEmpty == false else { continue }
            for chunk in Self.chunks(group, size: 200) {
                let ckRecords = try chunk.map { try pack($0, assetDirectory: directory) }
                let result = try await database.modifyRecords(saving: ckRecords, deleting: [],
                                                              savePolicy: .changedKeys)
                for (_, savedResult) in result.saveResults {
                    if case .success(let record) = savedResult {
                        saved.append(Self.unpack(record, kind: kind))
                    }
                }
            }
        }
        return saved
    }

    @discardableResult
    func delete(_ kind: CloudRecordKind, names: [String]) async throws -> [String] {
        guard names.isEmpty == false else { return [] }
        var deleted: [String] = []
        for chunk in Self.chunks(names.map(CKRecord.ID.init(recordName:)), size: 200) {
            // .allKeys：手上没有这些记录的服务端变更标记，按默认策略删会撞
            // serverRecordChanged —— 那句话是「别人改过所以不删」，
            // 而这里的语义是「不管别人怎么想，这条要清掉」。
            let result = try await database.modifyRecords(saving: [], deleting: chunk, savePolicy: .allKeys)
            for (id, deleteResult) in result.deleteResults {
                if case .success = deleteResult { deleted.append(id.recordName) }
            }
        }
        return deleted
    }

    // MARK: - 账户

    func accountStatus() async throws -> CloudAccountStatus {
        do {
            return CloudAccountStatus(try await container.accountStatus())
        } catch {
            throw CloudStoreError.requestFailed(cloudKitReason(error))
        }
    }

    // MARK: - CKRecord ↔ CloudRecord

    private func pack(_ record: CloudRecord, assetDirectory: URL) throws -> CKRecord {
        let ck = CKRecord(recordType: record.kind.cloudKitType, recordID: CKRecord.ID(recordName: record.name))
        ck["updatedAt"] = record.updatedAt as NSDate
        if let deletedAt = record.deletedAt { ck["deletedAt"] = deletedAt as NSDate }
        ck["payload"] = record.payload as NSData
        if let icon = record.icon {
            ck["iconChecksum"] = CloudRecord.iconChecksum(of: icon) as NSString
            if icon.count > Self.inlineIconLimit {
                let url = assetDirectory.appendingPathComponent("\(record.name)-icon.bin")
                try icon.write(to: url, options: .atomic)
                ck["iconAsset"] = CKAsset(fileURL: url)
            } else {
                ck["icon"] = icon as NSData
            }
        } else if let checksum = record.iconChecksum {
            // 没有字节也要把校验和带上：清单比对靠它决定「本机这张图要不要重传」。
            ck["iconChecksum"] = checksum as NSString
        }
        return ck
    }

    private static func unpack(_ ck: CKRecord, kind: CloudRecordKind) -> CloudRecord {
        let iconData = (ck["icon"] as? Data)
            ?? ((ck["iconAsset"] as? CKAsset)?.fileURL).flatMap { try? Data(contentsOf: $0) }
        return CloudRecord(kind: kind,
                           name: ck.recordID.recordName,
                           updatedAt: (ck["updatedAt"] as? Date) ?? .distantPast,
                           deletedAt: ck["deletedAt"] as? Date,
                           payload: ck["payload"] as? Data ?? Data(),
                           icon: iconData,
                           iconChecksum: ck["iconChecksum"] as? String)
    }

    private static func chunks<T>(_ items: [T], size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }

    /// CloudKit 的错误码翻成人话。界面上只会出现这一套句子，不会把 CKError 原样端给用户；
    /// 但每一种都指向一个用户真能去做的动作，不是「未知错误，稍后再试」。
    private func cloudKitReason(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .networkUnavailable, .networkFailure: return "网络不通"
        case .notAuthenticated, .accountTemporarilyUnavailable, .permissionFailure, .managedAccountRestricted:
            return "iCloud 账户不可用或没有写入权限（受限账户、未登录、暂时不可用）"
        case .quotaExceeded, .limitExceeded: return "iCloud 空间已满或超出用量额度"
        case .serverRecordChanged: return "云端这一条刚被别的设备改过"
        case .zoneNotFound, .missingEntitlement, .badContainer, .badDatabase:
            // 这一句基本只会出现在「容器建了、Schema 没部署」的时候。
            return "云端容器或表还没建好：到 iCloud 控制台把四个 record type 部署到当前环境"
        case .partialFailure, .batchRequestFailed:
            // 一批里有一条没成：整批按失败处理，本机数据没动，下一趟原样重试。
            return "这一批没有整体存进云端，本机数据没动，下次同步会原样重推"
        default: return ck.localizedDescription
        }
    }
}

/// 我们自己的账户状态。`CKAccountStatus` 是 CloudKit 的类型，不该出现在测试里。
enum CloudAccountStatus: Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unknown

    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .unknown
        @unknown default: self = .unknown
        }
    }

    var isAvailable: Bool { self == .available }

    var title: String {
        switch self {
        case .available: return "可用"
        case .noAccount: return "这台设备没有登录 iCloud 账户"
        case .restricted: return "账户受限（可能是儿童账户）"
        case .temporarilyUnavailable: return "暂时不可用"
        case .unknown: return "认不出来"
        }
    }
}
