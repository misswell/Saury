import Foundation
import SwiftData
import os

/// 容器的唯一入口。运行时的 schema 只有 V4（当前版本），
/// 但迁移计划里声明过的旧 schema 必须一直留着，否则老库升不上来。
///
/// 当前版本里新加的那一列 `remindersEnabled` 不是迁移阶段：见
/// `ReminderIntentBackfill` 和 `Docs/DATA_MIGRATION.md` 里那次闪退的记录。
enum PersistenceController {
    private static let logger = Logger(subsystem: "com.guofeng.saury", category: "data")

    /// SwiftData 自带的 CloudKit 同步一律显式关掉。
    ///
    /// 默认值是 `.automatic`：将来谁在 Xcode 里给 target 勾上 iCloud 能力，
    /// SwiftData 会自己开始往库里写同步元数据，和 `SyncCoordinator` 这套自定义
    /// 同步**同时**写同一批订阅 —— 两条写入路径互相看不见对方，
    /// 结果就是同一条订阅被自己盖自己。任务书 §4.1 明令不许双重写入，
    /// 那就不能靠「现在还没勾」这种默认值，要写死。
    private static let cloudKit: ModelConfiguration.CloudKitDatabase = .none

    /// 只有从这几个旧版本跳上来才需要走声明好的迁移阶段。
    /// 版本号是 CoreData 写进库里的原话（`Z_METADATA.Z_PLIST`）。
    private static let versionsNeedingDeclaredStages: Set<String> = ["1.0.0", "2.0.0", "3.0.0"]

