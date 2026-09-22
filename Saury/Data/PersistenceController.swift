import Foundation
import SwiftData

/// 容器的唯一入口。运行时的 schema 只有 V3（当前版本），
/// 但迁移计划里声明过的旧 schema 必须一直留着，否则老库升不上来。
enum PersistenceController {
    /// - Parameter url: 只在验证迁移时用；正常运行交给 SwiftData 决定存放位置。
    static func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let configuration = url.map { ModelConfiguration(url: $0) } ?? ModelConfiguration()
        return try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV3.self),
            migrationPlan: SauryMigrationPlan.self,
            configurations: [configuration]
        )
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
}
