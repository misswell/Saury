import Foundation
import os
import SwiftData

/// 写盘失败的出口。之前满项目都是 `try? context.save()`，出错时既不进日志
/// 也不进界面，等于把问题留给用户去猜（方案 §109 禁止静默吞异常）。
enum SauryLog {
    private static let logger = Logger(subsystem: "com.guofeng.saury", category: "data")
    private static let notifications = Logger(subsystem: "com.guofeng.saury", category: "notifications")
    private static let preferences = Logger(subsystem: "com.guofeng.saury", category: "preferences")

    static func saveFailed(_ operation: String, _ error: Error) {
        logger.error("\(operation, privacy: .public) 保存失败：\(error.localizedDescription, privacy: .public)")
    }

    /// 偏好写盘失败：这一条如果静默过去，界面会显示一个磁盘上并不存在的设置。
    static func preferencesFailed(_ operation: String, _ detail: String) {
        preferences.error("\(operation, privacy: .public) 没写进去：\(detail, privacy: .public)")
    }

    /// 通知排不进去多半是没授权或超出系统容量，两者都必须能从日志里看出来。
    static func notificationFailed(_ operation: String, _ error: Error) {
        notifications.error("\(operation, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
    }

    /// 主动放弃或挤掉的那一类：不是错误，但用户以为排上了，日志里得留一句。
    static func notificationSkipped(_ detail: String) {
        notifications.warning("\(detail, privacy: .public)")
    }

    /// 每一趟重排的结果都要留一行。只记错误的话，「提醒没响」这种问题在日志里
    /// 会显示成一片空白 —— 分不清是没排、排了被拒，还是排好了没到点。
    static func notificationScheduled(_ detail: String) {
        notifications.log("\(detail, privacy: .public)")
    }}

extension ModelContext {
    /// 保存，失败时至少留下可查的痕迹。SwiftData 稍后还会自动重试，
    /// 所以调用方不需要为此中断流程。
    func saveOrLog(_ operation: String) {
        do {
            try save()
        } catch {
            SauryLog.saveFailed(operation, error)
        }
    }
}
