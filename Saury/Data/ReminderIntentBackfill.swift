import Foundation
import os
import SwiftData

/// 老库里每一行「要不要提醒」的补算，跑在**真库打开之后**，不是一条 Schema 迁移阶段。
///
/// 为什么不写在迁移里：`VersionedSchema.models` 只能列活着的类型，所以「加这一列之前
/// 那一版」和当前版交得出同一份模型，SwiftData 建 custom stage 时当场抛
/// 「The current model reference and the next model reference cannot be equal」——
/// 老库设备一进 App 就闪退（这一条是装上老库实测撞出来的，见 `Docs/DATA_MIGRATION.md`）。
/// 补一列交给 CoreData 的自动轻量迁移，补一个**结论**只能自己来。
///
/// 规则只有一条，而且是对着**旧界面说的话**下的（任务书 §5.1「不得静默改变提醒规则」）：
/// - `reminderDays > 0` → 开；
/// - `reminderDays == 0` → 关。旧版新增页和详情页都把 0 天写成「不提醒」，
///   调度器却会在扣费当天排一条 —— 那是和说明相矛盾的 bug，不是用户的意图。
///
/// 天数一律原样留着：将来用户把开关打开时，他当初选的那一天还在。
enum ReminderIntentBackfill {
    private static let logger = Logger(subsystem: "com.guofeng.saury", category: "notifications")

    /// 这台设备跑过这趟没有。写时间戳而不是 true，方便日后查是哪一次启动补的。
    static let doneKey = "saury.reminderIntent.v5rows"

    /// 旧值 → 开关。备份恢复、云端载荷、这里三条路共用同一个说法，
    /// 同一份数据从哪条路进来都不许判出相反结果。
    static func intent(reminderDays: Int) -> Bool { reminderDays > 0 }

    /// 跑一次。返回改了几行；`nil` = 这台设备已经补过（一条都不动）或这趟没做完。
    ///
    /// 「没做完」包括读不出行和落盘失败：哨兵只在全程顺利时才写，
    /// 否则下次启动就没有任何理由再补第二遍，用户的提醒规则就永远停在错的那一半。
    @discardableResult
    static func runIfNeeded(container: ModelContainer,
                            defaults: UserDefaults = .standard) -> Int? {
        guard defaults.object(forKey: doneKey) == nil else { return nil }
        let context = ModelContext(container)
        guard let subscriptions = try? context.fetch(FetchDescriptor<Subscription>()) else {
            logger.error("提醒意图补算没跑成：读不出订阅行")
            return nil
        }
        var changed = 0
        for subscription in subscriptions where subscription.remindersEnabled != intent(reminderDays: subscription.reminderDays) {
            // 只动开关，不动 `updatedAt`：补算不是用户改动。盖了时间戳的话，
            // 升级完的那台设备会把库里每一行都当成「本机这份最新」整片推上云，
            // 把另一台设备刚改的东西盖掉。
            subscription.remindersEnabled = intent(reminderDays: subscription.reminderDays)
            changed += 1
        }
        do {
            try context.save()
        } catch {
            logger.error("提醒意图补算没落盘：\(String(error.localizedDescription.prefix(200)), privacy: .public)")
            return nil
        }
        defaults.set(Date().timeIntervalSince1970, forKey: doneKey)
        logger.info("提醒意图补算完成：\(changed) 条订阅按当初界面上的说法落成开关")
        return changed
    }
}
