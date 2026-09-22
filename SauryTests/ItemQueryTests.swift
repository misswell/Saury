import XCTest
@testable import Saury

/// 搜索、筛选、排序（方案 §16–§18）和位置清单（§33）的口径。
final class ItemQueryTests: XCTestCase {
    private let calendar = ExpiryEngine.calendar
    private let reference = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 9))!

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: reference) ?? reference
    }

    private func makeItem(
        name: String = "牛奶",
        brand: String? = nil,
        category: ExpiryCategory = .food,
        offset: Int = 3,
        barcode: String? = nil,
        batchNumber: String? = nil,
        location: String? = nil,
        quantity: Double = 1,
        unit: String = "件",
        notes: String = "",
        imageIdentifier: String? = nil,
        state: ExpiryState = .active
    ) -> ExpiryItem {
        ExpiryItem(
            name: name, brand: brand, category: category, expiryDate: day(offset),
            barcode: barcode, batchNumber: batchNumber, quantity: quantity, unit: unit,
            location: location, imageIdentifier: imageIdentifier, state: state, notes: notes
        )
    }

    // MARK: - 搜索

    func testSearchCoversEveryDocumentedField() {
        let item = makeItem(
            name: "纯牛奶", brand: "蒙牛", barcode: "6901234567890",
            batchNumber: "A20260901", location: "冰箱", notes: "给孩子的第二瓶",
            imageIdentifier: "uuid-1"
        )
        let haystack = [item]

        for query in ["纯牛", "蒙牛", "6901234", "7890", "A2026", "冰箱", "第二瓶", "食品"] {
            let results = ItemQuery(searchText: query).results(in: haystack, now: reference)
            XCTAssertEqual(results.count, 1, "「\(query)」应该命中这条记录")
        }
    }

    func testSearchMissesUnrelatedText() {
        let results = ItemQuery(searchText: "洗衣液").results(in: [makeItem()], now: reference)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - 筛选

    func testDefaultQueryHidesEverythingTheUserAlreadyHandled() {
        let handled = [ExpiryState.consumed, .discarded, .renewed, .cancelled, .archived]
        let items = handled.map { makeItem(name: $0.title, state: $0) } + [makeItem(name: "还在跟踪")]
        let results = ItemQuery().results(in: items, now: reference)
        XCTAssertEqual(results.map(\.name), ["还在跟踪"])
    }

    func testStateFilterBringsProcessedItemsBack() {
        let items = [makeItem(name: "空盒子", state: .consumed), makeItem(name: "还在跟踪")]
        let results = ItemQuery(states: [.consumed]).results(in: items, now: reference)
        XCTAssertEqual(results.map(\.name), ["空盒子"])
    }

    func testUrgencyBucketsMatchTheDocumentedRanges() {
        let items = [-3, 0, 2, 5, 15, 45].enumerated().map { makeItem(name: "\($0.offset)", offset: $0.element) }
        let expected: [ExpiryUrgency: [String]] = [
            .expired: ["0"], .today: ["1"], .critical: ["2"], .soon: ["3"], .upcoming: ["4"], .normal: ["5"]
        ]
        for (bucket, names) in expected {
            XCTAssertEqual(ItemQuery(urgencies: [bucket]).results(in: items, now: reference).map(\.name), names)
        }
    }

    func testCategoryAndLocationFiltersCombine() {
        let items = [
            makeItem(name: "牛奶", category: .food, location: "冰箱"),
            makeItem(name: "布洛芬", category: .medicine, location: "冰箱"),
            makeItem(name: "酸奶", category: .food, location: "药箱")
        ]
        let results = ItemQuery(categories: [.food], locations: ["冰箱"]).results(in: items, now: reference)
        XCTAssertEqual(results.map(\.name), ["牛奶"])
    }

    func testCompletenessFilters() {
        let items = [makeItem(name: "有图", imageIdentifier: "u1"), makeItem(name: "有条", barcode: "123"), makeItem(name: "光杆")]
        XCTAssertEqual(ItemQuery(hasImageOnly: true).results(in: items, now: reference).map(\.name), ["有图"])
        XCTAssertEqual(ItemQuery(hasBarcodeOnly: true).results(in: items, now: reference).map(\.name), ["有条"])
    }

    func testIsFilteringOnlyReportsRealDeviation() {
        XCTAssertFalse(ItemQuery().isFiltering)
        XCTAssertFalse(ItemQuery(sort: .name).isFiltering, "换排序不算筛选")
        XCTAssertTrue(ItemQuery(searchText: "  奶  ").isFiltering)
        XCTAssertTrue(ItemQuery(categories: [.food]).isFiltering)
    }

    // MARK: - 排序

    func testEarliestExpiryPutsExpiredThingsFirst() {
        let items = [makeItem(name: "半年后", offset: 180), makeItem(name: "昨天", offset: -1), makeItem(name: "今天", offset: 0), makeItem(name: "明天", offset: 1)]
        XCTAssertEqual(ItemQuery().results(in: items, now: reference).map(\.name), ["昨天", "今天", "明天", "半年后"])
    }

    func testEverySortOptionOrdersTheWayItClaims() {
        var old = makeItem(name: "Apple", offset: 5, quantity: 2)
        old.createdAt = day(-9)
        old.updatedAt = day(-9)
        let fresh = makeItem(name: "Zebra", offset: 20, quantity: 9)
        let items = [old, fresh]

        XCTAssertEqual(ItemQuery(sort: .latestExpiry).results(in: items, now: reference).map(\.name), ["Zebra", "Apple"])
        XCTAssertEqual(ItemQuery(sort: .recentlyAdded).results(in: items, now: reference).map(\.name), ["Zebra", "Apple"])
        XCTAssertEqual(ItemQuery(sort: .recentlyModified).results(in: items, now: reference).map(\.name), ["Zebra", "Apple"])
        XCTAssertEqual(ItemQuery(sort: .quantity).results(in: items, now: reference).map(\.name), ["Zebra", "Apple"])
        XCTAssertEqual(ItemQuery(sort: .name).results(in: items, now: reference).map(\.name), ["Apple", "Zebra"])
    }

    func testSortChoiceSurvivesAReopen() {
        let previous = UserDefaults.standard.string(forKey: QJPreferences.itemSortKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: QJPreferences.itemSortKey) }
            else { UserDefaults.standard.removeObject(forKey: QJPreferences.itemSortKey) }
        }
        QJPreferences.itemSort = .name
        XCTAssertEqual(QJPreferences.itemSort, .name)
        UserDefaults.standard.set("不认识的选项", forKey: QJPreferences.itemSortKey)
        XCTAssertEqual(QJPreferences.itemSort, .earliestExpiry, "读到旧版本或损坏的值时要退回默认")
    }

    // MARK: - 批次（§30）

    func testBatchesOfTheSameProductShareAKey() {
        let a = makeItem(name: "纯牛奶", barcode: "6901234567890", batchNumber: "A")
        let b = makeItem(name: "纯牛奶", barcode: "6901234567890", batchNumber: "B")
        XCTAssertEqual(a.productKey, b.productKey)
    }

    func testProductKeyFallsBackToNameWithoutBarcode() {
        let a = makeItem(name: "  酸奶 ")
        let b = makeItem(name: "酸奶")
        XCTAssertEqual(a.productKey, b.productKey)
        XCTAssertNotEqual(a.productKey, makeItem(name: "纯牛奶").productKey)
    }

    // MARK: - 位置清单（§33）

    func testLocationCatalogTrimsAndDeduplicates() {
        let previous = UserDefaults.standard.stringArray(forKey: "qijian.locations")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "qijian.locations") }
            else { UserDefaults.standard.removeObject(forKey: "qijian.locations") }
        }
        LocationCatalog.replace(["冰箱", "  冰箱 ", " 车库 ", "", "阳台"])
        XCTAssertEqual(LocationCatalog.all, ["冰箱", "车库", "阳台"])
    }

    func testUsedLocationsFollowTheCatalogOrder() {
        let previous = UserDefaults.standard.stringArray(forKey: "qijian.locations")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "qijian.locations") }
            else { UserDefaults.standard.removeObject(forKey: "qijian.locations") }
        }
        LocationCatalog.replace(["药箱", "冰箱", "厨房"])
        let items = [
            makeItem(name: "a", location: "厨房"),
            makeItem(name: "b", location: "冰箱"),
            makeItem(name: "c", location: "车库"),
            makeItem(name: "d", location: "冰箱"),
            makeItem(name: "e", location: "   ")
        ]
        XCTAssertEqual(LocationCatalog.usedLocations(in: items), ["冰箱", "厨房", "车库"])
    }

    func testDeletingALocationLeavesTheItemsAlone() {
        let previous = UserDefaults.standard.stringArray(forKey: "qijian.locations")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "qijian.locations") }
            else { UserDefaults.standard.removeObject(forKey: "qijian.locations") }
        }
        let item = makeItem(name: "牛奶", location: "车库")
        LocationCatalog.replace(["冰箱"])
        XCTAssertEqual(item.location, "车库", "清单是建议，不是外键")
    }
}
