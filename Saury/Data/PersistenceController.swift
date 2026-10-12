import Foundation
import SwiftData
import os

/// 容器的唯一入口。运行时的 schema 只有 V4（当前版本），
/// 但迁移计划里声明过的旧 schema 必须一直留着，否则老库升不上来。
enum PersistenceController {
    private static let logger = Logger(subsystem: "com.guofeng.saury", category: "data")

    /// - Parameter url: 只在验证迁移时用；正常运行交给 SwiftData 决定存放位置。
    static func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let configuration = url.map { ModelConfiguration(url: $0) } ?? ModelConfiguration()
        return try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV4.self),
            migrationPlan: SauryMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// 测试与预览用：纯内存库。
    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV4.self),
            configurations: [configuration]
        )
    }

    /// 带自愈的入口：迁移失败（例如本机留着一个认不出的老库）时，
    /// 把旧库挪到一边换新库重试一次，绝不让 App 卡死在启动页。
    /// 挪走的文件保留在原地，需要的时候还能手工找回。
    static func makeContainerWithRecovery() throws -> ModelContainer {
        do {
            return try makeContainer()
        } catch {
            logger.error("本地库打不开（\(error.localizedDescription, privacy: .public)），尝试移走旧库重建")
            for url in candidateStoreLocations() {
                quarantineStore(at: url)
            }
            return try makeContainer()
        }
    }

    /// 默认库可能出现的两个位置：App 自己的 Application Support 和 App Group。
    private static func candidateStoreLocations() -> [URL] {
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
    private static func quarantineStore(at url: URL) {
        let manager = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: fileURL.path) else { continue }
            let destination = URL(fileURLWithPath: fileURL.path + ".quarantined-\(stamp)")
            try? manager.moveItem(at: fileURL, to: destination)
            logger.info("旧库已留底：\(destination.lastPathComponent, privacy: .public)")
        }
    }

    /// 旧版本（V1）的容器。存在的唯一理由是让测试能造出一个「用户手机上的旧库」。
    static func makeLegacyContainer(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV1.self),
            configurations: [ModelConfiguration(url: url)]
        )
    }

    /// V2（上一版发布）的容器：验证「已经有数据的库 + 新表」这条升级路径。
    static func makeV2Container(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV2.self),
            configurations: [ModelConfiguration(url: url)]
        )
    }

    /// V3 的容器：验证「V3 库升级成订阅」这条路径。
    static func makeV3Container(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV3.self),
            configurations: [ModelConfiguration(url: url)]
        )
    }
}
