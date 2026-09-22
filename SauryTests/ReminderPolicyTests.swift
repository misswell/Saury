import XCTest
@testable import Saury

/// 提醒计划模板（方案 §43）。
final class ReminderPolicyTests: XCTestCase {
    private let key = QJPreferences.defaultReminderDaysKey
    private let day = 24 * 60

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDefaultPlanNeverRepeatsTheSameMoment() {
        for days in [1, 3, 7, 14, 30] {
            UserDefaults.standard.set(days, forKey: key)
            for category in ExpiryCategory.allCases {
                let offsets = ReminderPolicy.defaultOffsets(for: category)
                XCTAssertEqual(Set(offsets).count, offsets.count,
                               "\(category.title) 在默认提前 \(days) 天时出现了重复提醒")
            }
        }
    }

    func testDefaultPlanRunsFromEarliestToTheDayItself() {
        UserDefaults.standard.set(3, forKey: key)
        for category in ExpiryCategory.allCases {
            let offsets = ReminderPolicy.defaultOffsets(for: category)
            XCTAssertEqual(offsets, offsets.sorted(by: >), "\(category.title) 的顺序反了")
            XCTAssertFalse(offsets.isEmpty)
        }
    }

    func testPresetsOfferEveryDocumentedLadderStep() {
        let presets = ReminderPolicy.presets(for: .food)
        let minutes = Set(presets.map(\.minutesBefore))
        XCTAssertEqual(Set([90 * day, 30 * day, 14 * day, 7 * day, 3 * day, day, 0]).subtracting(minutes), [])
        XCTAssertEqual(presets.count, minutes.count, "勾选档位重复会让同一时刻出现两个按钮")
    }
}
