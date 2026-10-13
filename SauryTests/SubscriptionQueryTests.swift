import XCTest
@testable import Saury

/// 任务书 §8.2：订阅页那一屏「看得见哪几条、按什么排、合计对着一批算」的判断。
///
/// 这些规则全都长在「刷新一次会不会变」上，所以每一条都反复调用同一个函数考它，
/// 而不是只断言一次结果。视图里那段 `items` 现在只是转手调这里的函数，
/// 测到的就是屏幕上真在用的那一份判断。
@MainActor
final class SubscriptionQueryTests: XCTestCase {
    private let day: TimeInterval = 86_400

    /// 不入库的裸对象：这一层只读字段，不需要 SwiftData 上下文。
    private func sub(_ name: String,
                     id: UUID = UUID(),
                     plan: String = "",
                     notes: String = "",
                     category: String = "other",
                     payment: String = "",
                     price: Int = 1000,
                     currency: String = "CNY",
                     cycle: BillingCycle = .monthly,
                     state: SubscriptionState = .autoRenew,
                     start: Date = Date(timeIntervalSince1970: 1_700_000_000),
                     created: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Subscription {
        Subscription(id: id, name: name, plan: plan, priceMinorUnits: price,
                     currencyCode: currency, cycle: cycle, category: category,
                     state: state, startDate: start, paymentMethod: payment,
                     notes: notes, createdAt: created)
    }

    private let none = SubPreferences.ListFilters()

    private func visible(_ items: [Subscription], search: String = "",
                         filters: SubPreferences.ListFilters = SubPreferences.ListFilters()) -> [Subscription] {
        SubscriptionQuery.visible(items, search: search, filters: filters) { _ in "效率" }
    }

    private func names(_ items: [Subscription]) -> [String] {
        items.map(\.name)
    }

    // MARK: - 谁该出现在这一屏

    func testArchivedAndTrashedNeverShow() {
        let live = sub("Netflix")
        let archived = sub("老账号")
        archived.archivedAt = Date()
        let trashed = sub("删掉的")
        trashed.deletedAt = Date()

        XCTAssertEqual(names(visible([live, archived, trashed])), ["Netflix"],
                       "归档和回收站里的不许混进列表，哪怕一个筛选条件都没设")
    }

    func testSearchHitsEveryFieldIncludingTheCategoryName() {
        let byName = sub("爱奇艺")
        let byPlan = sub("网盘", plan: "星钻会员")
        let byNotes = sub("记账本", notes: "和朋友合租")
        let byPayment = sub("工具", payment: "PayPal")
        let byCategory = sub("新服务", category: "video")
        let all = [byName, byPlan, byNotes, byPayment, byCategory]

        XCTAssertEqual(names(visible(all, search: "奇艺")), ["爱奇艺"])
        XCTAssertEqual(names(visible(all, search: "星钻")), ["网盘"])
        XCTAssertEqual(names(visible(all, search: "合租")), ["记账本"])
        XCTAssertEqual(names(visible(all, search: "paypal")), ["工具"], "大小写不该影响命中")
        XCTAssertEqual(names(visible(all, search: "视频")).count, 0, "分类名由外面给，这里给的是「效率」")
    }

    func testSearchIgnoresSurroundingWhitespaceAndBlankIsNoSearch() {
        let items = [sub("Netflix")]
        XCTAssertEqual(visible(items, search: "  netflix \n").count, 1)
        XCTAssertEqual(visible(items, search: "   ").count, 1, "全是空格的输入等于没搜")
        XCTAssertFalse(SubscriptionQuery.isNarrowed(search: "   ", filters: none))
    }

    func testFilterGroupsCombineWithAndWhileMembersCombineWithOr() {
        let videoAuto = sub("腾讯视频", category: "video", payment: "微信支付", state: .autoRenew)
        let videoManual = sub("爱奇艺", category: "video", payment: "支付宝", state: .manualRenew)
        let toolAuto = sub("Notion", category: "tool", payment: "PayPal", state: .autoRenew)
        let all = [videoAuto, videoManual, toolAuto]

        // 组内「或」：两个分类都算命中。
        XCTAssertEqual(Set(names(visible(all, filters: .init(categoryIDs: ["video", "tool"])))),
                       Set(["腾讯视频", "爱奇艺", "Notion"]))
        // 组间「与」：分类 + 状态，只剩既是视频又自动续费的那条。
        XCTAssertEqual(names(visible(all, filters: .init(categoryIDs: ["video"], states: [.autoRenew]))),
                       ["腾讯视频"])
        // 支付方式单独一组也一样是「与」的其中一格。
        XCTAssertEqual(names(visible(all, filters: .init(paymentMethods: ["支付宝"]))), ["爱奇艺"])
    }

    func testEmptyFilterGroupRestrictsNothing() {
        let all = [sub("A"), sub("B")]
        XCTAssertEqual(visible(all, filters: none).count, 2)
        var partial = SubPreferences.ListFilters()
        partial.categoryIDs = []
        partial.states = []
        XCTAssertEqual(visible(all, filters: partial).count, 2)
        XCTAssertFalse(partial.isActive)
    }

    func testIsNarrowedTracksWhatActuallyNarrows() {
        XCTAssertFalse(SubscriptionQuery.isNarrowed(search: "", filters: none))
        XCTAssertTrue(SubscriptionQuery.isNarrowed(search: "云", filters: none))
        XCTAssertTrue(SubscriptionQuery.isNarrowed(search: "", filters: .init(currencies: ["USD"])))
        XCTAssertFalse(SubscriptionQuery.isNarrowed(search: "  ", filters: none))
    }

    func testSelectedCountAddsEveryGroup() {
        XCTAssertEqual(none.selectedCount, 0)
        let filters = SubPreferences.ListFilters(categoryIDs: ["video", "tool"],
                                                 states: [.autoRenew],
                                                 paymentMethods: [],
                                                 currencies: ["USD", "JPY"])
        XCTAssertEqual(filters.selectedCount, 5)
    }

    // MARK: - 排序：同一条排两次必须还是那个位置

    func testEqualPricesKeepTheSameOrderAcrossRenders() {
        // 三条一样的价钱。Swift 的 `sort` 不保证稳定，没有兜底次序的话
        // 同一批数据刷新两次就能换个位 —— 列表看起来在跳。
        let a = sub("Alpha", price: 6800)
        let b = sub("Bravo", price: 6800)
        let c = sub("Charlie", price: 6800)
        let items = [c, a, b]

        let first = SubscriptionQuery.sorted(items, by: .priceAscending, seed: UUID(),
                                             defaultCurrency: "CNY", rates: [:])
        for _ in 0..<5 {
            let again = SubscriptionQuery.sorted(items, by: .priceAscending, seed: UUID(),
                                                 defaultCurrency: "CNY", rates: [:])
            XCTAssertEqual(names(again), names(first), "同价三条每次刷新换个位")
        }
    }

    func testPinnedLeadAndTheRestKeepTheirPrimaryOrder() {
        // 置顶那一趟排序如果写成「非置顶一律相等」，不稳定排序会把后面那批打乱。
        let cheap = sub("A便宜", price: 100)
        let middle = sub("B中等", price: 500)
        let dear = sub("C贵", price: 900)
        let pinnedLate = sub("D置顶晚", price: 300)
        pinnedLate.pinnedAt = Date(timeIntervalSince1970: 2_000)
        let pinnedEarly = sub("E置顶早", price: 300)
        pinnedEarly.pinnedAt = Date(timeIntervalSince1970: 1_000)

        let ordered = SubscriptionQuery.sorted([cheap, middle, dear, pinnedLate, pinnedEarly],
                                              by: .priceAscending, seed: UUID(),
                                              defaultCurrency: "CNY", rates: [:])
        XCTAssertEqual(names(ordered), ["D置顶晚", "E置顶早", "A便宜", "B中等", "C贵"],
                       "置顶在最前、它们之间刚置顶的在前，其余仍按费用升序")
    }

    func testPriceSortUsesTheExchangeRateNotTheRawNumber() {
        let cny = sub("人民币", price: 10_000)                    // ¥100
        let usd = sub("美元", price: 2_000, currency: "USD")      // $20
        let rates = ["CNY": 7.0, "USD": 1.0]

        let ascending = SubscriptionQuery.sorted([cny, usd], by: .priceAscending, seed: UUID(),
                                                 defaultCurrency: "CNY", rates: rates)
        XCTAssertEqual(names(ascending), ["人民币", "美元"], "$20 折成 ¥140，比 ¥100 贵")
        XCTAssertEqual(names(SubscriptionQuery.sorted([cny, usd], by: .priceDescending, seed: UUID(),
                                                      defaultCurrency: "CNY", rates: rates)),
                       ["美元", "人民币"])
    }

    func testUnknownNextChargeSinksToTheBottom() {
        let soon = sub("下周扣", cycle: .weekly, start: Date(timeIntervalSince1970: 1_700_000_000))
        let later = sub("明年扣", cycle: .yearly, start: Date(timeIntervalSince1970: 1_700_000_000))
        let oneTime = sub("买断", cycle: .oneTime)

        let ordered = SubscriptionQuery.sorted([oneTime, later, soon], by: .nextCharge, seed: UUID(),
                                               defaultCurrency: "CNY", rates: [:])
        XCTAssertEqual(names(ordered).first, "下周扣")
        XCTAssertEqual(names(ordered).last, "买断", "认不出下一次扣费的不能混在近期扣费里")
    }

    func testDurationAndAddedDateAreOppositeTimeAxes() {
        let old = sub("先订的", start: Date(timeIntervalSince1970: 1_000), created: Date(timeIntervalSince1970: 5_000))
        let fresh = sub("后订的", start: Date(timeIntervalSince1970: 2_000), created: Date(timeIntervalSince1970: 4_000))

        XCTAssertEqual(names(SubscriptionQuery.sorted([fresh, old], by: .duration, seed: UUID(),
                                                      defaultCurrency: "CNY", rates: [:])),
                       ["先订的", "后订的"], "按订阅时长 = 开始得早的在前")
        XCTAssertEqual(names(SubscriptionQuery.sorted([fresh, old], by: .addedDate, seed: UUID(),
                                                      defaultCurrency: "CNY", rates: [:])),
                       ["先订的", "后订的"], "按添加时间 = 后加的在前，这里 old 的 createdAt 更晚")
    }

    /// 固定的 id：随机这一档看的就是 id，id 每轮换新Uuid 的话这一组断言变成掷骰子，
    /// 「换个 seed 要换种排法」这种话就再也拦不住回归了。
    private func fixedID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    func testRandomIsReproduciblePerSeedAndDifferentAcrossSeeds() {
        // 12 条：想让两个 seed 洗出同一个顺序，概率是 1/12!，撞不上运气。
        let items = (0..<12).map { sub("条目\($0)", id: fixedID($0)) }
        let seed = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let nameOrder = SubscriptionQuery.sorted(items, by: .name, seed: seed,
                                                 defaultCurrency: "CNY", rates: [:])

        let first = SubscriptionQuery.sorted(items, by: .random, seed: seed,
                                             defaultCurrency: "CNY", rates: [:])
        XCTAssertEqual(names(first), names(SubscriptionQuery.sorted(items, by: .random, seed: seed,
                                                                   defaultCurrency: "CNY", rates: [:])),
                       "同一颗 seed 洗出来必须是同一个顺序，否则刷新一下又变")
        XCTAssertEqual(Set(names(first)), Set(names(items)), "随机不许丢条目也不许多条目")
        XCTAssertNotEqual(names(first), names(nameOrder), "随机这一档不许退化成按名称")

        let other = SubscriptionQuery.sorted(items, by: .random,
                                             seed: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                                             defaultCurrency: "CNY", rates: [:])
        XCTAssertNotEqual(names(other), names(first), "换 seed 要换一种排法")

        // 只断言「不一样」拦不住这类毛病：seed 的影响整体乘在哈希前面的话，换 seed
        // 等于把同一批键平移一格，洗出来的顺序只是转了个圈 —— 按「再随机一次」看着没反应。
        // 真洗过之后 12 条里对上位次的不该超过两三处，这里取 8 作为底线。
        let moved = zip(names(first), names(other)).filter { $0 != $1 }.count
        XCTAssertGreaterThanOrEqual(moved, 8,
                                    "换 seed 只把顺序转了个圈（这里只有 \(moved) 处换了位置）")
    }

    func testRandomKeepsPinnedOnTopWithoutDuplicatingIt() {
        // 「随机」洗的是其余那一批：置顶的那条哪一档都在最前，而且只出现一次。
        let pinned = sub("置顶的")
        pinned.pinnedAt = Date()
        let items = [pinned] + (0..<6).map { sub("条目\($0)", id: fixedID(100 + $0)) }
        let seed = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let ordered = SubscriptionQuery.sorted(items, by: .random, seed: seed,
                                               defaultCurrency: "CNY", rates: [:])
        XCTAssertEqual(names(ordered).first, "置顶的", "随机不许把置顶的洗到看不见的地方")
        XCTAssertEqual(ordered.filter(\.isPinned).count, 1, "同一条不许摆两份")
        XCTAssertEqual(Set(names(ordered)).count, ordered.count, "不许丢条目也不许多条目")
    }

    // MARK: - 分节与合计口径

    func testGroupedSectionsSplitRecurringFromOneTime() {
        let monthly = sub("月费", cycle: .monthly)
        let yearly = sub("年费", cycle: .yearly)
        let bought = sub("买断", cycle: .oneTime)
        let sections = SubscriptionQuery.sections(of: [monthly, bought, yearly])

        XCTAssertEqual(sections.map(\.title), ["周期订阅", "买断 · 一次性"])
        XCTAssertEqual(names(sections[0].items), ["月费", "年费"])
        XCTAssertEqual(names(sections[1].items), ["买断"])
    }

    func testEmptySectionIsNotRendered() {
        let sections = SubscriptionQuery.sections(of: [sub("买断", cycle: .oneTime)])
        XCTAssertEqual(sections.map(\.title), ["买断 · 一次性"], "空节不许占一行")
        XCTAssertTrue(SubscriptionQuery.sections(of: []).isEmpty)
    }

    func testSummaryScopeFollowsTheVisibleSetOnlyWhenNarrowed() {
        let live = sub("在册", price: 1000)
        let paused = sub("停用", price: 9_000, state: .inactive)
        let hidden = sub("筛掉的", price: 500)

        let all = SubscriptionQuery.summaryScope([live, hidden], all: [live, paused, hidden],
                                                 narrowed: false)
        XCTAssertEqual(names(all), ["在册", "筛掉的"], "没收窄时算全部在册的，停用的一向不计入")
        XCTAssertFalse(all.contains { $0.name == "停用" }, "停用的一条都不许算进合计")

        let narrowed = SubscriptionQuery.summaryScope([live], all: [live, paused, hidden],
                                                      narrowed: true)
        XCTAssertEqual(names(narrowed), ["在册"], "收窄之后就只算屏上这一批，否则合计不是用户看的这些东西的钱")
    }

    func testNormalizedSearchTrimsBothEnds() {
        XCTAssertEqual(SubscriptionQuery.normalizedSearch("  iCloud  "), "iCloud")
        XCTAssertEqual(SubscriptionQuery.normalizedSearch("\n\t"), "")
    }

    // MARK: - 总览面板：待付款 / 试用中

    func testAwaitingPaymentIsManualRenewalsThatStillHaveADueDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let manual = sub("手动", state: .manualRenew, start: now.addingTimeInterval(-86_400))
        let auto = sub("自动", state: .autoRenew, start: now.addingTimeInterval(-86_400))
        let stopped = sub("停用", state: .inactive)
        let oneOff = sub("买断", cycle: .oneTime, state: .manualRenew)
        let ended = sub("已过期", state: .manualRenew, start: now.addingTimeInterval(-86_400))
        ended.endDate = now.addingTimeInterval(-3_600)
        let archived = sub("归档的", state: .manualRenew, start: now.addingTimeInterval(-86_400))
        archived.archivedAt = now
        let trashed = sub("回收站", state: .manualRenew, start: now.addingTimeInterval(-86_400))
        trashed.deletedAt = now

        let all = [manual, auto, stopped, oneOff, ended, archived, trashed]
        XCTAssertEqual(names(SubscriptionQuery.awaitingPayment(all, onOrAfter: now)), ["手动"],
                       "待付款只收手动续费且推得出下一笔的：自动的、停用的、买断的、越过结束日的、归档和回收站的都不算")
        for _ in 0..<5 {
            XCTAssertEqual(names(SubscriptionQuery.awaitingPayment(all, onOrAfter: now)), ["手动"],
                           "同一批数据换个顺序问，答案不许变")
        }
    }

