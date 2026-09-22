import Foundation
import os
import SwiftData

/// 写盘失败的出口。之前满项目都是 `try? context.save()`，出错时既不进日志
/// 也不进界面，等于把问题留给用户去猜（方案 §109 禁止静默吞异常）。
enum SauryLog {
    private static let logger = Logger(subsystem: "com.guofeng.saury", category: "data")
    private static let notifications = Logger(subsystem: "com.guofeng.saury", category: "notifications")

    static func saveFailed(_ operation: String, _ error: Error) {
        logger.error("\(operation, privacy: .public) 保存失败：\(error.localizedDescription, privacy: .public)")
    }

    /// 通知排不进去多半是没授权或超出系统容量，两者都必须能从日志里看出来。
    static func notificationFailed(_ operation: String, _ error: Error) {
        notifications.error("\(operation, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
    }
}

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
