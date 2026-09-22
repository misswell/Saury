import XCTest
import SwiftData
@testable import Saury

/// 迁移是唯一不允许「差不多就行」的地方：老库里是用户真实记下的订阅，
/// 字段映射错了不会崩溃，只会静默变成另一条数据。
final class MigrationTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 字段映射（方案 §11）

    func testRenewalFieldsLandOnTheirExpiryCounterparts() {
        let item = RenewalItem(
            name: "视频会员",
            amountMinorUnits: 2500,
            currencyCode: "USD",
            nextRenewalDate: referenceDate,
            cycleRawValue: "customMonths",
            intervalMonths: 3,
            statusRawValue: "active",
            isAutoRenewing: true,
            cancelByDate: referenceDate,
            reminderOffsets: [3 * 24 * 60, 0],
            managementURLString: "https://example.com/manage",
            notes: "和家人共用"
        )
        let migrated = ExpiryItem(migratedFrom: LegacyRenewalSnapshot(item))

        XCTAssertEqual(migrated.id, item.id)
        XCTAssertEqual(migrated.name, "视频会员")
        XCTAssertEqual(migrated.expiryDate, referenceDate)
        XCTAssertEqual(migrated.priceMinorUnits, 2500)
        XCTAssertEqual(migrated.currencyCode, "USD")
        XCTAssertEqual(migrated.category, .subscription, "旧订阅全部归入订阅分类")
        XCTAssertEqual(migrated.recurrence, .custom)
        XCTAssertEqual(migrated.recurrenceInterval, 3)
        XCTAssertEqual(migrated.anchorDay, item.anchorDay, "旧库里的锚点日决定续费落在哪天，必须原样带过来")
        XCTAssertEqual(migrated.actionDeadline, referenceDate)
        XCTAssertEqual(migrated.sourceURL, "https://example.com/manage")
        XCTAssertEqual(migrated.reminderOffsets, [3 * 24 * 60, 0], "提醒计划原样保留")
        XCTAssertEqual(migrated.notes, "和家人共用")
        XCTAssertEqual(migrated.createdAt, item.createdAt)
        XCTAssertEqual(migrated.updatedAt, item.updatedAt)
    }

    func testEveryLegacyCycleMapsToADocumentedRecurrence() {
        func recurrence(_ cycle: String, autoRenewing: Bool = true, intervalMonths: Int = 1) -> ExpiryRecurrence {
            let item = RenewalItem(
                name: "x",
                nextRenewalDate: referenceDate,
                cycleRawValue: cycle,
                intervalMonths: intervalMonths,
                isAutoRenewing: autoRenewing
            )
            return SauryMigrationPlan.recurrence(for: LegacyRenewalSnapshot(item)).rule
        }

        XCTAssertEqual(recurrence("monthly"), .monthly)
        XCTAssertEqual(recurrence("yearly"), .yearly)
        XCTAssertEqual(recurrence("customMonths", intervalMonths: 6), .custom)
        XCTAssertEqual(recurrence("oneTime"), .none)
        XCTAssertEqual(recurrence("freeTrial"), .monthly, "试用到期后仍会推进，和旧行为一致")
        XCTAssertEqual(recurrence("nonsense"), .monthly, "读不懂的旧值退回每月，而不是变成不重复")
        XCTAssertEqual(recurrence("monthly", autoRenewing: false), .none, "自动续费关掉等于不再重复")
    }

    func testLegacyStatusMapsToUserStateAndNeverStoresExpired() {
        func state(_ status: String) -> ExpiryState {
            SauryMigrationPlan.state(for: LegacyRenewalSnapshot(RenewalItem(name: "x", nextRenewalDate: referenceDate, statusRawValue: status)))
        }
        XCTAssertEqual(state("active"), .active)
        XCTAssertEqual(state("paused"), .archived)
        XCTAssertEqual(state("cancelled"), .cancelled)
        XCTAssertEqual(state("expired"), .active, "过期由天数实时判定，不能当作用户状态存下来")
        XCTAssertEqual(state("nonsense"), .active)
    }

    func testLegacyDecisionsBecomeEvents() {
        func eventType(_ action: String) -> ExpiryEventType {
            SauryMigrationPlan.eventType(for: LegacyDecisionSnapshot(DecisionRecord(renewalItemID: UUID(), itemName: "x", actionRawValue: action)))
        }
        XCTAssertEqual(eventType("cancelled"), .cancelled)
        XCTAssertEqual(eventType("continued"), .renewed)
        XCTAssertEqual(eventType("paused"), .archived)
        XCTAssertEqual(eventType("snoozed"), .snoozed)
        XCTAssertEqual(eventType("nonsense"), .snoozed)
    }

    func testZeroAmountBecomesNoPriceRatherThanFree() {
        let paid = ExpiryItem(migratedFrom: LegacyRenewalSnapshot(RenewalItem(name: "付费", amountMinorUnits: 1900, nextRenewalDate: referenceDate)))
        let free = ExpiryItem(migratedFrom: LegacyRenewalSnapshot(RenewalItem(name: "未知", amountMinorUnits: 0, nextRenewalDate: referenceDate)))
        XCTAssertEqual(paid.priceMinorUnits, 1900)
        XCTAssertNil(free.priceMinorUnits)
        XCTAssertFalse(free.hasPrice, "旧数据里的 0 是「没填」，不能显示成 ¥0.00")
    }

    // MARK: - 真实库迁移

    @MainActor
    func testDataSurvivesOpeningTheNewSchema() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saury-migration-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = RenewalItem(
            name: "云储存 200GB",
            amountMinorUnits: 2100,
            nextRenewalDate: referenceDate,
            cycleRawValue: "yearly",
            reminderOffsets: [7 * 24 * 60, 0]
        )
        let cancelled = RenewalItem(name: "旧会员", amountMinorUnits: 900, nextRenewalDate: referenceDate, statusRawValue: "cancelled")

        // 旧容器一关，托管对象就不能再碰了，所以 id 要在还活着的时候取出来。
        var firstID = UUID()
        do {
            let legacy = try PersistenceController.makeLegacyContainer(url: url)
            let context = legacy.mainContext
            context.insert(first)
            context.insert(cancelled)
            context.insert(DecisionRecord(renewalItemID: first.id, itemName: first.name, actionRawValue: "continued", amountMinorUnits: 2100))
            try context.save()
            firstID = first.id
        }

        let container = try PersistenceController.makeContainer(url: url)
        let context = container.mainContext
        let items = try context.fetch(FetchDescriptor<ExpiryItem>())
        let events = try context.fetch(FetchDescriptor<ExpiryEvent>())

        XCTAssertEqual(items.count, 2, "旧库里的两条订阅都要出现在新库")
        let cloud = try XCTUnwrap(items.first { $0.name == "云储存 200GB" })
        XCTAssertEqual(cloud.priceMinorUnits, 2100)
        XCTAssertEqual(cloud.currencyCode, "CNY")
        XCTAssertEqual(cloud.recurrence, .yearly)
        XCTAssertEqual(cloud.expiryDate, referenceDate)
        XCTAssertEqual(cloud.reminderOffsets, [7 * 24 * 60, 0])
        XCTAssertEqual(cloud.state, .active)
        XCTAssertEqual(try XCTUnwrap(items.first { $0.name == "旧会员" }).state, .cancelled)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventType, .renewed)
        XCTAssertEqual(events.first?.itemID, firstID)
        XCTAssertEqual(events.first?.priceMinorUnits, 2100)
    }
}