    /// - Parameter url: 只在验证迁移时用；正常运行交给 SwiftData 决定存放位置。
    static func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let configuration = url.map { ModelConfiguration(url: $0, cloudKitDatabase: cloudKit) }
            ?? ModelConfiguration(cloudKitDatabase: cloudKit)
        return try openContainer(url: url, configuration: configuration)
    }

    /// 按**库自己留下的证据**选开门的方式，两种各有非走不可的理由：
    ///
    /// - 库还停在 1/2/3 版：跨版本改造型（旧「物品」换成订阅、事件重新认领主人）
    ///   只有 `SauryMigrationPlan` 里那几段声明好的阶段做得了，必须带计划开。
    /// - 库已经在本机这一版（比如只是多了 `remindersEnabled` 一列）：**不能**带计划开。
    ///   这一列没法做成一条迁移阶段 —— `VersionedSchema.models` 只能列在用的类型，
    ///   新旧两版交得出同一份模型，`.custom(fromVersion:toVersion:)` 建 stage 时当场抛
    ///   「The current model reference and the next model reference cannot be equal」。
    ///   带计划的开法又不肯替这一列做轻量迁移（实测：装着这一列之前的库三种写法都报
    ///   `loadIssueModelContainer`，见 `Docs/DATA_MIGRATION.md`），于是只剩不带计划这一条：
    ///   CoreData 自己补得上这一列。
    /// - 判不清（版本章还没从 `-wal` 落进主文件、文件压根不是库）：**按带计划的老路走**。
    ///   这一条不是图省事，是两种错的代价不对等：拿不带计划去开一个老库，CoreData 会做
    ///   自动迁移，而旧实体在它眼里是要删掉的东西，实测能把用户的行洗成零（`Docs/DATA_MIGRATION.md`
    ///   里那条 `Persistent History … entities being removed`）。带计划开不出来最多是打不开，
    ///   文件还在原处，还有救。
    private static func openContainer(url: URL?, configuration: ModelConfiguration) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SaurySchemaV4.self)
        if opensWithDeclaredStages(for: schemaEvidence(forStoreAt: url)) {
            return try ModelContainer(for: schema,
                                      migrationPlan: SauryMigrationPlan.self,
                                      configurations: [configuration])
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// 判据单独拎出来是个纯函数，为的是测试能钉住它（见 `MigrationAndBackupTests`）：
    /// 这条判断只能出一种错，就是「把老库当成本机这一版」，而那种错的代价是用户的行被洗掉。
    /// 光测开库结果钉不住 —— CoreData 自己也会挑，撞对了不代表规则写对了。
    static func opensWithDeclaredStages(for evidence: StoreFileProbe.SchemaEvidence) -> Bool {
        switch evidence {
        case .absent, .legacyTables, .unreadable: return true
        case .stamped(let version): return versionsNeedingDeclaredStages.contains(version)
        case .currentTables: return false
        }
    }

    /// 给迁移用的库在哪个位置，就探哪个位置：显式给了 url 只认那一个，
    /// 否则在两个候选位置里找第一个真看得懂的文件（哪儿都没有库才是 `.absent`）。
    private static func schemaEvidence(forStoreAt url: URL?) -> StoreFileProbe.SchemaEvidence {
        if let url { return StoreFileProbe.schemaEvidence(at: url) }
        for candidate in candidateStoreLocations() {
            let evidence = StoreFileProbe.schemaEvidence(at: candidate)
            if evidence != .absent { return evidence }
        }
        return .absent
    }

    /// 测试与预览用：纯内存库。
    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: cloudKit)
        return try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV4.self),
            configurations: [configuration]
        )
    }

    /// 带自愈的入口。失败分四种，只有一种允许挪库重建（见 `StoreFailure`）：
    /// 认不准的原因一律不动用户的文件。
    /// 真的重建过一次，结果留在 `lastRecovery` 里 —— 界面上必须把这件事说出来。
    /// - Parameter url: 只在测试里给，正常运行交给 SwiftData 决定存放位置。
    static func makeContainerWithRecovery(url: URL? = nil) throws -> ModelContainer {
        let storeURLs = url.map { [$0] } ?? candidateStoreLocations()
        do {
            let made = try makeContainer(url: url)
            return made
        } catch {
            let failure = StoreFailure(error, storeURLs: storeURLs)
            logger.error("本地库打不开（\(failure.detail, privacy: .public)）")
            guard failure.canRebuildStore else {
                // 结构读不懂、权限、磁盘、认不出的原因：挪走旧库只会把
                // 「也许还能救」变成「肯定没了」。
                throw failure
            }
            let keptAside = quarantineStores(in: storeURLs)
            guard keptAside.isEmpty == false else {
                // 一个文件都没挪走：库根本不在我们认的那两个位置，或者压根不存在。
                // 这时候「文件坏了」这句话不能说 —— 判据只剩错误文本，可信度不够，
                // 改成如实交代「原因没认出来，没动过任何东西」。
                throw StoreFailure.other(failure.detail)
            }
            do {
                let made = try makeContainer(url: url)
                let note = StoreRecovery(reason: failure, keptAside: keptAside)
                lastRecovery = note
                persistRecovery(note)
                logger.info("旧库已留底并重建新库，留底 \(keptAside.count) 个文件")
                return made
            } catch {
                // 挪走旧库还是建不起来：这时候连新库都没有，更不能装作只是「恢复过了」。
                throw StoreOpenProblem(recovery: StoreRecovery(reason: failure, keptAside: keptAside),
                                       second: StoreFailure(error, storeURLs: storeURLs))
            }
        }
    }

    /// 最近一次「挪库重建」的留底。存在 UserDefaults 里，跨启动还在，
    /// 直到用户在数据页上说「我看过了」—— 见 `acknowledgeRecovery()`。
    private(set) static var lastRecovery: StoreRecovery? = storedRecovery()

    static let recoveryDefaultsKey = "saury.store.recovery"

    /// 磁盘上那份留底记录 —— 也就是「杀掉 App 再打开」之后还会剩下的东西。
    static func storedRecovery() -> StoreRecovery? {
        guard let data = UserDefaults.standard.data(forKey: recoveryDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(StoreRecovery.self, from: data)
    }

    private static func persistRecovery(_ note: StoreRecovery) {
        guard let data = try? JSONEncoder().encode(note) else { return }
        UserDefaults.standard.set(data, forKey: recoveryDefaultsKey)
    }

    /// 用户看过并认了这件事。留底的文件一个都不动，只是不再每次启动都拦一道横幅。
    static func acknowledgeRecovery() {
        lastRecovery = nil
        UserDefaults.standard.removeObject(forKey: recoveryDefaultsKey)
    }

    /// 连新库都建不起来、只能用内存库开起来时的原因。这时候库里每一条改动都会在
    /// 下次启动时消失，界面上必须一直写着，不能说一半。
    private(set) static var lastOpenFailure: StoreFailure?

    /// 启动入口：永远返回一个能用的容器，但把「这个容器是怎么来的」留在上面两个字段里。
    /// 闪退和静默的空库都不是选项 —— 先开起来，再把话说清楚。
    /// 回来的这一个同时记进 `liveContainer`：通知点击那条路上要用，两个出口都得记。
    /// - Parameter url: 只在测试里给，用来造出各种打不开的场景。
    static func makeContainerForLaunch(url: URL? = nil) -> ModelContainer {
        do {
            let made = try makeContainerWithRecovery(url: url)
            lastOpenFailure = nil
            liveContainer = made
            return made
        } catch {
            let problem = error as? StoreOpenProblem
            let reason = problem?.second
                ?? StoreFailure(error, storeURLs: url.map { [$0] } ?? candidateStoreLocations())
            logger.error("本地库没能开起来，先用内存库开起来：\(reason.detail, privacy: .public)")
            lastOpenFailure = reason
            guard let fallback = try? makeInMemoryContainer() else {
                fatalError("本地库和内存库都建不起来：\(reason.detail)")
            }
            liveContainer = fallback
            return fallback
        }
    }

    /// 首屏那条说明的正文。没有事的时候是 nil。
    static var launchNotice: String? {
        if let failure = lastOpenFailure {
            return "现在这个 App 跑在临时库上：这一趟里写的东西，下次打开就没了。"
                + "\(failure.userText)\(failure.advice)"
        }
        return lastRecovery?.message
    }

    /// 挪走旧库还是建不起来：两次失败都要说，只说第一次会误导。
    struct StoreOpenProblem: LocalizedError {
        let recovery: StoreRecovery
        let second: StoreFailure

        var errorDescription: String? {
            "\(recovery.message) 重建之后还是打不开：\(second.userText)"
        }
    }

    /// 默认库可能出现的两个位置：App 自己的 Application Support 和 App Group。
    static func candidateStoreLocations() -> [URL] {
        var urls: [URL] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(support.appendingPathComponent("default.store"))
        }
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.guofeng.saury") {
            urls.append(group.appendingPathComponent("Library/Application Support/default.store"))
        }
        return urls
    }

    /// 把一套 SQLite 三件套改名留底：default.store → default.store.quarantined-<时间戳>。
    /// 只改名、不删除：这是「危险操作前的快照」，用户的数据必须还在磁盘上。
    private static func quarantineStores(in urls: [URL]) -> [URL] {
        urls.flatMap { quarantineStore(at: $0) }
    }

    @discardableResult
    static func quarantineStore(at url: URL) -> [URL] {
        let manager = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        var moved: [URL] = []
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: fileURL.path) else { continue }
            let destination = URL(fileURLWithPath: fileURL.path + ".quarantined-\(stamp)-\(Int.random(in: 1000...9999))")
            guard (try? manager.moveItem(at: fileURL, to: destination)) != nil else { continue }
            moved.append(destination)
            logger.info("旧库已留底：\(destination.lastPathComponent, privacy: .public)")
        }
        return moved
    }

    /// 这一次运行真正在用那个容器，由 `makeContainerForLaunch` 记下来。
    ///
    /// UIKit 那一侧的入口（通知点击的回调）拿不到 SwiftUI 的环境，只能从这里要。
    /// 让它自己再开一个容器是不行的：同一个库开两个容器，两边看见的数据会打架。
    /// 内存兜底那一种也算「在用」—— 这时候通知动作照样能读能写，只是重启就没了，
    /// 首屏那条横幅已经把这件事说给用户听了。
    static private(set) var liveContainer: ModelContainer?

    /// 旧版本（V1）的容器。存在的唯一理由是让测试能造出一个「用户手机上的旧库」。
    static func makeLegacyContainer(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV1.self),
            configurations: [ModelConfiguration(url: url, cloudKitDatabase: cloudKit)]
        )
    }

    /// V2（上一版发布）的容器：验证「已经有数据的库 + 新表」这条升级路径。
    static func makeV2Container(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV2.self),
            configurations: [ModelConfiguration(url: url, cloudKitDatabase: cloudKit)]
        )
    }

    /// V3 的容器：验证「V3 库升级成订阅」这条路径。
    static func makeV3Container(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV3.self),
            configurations: [ModelConfiguration(url: url, cloudKitDatabase: cloudKit)]
        )
    }

    /// 不带迁移计划的 V4 容器：造一个「上一版发布留下来的库」给测试当现场用。
    /// `ReminderIntentBackfill` 的那条规则得有真库可跑，不能只靠说。
    static func makeV4Container(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV4.self),
            configurations: [ModelConfiguration(url: url, cloudKitDatabase: cloudKit)]
        )
    }
}
