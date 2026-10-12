import Foundation
import CloudKit
import SwiftData
import UIKit
import os

enum CloudSyncError: LocalizedError {
    case cloudUnavailable

    var errorDescription: String? { "这台 App 没有配置 iCloud 能力" }
}

/// iCloud 同步引擎（方案：与「iCloud 与数据」页配套）。
///
/// 做法：把每条订阅打成一条 CKRecord（payload = 导出 JSON，图标 = PNG data）
/// 存进私有库，同步时「拉取合并 + 推送更新」，以 updatedAt 为准；
/// 本机删除过且已同步过的记录会把远端一起删掉。
///
/// 容器用 CKContainer.default()（即 iCloud.<bundleID>）。App 没配 iCloud
/// 权限或没登录账户时，所有请求都会以错误结束 —— 引擎把这些错误吃掉，
/// 状态显示成「不可用」，绝不影响 App 启动。
@MainActor
final class CloudSyncEngine: ObservableObject {
    static let shared = CloudSyncEngine()

    private static let logger = Logger(subsystem: "com.guofeng.saury", category: "cloud")
    private static let recordType = "Subscription"
    private static let autoSyncKey = "saury.cloudAutoSync"
    private static let lastSyncKey = "saury.cloudLastSync"
    private static let syncedIDsKey = "saury.cloudSyncedIDs"

    @Published private(set) var accountStatus: CKAccountStatus?
    @Published private(set) var lastSync: Date?
    /// 最近一次拉取看到的云端订阅数。
    @Published private(set) var remoteCount: Int?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastMessage: String?

    /// CloudKit 必须在编译期确认有 iCloud 能力才能碰：
    /// CKContainer.default() 在没有权限时于 dispatch_once 里抛异常，任何
    /// @try 都接不住。所以由 `SAURY_ICLOUD` 编译条件决定 —— 在 Xcode 里给
    /// 目标加上 iCloud 能力（容器 iCloud.com.guofeng.saury）并把这个条件
    /// 加进 SWIFT_ACTIVE_COMPILATION_CONDITIONS 之后，同步才会真正启用。
    static var cloudKitCompiledIn: Bool {
        #if SAURY_ICLOUD
        return true
        #else
        return false
        #endif
    }

    private var container: CKContainer? {
        guard Self.cloudKitCompiledIn else { return nil }
        if let cached = containerCache { return cached }
        let resolved = CKContainer.default()
        containerCache = resolved
        return resolved
    }

    private var containerCache: CKContainer?

    private var database: CKDatabase? { container?.privateCloudDatabase }

