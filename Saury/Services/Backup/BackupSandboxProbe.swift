#if DEBUG
import Foundation
import SwiftData
import UIKit

/// 备份在 App 自己的沙箱里跑一趟，并把每一步的实况写成 JSON 留在 Documents。
///
/// 单元测试跑的是内存库；这里用的是真库、真图标目录、真文件容器，
/// 证明的是「文件在磁盘上、恢复后库里真的有这些行」，不是 App 自己嘴上说成功。
/// 启动参数 `-saury-backup` 触发，只给验证用。
@MainActor
enum BackupSandboxProbe {
    struct Step: Codable {
        let name: String
        let detail: String
        var passed: Bool
    }

    struct Result: Codable {
        let ranAt: Date
        var steps: [Step]
        var report: String
        var backupFile: String
        var isPassed: Bool { steps.allSatisfy(\.passed) }
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("SauryBackupProbe", isDirectory: true)
    }

    static func run(context: ModelContext, preferences: SubPreferences) {
        var result = Result(ranAt: Date(), steps: [], report: "", backupFile: "")
        let icons = IconImageStore.shared
        let repository = SubscriptionRepository(context: context)
        let iconFileName = "probe-\(UUID().uuidString.prefix(8)).png"
        let subscriptionID = UUID()
        let eventID = UUID()

        func record(_ name: String, _ detail: String, _ passed: Bool = true) {
            result.steps.append(Step(name: name, detail: detail, passed: passed))
        }

        do {
            // 1. 先用 App 真正的写入口做一条带图片图标的订阅和一笔历史。
            let image = probeImage()
            guard let storedIcon = icons.store(image, named: iconFileName),
                  let iconBytes = icons.data(for: storedIcon) else {
                record("seed", "图标写不进本机目录，后面的对比没有意义", false)
                throw ProbeError("图标存不下来")
            }
            var draft = SubscriptionDraft(id: subscriptionID,
                                          name: "备份沙箱探针",
                                          priceMinorUnits: 4517,
                                          currencyCode: "USD",
                                          cycle: .monthly)
            draft.iconImageFile = storedIcon
            draft.notes = "只用于验证备份真的落盘"
            _ = try repository.apply(draft)
            try repository.record(SubscriptionEventDraft(id: eventID,
                                                         subscriptionID: subscriptionID,
                                                         type: .charged,
                                                         amountMinorUnits: 4517,
                                                         currencyCode: "USD"))
            record("seed", "订阅 \(subscriptionID.uuidString.prefix(8)) + 1 笔历史 + 图标 \(iconBytes.count) 字节")

            // 2. 打包，并把包写到磁盘上。
            let built = try BackupService.build(context: context, preferences: preferences, icons: icons)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(built.fileName)
            try built.data.write(to: fileURL, options: .atomic)
            result.backupFile = fileURL.path
            record("build", "\(built.summaryText)；包写在 \(fileURL.lastPathComponent)")

            // 3. 从磁盘重新读回来：内存里算过的那份不算数。
            let onDisk = try Data(contentsOf: fileURL)
            let manifest = try BackupContainer.readManifest(onDisk)
            let documentPlain = manifest.documentPart?.byteLength ?? 0
            record("read-back",
                   "磁盘字节与打包结果一致：\(onDisk == built.data)；文件头 \(hexPrefix(onDisk))；"
                       + "正文未压缩 \(documentPlain) 字节，整个包 \(onDisk.count) 字节",
                   onDisk == built.data && onDisk.count < documentPlain)

            // 4. 把图标和库都清掉：恢复之后它们必须自己长回来。
            icons.delete(iconFileName)
            let iconGone = icons.data(for: iconFileName) == nil
            try repository.wipeAll()
            let emptySubscriptions = (try? context.fetchCount(FetchDescriptor<Subscription>())) ?? -1
            let emptyEvents = (try? context.fetchCount(FetchDescriptor<SubscriptionEvent>())) ?? -1
            record("wipe", "图标已删：\(iconGone)；库里订阅 \(emptySubscriptions) 条、事件 \(emptyEvents) 条",
                   iconGone && emptySubscriptions == 0 && emptyEvents == 0)

            // 5. 用磁盘上那份包恢复。
            let report = try BackupService.restore(data: onDisk, into: context, preferences: preferences)
            result.report = report.summaryText

            let restored = repository.subscription(id: subscriptionID)
            let restoredEvent = repository.event(id: eventID)
            let iconBack = icons.data(for: iconFileName)
            // 库里恢复完该有的条数以清单为准：探针之外这台机器上还有别的行，
            // 那些也一样要跟着备份走，所以不能拿「1」去对。
            record("restore",
                   "新增 \(report.counts.subscriptionsInserted)、事件新增 \(report.counts.eventsInserted)、"
                       + "图标写回 \(report.iconsWritten) 张；校验干净：\(report.isClean)",
                   report.isClean
                       && report.counts.subscriptionsInserted == built.manifest.subscriptionCount
                       && report.counts.eventsInserted == built.manifest.eventCount
                       && report.iconsWritten == built.manifest.iconCount)
            record("row",
                   "金额 \(restored?.priceMinorUnits.description ?? "无")/4517、"
                       + "币种 \(restored?.currencyCode ?? "无")/USD、周期 \(restored?.cycleRawValue ?? "无")",
                   restored?.priceMinorUnits == 4517 && restored?.currencyCode == "USD"
                       && restored?.cycleRawValue == BillingCycle.monthly.rawValue)
            record("event",
                   "事件 \(eventID.uuidString.prefix(8)) 回到库里，指向 \(restoredEvent?.subscriptionID.uuidString.prefix(8) ?? "无")",
                   restoredEvent?.subscriptionID == subscriptionID)
            record("icon",
                   "图标字节和删掉之前一样：\(iconBack == iconBytes)（\(iconBack?.count ?? 0)/\(iconBytes.count)）",
                   iconBack == iconBytes)
        } catch {
            record("error", "探针中途失败：\(error.localizedDescription)", false)
        }

        let data = (try? JSONEncoder().encode(result)) ?? Data()
        let url = directory.appendingPathComponent("probe-result.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            NSLog("SauryBackupProbe 结果已写入 \(url.path)：通过=\(result.isPassed)")
        } catch {
            NSLog("SauryBackupProbe 结果写不出来：\(error.localizedDescription)")
        }
    }

    private static func probeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            UIColor.white.setFill()
            context.fill(CGRect(x: 24, y: 24, width: 48, height: 48))
        }
    }

    private static func hexPrefix(_ data: Data) -> String {
        data.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private struct ProbeError: Error {
        let text: String
        init(_ text: String) { self.text = text }
        var localizedDescription: String { text }
    }
}
#endif
