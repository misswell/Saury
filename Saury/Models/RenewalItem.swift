import Foundation
import SwiftData

@Model
final class RenewalItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var amountMinorUnits: Int
    var currencyCode: String
    var nextRenewalDate: Date
    var anchorDay: Int
    var cycleRawValue: String
    var intervalMonths: Int
    var categoryRawValue: String
    var statusRawValue: String
    var isAutoRenewing: Bool
    var cancelByDate: Date?
    var reminderOffsetsData: Data
    var managementURLString: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        amountMinorUnits: Int = 0,
        currencyCode: String = "CNY",
        nextRenewalDate: Date,
        cycle: RenewalCycle = .monthly,
        intervalMonths: Int = 1,
        category: RenewalCategory = .other,
        status: RenewalStatus = .active,
        isAutoRenewing: Bool = true,
        cancelByDate: Date? = nil,
        reminderOffsets: [Int]? = nil,
        managementURLString: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.amountMinorUnits = max(amountMinorUnits, 0)
        self.currencyCode = currencyCode.isEmpty ? "CNY" : currencyCode
        self.nextRenewalDate = nextRenewalDate
        self.anchorDay = Calendar.current.component(.day, from: nextRenewalDate)
        self.cycleRawValue = cycle.rawValue
        self.intervalMonths = max(intervalMonths, 1)
        self.categoryRawValue = category.rawValue
        self.statusRawValue = status.rawValue
        self.isAutoRenewing = isAutoRenewing
        self.cancelByDate = cancelByDate
        self.reminderOffsetsData = (try? JSONEncoder().encode(reminderOffsets ?? cycle.defaultReminderOffsets)) ?? Data()
        self.managementURLString = managementURLString
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var cycle: RenewalCycle {
        get { RenewalCycle(rawValue: cycleRawValue) ?? .monthly }
        set { cycleRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var category: RenewalCategory {
        get { RenewalCategory(rawValue: categoryRawValue) ?? .other }
        set { categoryRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var status: RenewalStatus {
        get { RenewalStatus(rawValue: statusRawValue) ?? .active }
        set { statusRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var reminderOffsets: [Int] {
        get { (try? JSONDecoder().decode([Int].self, from: reminderOffsetsData)) ?? cycle.defaultReminderOffsets }
        set { reminderOffsetsData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = Date() }
    }

    var isActive: Bool { status == .active }

    func markUpdated() { updatedAt = Date() }
}

extension RenewalItem {
    static func previewItems(referenceDate: Date = Date()) -> [RenewalItem] {
        let calendar = Calendar.current
        let first = calendar.date(byAdding: .day, value: 5, to: referenceDate) ?? referenceDate
        let second = calendar.date(byAdding: .day, value: 13, to: referenceDate) ?? referenceDate
        let third = calendar.date(byAdding: .day, value: 28, to: referenceDate) ?? referenceDate
        return [
            RenewalItem(name: "设计工具 Pro", amountMinorUnits: 6800, nextRenewalDate: first, cycle: .monthly, category: .productivity),
            RenewalItem(name: "云储存 200GB", amountMinorUnits: 2100, nextRenewalDate: second, cycle: .monthly, category: .storage),
            RenewalItem(name: "音乐会员", amountMinorUnits: 1500, nextRenewalDate: third, cycle: .monthly, category: .entertainment)
        ]
    }
}