    private init() {
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    var autoSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoSyncKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoSyncKey)
            if newValue {
                Task { await syncNow() }
            }
        }
    }

    // MARK: - 账户

    func refreshAccountStatus() async {
        guard Self.cloudKitCompiledIn else {
            accountStatus = .couldNotDetermine
            return
        }
        do {
            accountStatus = try await container?.accountStatus()
        } catch {
            Self.logger.error("读取 iCloud 账户状态失败：\(error.localizedDescription, privacy: .public)")
            accountStatus = .couldNotDetermine
        }
    }

    var accountTitle: String {
        switch accountStatus {
        case .available: return "可用"
        case .noAccount, .restricted, .couldNotDetermine: return "不可用"
        case .temporarilyUnavailable: return "暂时不可用"
        default: return "不可用"
        }
    }

    var isAccountAvailable: Bool { accountStatus == .available }

    // MARK: - 同步

    /// 拉取合并 + 推送更新。所有失败都静默降级，只留下日志和页脚消息。
    func syncNow(context: ModelContext? = nil) async {
        guard !isSyncing else { return }
        if !isAccountAvailable {
            await refreshAccountStatus()
        }
        guard isAccountAvailable else {
            lastMessage = "iCloud 账户不可用"
            return
        }
        guard Self.cloudKitCompiledIn, database != nil else {
            lastMessage = "未配置 iCloud 能力"
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let remote = try await fetchRemoteRecords()
            remoteCount = remote.count

            if let context {
                let incoming = try await merge(remote: remote, into: context)
                let pushed = try await push(local: incoming.locals, context: context)
                _ = pushed
                try context.save()
            }
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: Self.lastSyncKey)
            lastMessage = "已同步到 iCloud"
            if context != nil {
                NotificationCenter.default.post(name: .sauryDataChanged, object: nil)
            }
        } catch {
            Self.logger.error("iCloud 同步失败：\(error.localizedDescription, privacy: .public)")
            lastMessage = "同步失败：\(error.localizedDescription)"
        }
    }

    /// 以本机为准：每一条都打上最新标记整包推上去，远端同名记录被覆盖。
    /// 其他设备上多出来的记录不受影响，不会删任何数据。
    func pushLocalAsSource(context: ModelContext) async {
        guard !isSyncing else {
            lastMessage = "上一次同步还在进行"
            return
        }
        guard Self.cloudKitCompiledIn, database != nil else {
            lastMessage = "未配置 iCloud 能力"
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
            var records: [CKRecord] = []
            for subscription in subscriptions where subscription.deletedAt == nil {
                records.append(Self.record(for: subscription))
            }
            try await save(records: records)
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: Self.lastSyncKey)
            remoteCount = records.count
            lastMessage = "已以本机数据为准上传"
        } catch {
            Self.logger.error("以本机为准上传失败：\(error.localizedDescription, privacy: .public)")
            lastMessage = "上传失败：\(error.localizedDescription)"
        }
    }

    /// 图标修复：本地丢了图（换机、清缓存）就从远端把 PNG 拉回来。
    func repairIcons(context: ModelContext) async {
        guard Self.cloudKitCompiledIn, database != nil else {
            lastMessage = "未配置 iCloud 能力"
            return
        }
        guard isAccountAvailable else {
            lastMessage = "iCloud 账户不可用"
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remote = try await fetchRemoteRecords()
            var repaired = 0
            for (recordID, payload, iconData, _) in remote {
                guard let payload else { continue }
                let id = Self.id(fromRecordName: recordID)
                let all = try context.fetch(FetchDescriptor<Subscription>())
                guard let local = all.first(where: { $0.id == id }) else { continue }
                if let file = local.iconImageFile,
                   IconImageStore.shared.image(for: file) == nil,
                   let iconData,
                   let image = UIImage(data: iconData),
                   let restored = IconImageStore.shared.store(image, id: id) {
                    local.iconImageFile = restored
                    local.markUpdated()
                    repaired += 1
                    _ = payload
                }
            }
            try context.save()
            lastMessage = repaired > 0 ? "已修复 \(repaired) 个图标" : "图标完好，无需修复"
        } catch {
            lastMessage = "修复失败：\(error.localizedDescription)"
        }
    }

    private func requireDatabase() throws -> CKDatabase {
        guard let database else {
            throw CloudSyncError.cloudUnavailable
        }
        return database
    }

    // MARK: - 远端读写

    private func fetchRemoteRecords() async throws -> [(recordID: String, payload: SubscriptionImportExport.ExportedSubscription?, iconData: Data?, updatedAt: Date)] {
        var results: [(String, SubscriptionImportExport.ExportedSubscription?, Data?, Date)] = []
        var cursor: CKQueryOperation.Cursor?
        let database = try requireDatabase()

        repeat {
            let page = try await fetchPage(cursor: cursor, database: database)
            for record in page.records {
                let unpacked = Self.unpack(record)
                let stamp = (record["updatedAt"] as? Date) ?? unpacked.payload?.createdAt ?? .distantPast
                results.append((unpacked.recordID, unpacked.payload, unpacked.iconData, stamp))
            }
            cursor = page.nextCursor
        } while cursor != nil
        return results
    }

    private struct QueryPage {
        let records: [CKRecord]
        let nextCursor: CKQueryOperation.Cursor?
    }

    private func fetchPage(cursor: CKQueryOperation.Cursor?, database: CKDatabase) async throws -> QueryPage {
        try await withCheckedThrowingContinuation { continuation in
            let operation: CKQueryOperation
            if let cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
                operation = CKQueryOperation(query: query)
            }
            operation.resultsLimit = 200
            operation.desiredKeys = ["updatedAt", "payload", "icon"]
            var fetched: [CKRecord] = []
            operation.recordFetchedBlock = { record in
                fetched.append(record)
            }
            operation.queryCompletionBlock = { nextCursor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: QueryPage(records: fetched, nextCursor: nextCursor))
                }
            }
            database.add(operation)
        }
    }

    /// 拉取合并：远端新的覆盖本机；本机删过且已同步的，连远端一起删。
    /// 返回值得推送的本机列表。
    private func merge(remote: [(recordID: String, payload: SubscriptionImportExport.ExportedSubscription?, iconData: Data?, updatedAt: Date)], into context: ModelContext) async throws -> (locals: [Subscription], pushed: Int) {
        let locals = try context.fetch(FetchDescriptor<Subscription>())
        let syncedIDs = Self.syncedIDs()

        // 远端 → 本机
        for (recordID, payload, iconData, remoteStamp) in remote {
            guard let payload else { continue }
            let id = Self.id(fromRecordName: recordID)
            if let local = locals.first(where: { $0.id == id }) {
                if remoteStamp > local.updatedAt {
                    Self.apply(payload: payload, iconData: iconData, stamp: remoteStamp, to: local)
                }
            } else {
                let incoming = Subscription(name: payload.name)
                incoming.id = id
                Self.apply(payload: payload, iconData: iconData, stamp: remoteStamp, to: incoming)
                context.insert(incoming)
            }
        }

        // 本机删除 → 远端删除
        let deletedLocally = locals.filter { $0.deletedAt != nil && syncedIDs.contains($0.id) }
        if !deletedLocally.isEmpty {
            let ids = deletedLocally.map { CKRecord.ID(recordName: Self.recordName(for: $0.id)) }
            _ = try? await requireDatabase().modifyRecords(saving: [], deleting: ids)
            var updated = syncedIDs
            for subscription in deletedLocally { updated.remove(subscription.id) }
            Self.saveSyncedIDs(updated)
        }

        // 待推送：本机比远端新，或从没同步过。
        let remoteStamps = Dictionary(uniqueKeysWithValues: remote.map { (Self.id(fromRecordName: $0.recordID), $0.updatedAt) })
        let toPush = locals.filter { subscription in
            guard subscription.deletedAt == nil else { return false }
            guard let remoteStamp = remoteStamps[subscription.id] else { return true }
            return subscription.updatedAt > remoteStamp
        }
        return (toPush, toPush.count)
    }

    private func push(local: [Subscription], context: ModelContext) async throws {
        guard !local.isEmpty else { return }
        let records = local.map(Self.record(for:))
        try await save(records: records)
        var synced = Self.syncedIDs()
        for subscription in local { synced.insert(subscription.id) }
        Self.saveSyncedIDs(synced)
    }

    private func save(records: [CKRecord]) async throws {
        let database = try requireDatabase()
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0 + 200, records.count)]) }) {
            _ = try await database.modifyRecords(saving: chunk, deleting: [], savePolicy: .changedKeys)
        }
    }

    // MARK: - 编解码

    static func recordName(for id: UUID) -> String { "sub-" + id.uuidString }

    static func id(fromRecordName name: String) -> UUID {
        UUID(uuidString: String(name.dropFirst(4))) ?? UUID()
    }

    static func record(for subscription: Subscription) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: recordName(for: subscription.id)))
        record["updatedAt"] = subscription.updatedAt as NSDate
        record["name"] = subscription.name
        record["payload"] = try? JSONEncoder.iso8601.encode(SubscriptionImportExport.exportedSubscription(subscription))
        if let file = subscription.iconImageFile, let image = IconImageStore.shared.image(for: file) {
            record["icon"] = image.pngData()
        }
        return record
    }

    static func unpack(_ record: CKRecord) -> (recordID: String, payload: SubscriptionImportExport.ExportedSubscription?, iconData: Data?) {
        let payload = (record["payload"] as? Data)
            .flatMap { try? JSONDecoder.iso8601.decode(SubscriptionImportExport.ExportedSubscription.self, from: $0) }
        let icon = record["icon"] as? Data
        return (record.recordID.recordName, payload, icon)
    }

    /// 远端 payload 覆盖本机字段。stamp = 远端的 updatedAt：
    /// 应用完必须把本机时间戳对齐到远端，否则下一轮同步会把这个订阅白推一遍。
    static func apply(payload: SubscriptionImportExport.ExportedSubscription, iconData: Data?, stamp: Date, to subscription: Subscription) {
        subscription.name = payload.name
        subscription.plan = payload.plan
        subscription.iconSymbolName = payload.iconSymbolName
        subscription.iconColorHex = payload.iconColorHex
        subscription.colorSpec = CardColorSpec(hexes: payload.colorHexes)
        subscription.priceMinorUnits = payload.priceMinorUnits
        subscription.currencyCode = payload.currencyCode
        subscription.cycleRawValue = payload.cycle
        subscription.customMonths = payload.customMonths
        subscription.categoryRawValue = payload.category
        subscription.stateRawValue = payload.state
        subscription.startDate = payload.startDate
        subscription.endDate = payload.endDate
        subscription.reminderDays = payload.reminderDays
        subscription.shareEnabled = payload.shareEnabled
        subscription.shareHeadcount = payload.shareHeadcount
        subscription.shareModeRawValue = payload.shareMode
        subscription.shareMyMinorUnits = payload.shareMyMinorUnits
        subscription.paymentMethod = payload.paymentMethod
        subscription.notes = payload.notes
        subscription.archivedAt = nil
        subscription.deletedAt = nil
        if let iconData, let image = UIImage(data: iconData) {
            subscription.iconImageFile = IconImageStore.shared.store(image, id: subscription.id)
        } else {
            subscription.iconImageFile = payload.iconImageFile
        }
        subscription.updatedAt = stamp
    }

    // MARK: - 已同步 id 集合

    private static func syncedIDs() -> Set<UUID> {
        guard let raw = UserDefaults.standard.stringArray(forKey: syncedIDsKey) else { return [] }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private static func saveSyncedIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: syncedIDsKey)
    }
}

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
