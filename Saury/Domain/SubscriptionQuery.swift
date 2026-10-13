import Foundation

/// 订阅页那一屏的判断：哪几条看得见、按什么排、那一行合计对着哪一批算。
///
/// 全是纯函数，输入只有列表、搜索词、筛选档位和排序档位。写在这里而不是留在
/// 视图里，是因为这几件事的坑都长在「刷新一次会不会变」上（任务书 §8.2）——
/// 只有拿真列表反复考才拦得住，靠眼睛看一屏是看不出来的。
enum SubscriptionQuery {
    /// 搜索词去掉首尾空白。全是空格的输入等于没搜。
    static func normalizedSearch(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 这一屏是不是被收窄了。空态文案和合计口径都看这一个判断。
    static func isNarrowed(search: String, filters: SubPreferences.ListFilters) -> Bool {
        !normalizedSearch(search).isEmpty || filters.isActive
    }

    /// 看得见的那几条：归档和回收站里的都不算。
    /// 搜索命中名称 / 套餐 / 备注 / 支付方式 / 分类名任意一处；
    /// 四组筛选之间是「与」，组内是「或」，空的那组不设限制。
    static func visible(_ subscriptions: [Subscription],
                        search: String,
                        filters: SubPreferences.ListFilters,
                        categoryName: (String) -> String) -> [Subscription] {
        var result = subscriptions.filter { $0.deletedAt == nil && $0.archivedAt == nil }
        let text = normalizedSearch(search).lowercased()
        if !text.isEmpty {
            result = result.filter { item in
                item.name.lowercased().contains(text)
                    || item.plan.lowercased().contains(text)
                    || item.notes.lowercased().contains(text)
                    || item.paymentMethod.lowercased().contains(text)
                    || categoryName(item.categoryRawValue).lowercased().contains(text)
            }
        }
        if filters.isActive {
            result = result.filter { item in
                (filters.categoryIDs.isEmpty || filters.categoryIDs.contains(item.categoryRawValue))
                    && (filters.states.isEmpty || filters.states.contains(item.state))
                    && (filters.paymentMethods.isEmpty || filters.paymentMethods.contains(item.paymentMethod))
                    && (filters.currencies.isEmpty || filters.currencies.contains(item.currencyCode))
            }
        }
        return result
    }

    /// 排好序的那几条。置顶的永远在最前（哪一档都一样），它们之间按「刚置顶的在前」；
    /// 其余的按当前档排。
    ///
    /// 每一档比较都补一条兜底次序。Swift 的 `sort` 不保证稳定，同价、同日、同名
    /// 只要没有兜底，下一次刷新就能把两条换个位置 —— 列表看起来就在跳。
    static func sorted(_ items: [Subscription],
                       by sort: SubscriptionSort,
                       seed: UUID,
                       defaultCurrency: String,
                       rates: [String: Double]) -> [Subscription] {
        let ordered: [Subscription]
        if sort == .random {
            ordered = items.sorted { rank($0.id, seed: seed) < rank($1.id, seed: seed) }
        } else {
            ordered = items.sorted { precedes($0, $1, by: sort, defaultCurrency: defaultCurrency, rates: rates) }
        }
        // 「随机」那一档也不把置顶的洗走：置顶要的就是「不管怎么排都得一眼找到」，
        // 打乱之后它沉到第三屏，这个开关就等于白设了。
        let pinned = items.filter(\.isPinned).sorted { first, second in
            if first.pinnedAt != second.pinnedAt {
                return (first.pinnedAt ?? .distantPast) > (second.pinnedAt ?? .distantPast)
            }
            return first.id.uuidString < second.id.uuidString
        }
        return pinned + ordered.filter { !$0.isPinned }
    }

    /// grouped 档的两个分节：周期订阅在前，买断 / 一次性在后，空的那节不出现。
    static func sections(of items: [Subscription]) -> [(title: String, items: [Subscription])] {
        [
            (title: "周期订阅", items: items.filter { $0.cycle.isRecurring }),
            (title: "买断 · 一次性", items: items.filter { !$0.cycle.isRecurring }),
        ].filter { !$0.items.isEmpty }
    }

    /// 那一行合计对着哪几条算。
    ///
    /// 收窄之后还拿全部订阅算钱，那个数就不是用户正在看的这些东西的钱：
    /// 搜「Netflix」只剩一条，合计却写着二十条的月费。
    /// 口径本身不变（还是「在册、非停用」），变的只是范围。
    static func summaryScope(_ visible: [Subscription],
                             all: [Subscription],
                             narrowed: Bool) -> [Subscription] {
        (narrowed ? visible : all).filter(\.isTracked)
    }

    /// 「待付款」面板那几条：手动续费、在册，而且推得出下一次应付日期。
    ///
    /// 自动续费的到点自己扣，不用你动手；一次性买断和已经越过结束日的没有下一笔 ——
    /// 这两类都不算「待付款」。按应付日期从近到远，同一天再按名称兜底。
    static func awaitingPayment(_ subscriptions: [Subscription],
                                onOrAfter reference: Date = Date()) -> [Subscription] {
        subscriptions.compactMap { item -> (Subscription, Date)? in
            guard item.isTracked, item.state == .manualRenew,
                  let due = BillingMath.nextChargeDate(for: item, onOrAfter: reference) else { return nil }
            return (item, due)
        }
        .sorted { first, second in
            if first.1 != second.1 { return first.1 < second.1 }
            let byName = first.0.name.localizedCaseInsensitiveCompare(second.0.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return first.0.id.uuidString < second.0.id.uuidString
        }
        .map(\.0)
    }

    /// 「试用中」面板那几条。我方没有独立的试用期字段，这里的语义是「还没开始」：
    /// 开始日排在当下之后的在册订阅 —— 先订下、到日子才生效的那些。按开始日从近到远。
    static func notStarted(_ subscriptions: [Subscription],
                           asOf now: Date = Date()) -> [Subscription] {
        subscriptions
            .filter { $0.isTracked && $0.startDate > now }
            .sorted { first, second in
                if first.startDate != second.startDate { return first.startDate < second.startDate }
                let byName = first.name.localizedCaseInsensitiveCompare(second.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return first.id.uuidString < second.id.uuidString
            }
    }

    /// 小玩具「帮我选一个」：在在册订阅里按 seed 抽一条。
    ///
    /// 置顶的不进抽签池 —— 置顶是「找得快」，不是「每次都被翻牌子」；
    /// 全部置顶时才退回从置顶里抽，不然这个按钮就没东西可抽。
    static func randomPick(_ subscriptions: [Subscription],
                           seed: UUID,
                           defaultCurrency: String,
                           rates: [String: Double]) -> Subscription? {
        let tracked = subscriptions.filter(\.isTracked)
        let pool = tracked.filter { !$0.isPinned }
        let source = pool.isEmpty ? tracked : pool
        return sorted(source, by: .random, seed: seed,
                      defaultCurrency: defaultCurrency, rates: rates).first
    }

    /// 冷知识「陪我最久」：开始日最早的一条；同一天按 id 兜底，反复算也不会换人。
    static func oldest(_ subscriptions: [Subscription]) -> Subscription? {
        subscriptions.min { first, second in
            if first.startDate != second.startDate { return first.startDate < second.startDate }
            return first.id.uuidString < second.id.uuidString
        }
    }

    /// 冷知识「最贵的一笔」：把「我承担的那份」折成默认币种之后最大的一条。
    /// 不折算就比数字的话，$20 会输给 ¥100（矩阵里价格排序踩过同一个坑）。
    /// 金额打平时取「按价格降序列表里的第一行」——名字排前的算更贵，
    /// 所以这里名字和 id 两条兜底次序都是反着写的。
    static func priciest(_ subscriptions: [Subscription],
                         defaultCurrency: String,
                         rates: [String: Double]) -> Subscription? {
        subscriptions.max { first, second in
            let a = first.myAmount.converting(to: defaultCurrency, rates: rates).minorUnits
            let b = second.myAmount.converting(to: defaultCurrency, rates: rates).minorUnits
            if a != b { return a < b }
            let byName = first.name.localizedCaseInsensitiveCompare(second.name)
            if byName != .orderedSame { return byName == .orderedDescending }
            return first.id.uuidString > second.id.uuidString
        }
    }

    // MARK: - 比较

    private static func precedes(_ a: Subscription, _ b: Subscription,
                                 by sort: SubscriptionSort,
                                 defaultCurrency: String,
                                 rates: [String: Double]) -> Bool {
        switch sort {
        case .grouped, .nextCharge:
            // 认不出下一次扣费的（一次性、已终止）排到最后，别混在近期扣费里。
            let nextA = BillingMath.nextChargeDate(for: a) ?? .distantFuture
            let nextB = BillingMath.nextChargeDate(for: b) ?? .distantFuture
            if nextA != nextB { return nextA < nextB }
        case .duration:
            if a.startDate != b.startDate { return a.startDate < b.startDate }
        case .addedDate:
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        case .priceDescending, .priceAscending:
            let valueA = a.myAmount.converting(to: defaultCurrency, rates: rates).minorUnits
            let valueB = b.myAmount.converting(to: defaultCurrency, rates: rates).minorUnits
            if valueA != valueB { return sort == .priceDescending ? valueA > valueB : valueA < valueB }
        case .name, .random:
            break
        }
        // 上面没分出先后，或者本来就是「按名称」：都落到这条确定次序上。
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.id.uuidString < b.id.uuidString
    }

    /// 「随机」档的键。
    ///
    /// 自己写的哈希，不是 Swift 的 `Hasher`：后者每个进程换一个种子，用它的话
    /// 同一颗 seed 在下次启动会洗出完全不同的顺序，用户切回来以为列表自己动了。
    /// 这里 seed 不变 → 顺序一定不变，「再随机一次」换 seed 才换一种排法。
    ///
    /// 末尾那三步散列不是装饰。FNV-1a 是滚动的：seed 的影响整体乘在前面，
    /// 单靠它，换 seed 只是把这批键在数轴上平移一格 —— 排序结果还是同一个顺序
    /// 转了个圈，「再随机一次」按下去看着没反应。测试抓到过一次，就是这个原因。
    private static func rank(_ id: UUID, seed: UUID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (seed.uuidString + id.uuidString).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        var mixed = hash
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }
}