    func testAwaitingPaymentSortsByDueDateThenName() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weekly = sub("周付", cycle: .weekly, state: .manualRenew, start: now.addingTimeInterval(-86_400))
        let monthly = sub("月付", state: .manualRenew, start: now.addingTimeInterval(-86_400))
        XCTAssertEqual(names(SubscriptionQuery.awaitingPayment([monthly, weekly], onOrAfter: now)),
                       ["周付", "月付"], "6 天后应付的排在约一个月后应付的前面")

        // 同一天的两条：名称兜底，反复问也不许换位。
        let bravo = sub("Bravo", state: .manualRenew, start: now.addingTimeInterval(-86_400))
        let charlie = sub("Charlie", state: .manualRenew, start: now.addingTimeInterval(-86_400))
        let doubled = [charlie, bravo]
        let first = names(SubscriptionQuery.awaitingPayment(doubled, onOrAfter: now))
        XCTAssertEqual(first, ["Bravo", "Charlie"])
        for _ in 0..<5 {
            XCTAssertEqual(names(SubscriptionQuery.awaitingPayment(doubled, onOrAfter: now)), first,
                           "同一天应付的两条每次刷新换个位")
        }
    }

    func testNotStartedShowsOnlyFutureStartsAndSortsByStartDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let soon = sub("下周开始", start: now.addingTimeInterval(6 * 86_400))
        let later = sub("一年后开始", start: now.addingTimeInterval(300 * 86_400))
        let running = sub("已开始", start: now.addingTimeInterval(-86_400))
        let atNow = sub("正点开始", start: now)
        let stopped = sub("停用的未来", state: .inactive, start: now.addingTimeInterval(86_400))
        let archived = sub("归档的", start: now.addingTimeInterval(86_400))
        archived.archivedAt = now
        let trashed = sub("回收站", start: now.addingTimeInterval(86_400))
        trashed.deletedAt = now

        let all = [later, running, soon, atNow, stopped, archived, trashed]
        XCTAssertEqual(names(SubscriptionQuery.notStarted(all, asOf: now)), ["下周开始", "一年后开始"],
                       "试用中只收开始日排在未来、还在册的：已开始的、正好当下的、停用/归档/回收站的都不算")
        for _ in 0..<5 {
            XCTAssertEqual(names(SubscriptionQuery.notStarted(all, asOf: now)), ["下周开始", "一年后开始"],
                           "同一批数据换个顺序问，答案不许变")
        }
    }

    // MARK: - 小玩具：抽签与冷知识

    func testRandomPickOnlyDrawsFromLiveUnpinnedAndIsStablePerSeed() {
        let live = sub("在册", id: fixedID(1))
        let liveB = sub("在册二", id: fixedID(6))
        let pinned = sub("置顶", id: fixedID(2))
        pinned.pinnedAt = Date()
        let archived = sub("归档", id: fixedID(3))
        archived.archivedAt = Date()
        let trashed = sub("回收站", id: fixedID(4))
        trashed.deletedAt = Date()
        let stopped = sub("停用", id: fixedID(5), state: .inactive)
        let pool = [live, pinned, archived, trashed, stopped]

        // 换 seed 随便抽：只可能命中两条在册的非置顶，置顶/归档/回收站/停用一条都不许进池子。
        for _ in 0..<12 {
            let pick = SubscriptionQuery.randomPick(pool, seed: UUID(), defaultCurrency: "CNY", rates: [:])
            XCTAssertEqual(["在册", "在册二"].contains(pick?.name ?? ""), true,
                           "抽出来的是 \(pick?.name ?? "nil")：抽签池混进了不该有的行")
        }
        // 同一颗 seed 反复抽是同一条 —— 「再抽一次」是按 seed 换排法，不是每次刷新掷骰子。
        let seed = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let first = SubscriptionQuery.randomPick(pool, seed: seed, defaultCurrency: "CNY", rates: [:])
        for _ in 0..<5 {
            XCTAssertEqual(SubscriptionQuery.randomPick(pool, seed: seed, defaultCurrency: "CNY", rates: [:])?.id,
                           first?.id, "同一颗 seed 抽出了不同的人")
        }
    }

    func testRandomPickFallsBackToPinnedWhenThatIsAllThereIs() {
        let pinned = sub("唯一置顶")
        pinned.pinnedAt = Date()
        XCTAssertEqual(SubscriptionQuery.randomPick([pinned], seed: UUID(),
                                                    defaultCurrency: "CNY", rates: [:])?.name,
                       "唯一置顶", "全是置顶时也要抽得出东西，不能空手")
        XCTAssertNil(SubscriptionQuery.randomPick([], seed: UUID(), defaultCurrency: "CNY", rates: [:]))
    }

    func testOldestIsStableAndPicksTheEarliestStart() {
        let old = sub("最早", start: Date(timeIntervalSince1970: 1_000))
        let newer = sub("后来的", start: Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(SubscriptionQuery.oldest([newer, old])?.name, "最早")
        XCTAssertNil(SubscriptionQuery.oldest([]))

        // 同一天开始的两条：反复算不许来回换人。
        let twinA = sub("A同天", id: fixedID(10), start: Date(timeIntervalSince1970: 2_000))
        let twinB = sub("B同天", id: fixedID(11), start: Date(timeIntervalSince1970: 2_000))
        let first = SubscriptionQuery.oldest([twinB, twinA])?.name
        for _ in 0..<5 {
            XCTAssertEqual(SubscriptionQuery.oldest([twinB, twinA])?.name, first, "同一天的两条在换人")
        }
    }

    func testPriciestConvertsCurrencyBeforeComparing() {
        let cny = sub("人民币", price: 10_000)                    // ¥100
        let usd = sub("美元", price: 2_000, currency: "USD")      // $20
        let rates = ["CNY": 7.0, "USD": 1.0]
        XCTAssertEqual(SubscriptionQuery.priciest([cny, usd], defaultCurrency: "CNY", rates: rates)?.name,
                       "美元", "$20 折成 ¥140，比 ¥100 贵；不折算就会挑错人")
        XCTAssertNil(SubscriptionQuery.priciest([], defaultCurrency: "CNY", rates: rates))
    }

    func testPriciestBreaksTiesWithTheFirstRowOfThePriceDescendingList() {
        let bravo = sub("Bravo", price: 10_000)
        let apple = sub("Apple", price: 10_000)
        let rates = ["CNY": 7.0, "USD": 1.0]
        // 定这条口径不是为了好看：小玩具页「最贵的一笔」和按价格降序的列表
        // 对同一条库必须指向同一个人，打平时也一样。
        let listFirst = SubscriptionQuery.sorted([bravo, apple], by: .priceDescending, seed: UUID(),
                                                 defaultCurrency: "CNY", rates: rates).first
        for _ in 0..<3 {
            let picked = SubscriptionQuery.priciest([bravo, apple], defaultCurrency: "CNY", rates: rates)
            XCTAssertEqual(picked?.id, listFirst?.id, "同价必须和降序列表第一行是同一个人，且反复算不换人")
        }
        XCTAssertEqual(listFirst?.name, "Apple", "这条名单本身就按名字升序打平")
    }
}
