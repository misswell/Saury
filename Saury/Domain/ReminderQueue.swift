import Foundation

/// 通知标识符的唯一出处（方案 §40）。同一个物品用两种写法，
/// 「该取消的没取消」就会变成长期重复提醒，而且界面上根本看不出来。
enum NotificationIdentifier {
    static let expiryPrefix = "saury.expiry."
    static let snoozePrefix = "saury.snooze."
    /// 改造之前用过的两套前缀。升级后第一次排队前必须清掉，
    /// 否则旧通知会和新通知一起响。
    static let legacyPrefixes = ["qijian.renewal.", "qijian.snooze."]

    /// 一个物品 + 一个提前量 = 一个标识符：重排同一条时系统会覆盖而不是叠加。
    static func expiry(itemID: UUID, offset: Int) -> String {
        "\(expiryPrefix)\(itemID.uuidString).\(offset)"
    }

    /// snooze 每次带一个新的尾号（方案 §40）：同一件东西可以一再推迟，
    /// 而普通重排在任何分支下都不许碰 snooze。
    static func snooze(itemID: UUID, nonce: UUID = UUID()) -> String {
        "\(snoozePrefix)\(itemID.uuidString).\(nonce.uuidString)"
    }

    /// 同一件物品全部 snooze 共用的前缀，用于「一个物品最多留一条」。
    static func snoozeGroup(itemID: UUID) -> String {
        "\(snoozePrefix)\(itemID.uuidString)."
    }

    static func isExpiry(_ identifier: String) -> Bool { identifier.hasPrefix(expiryPrefix) }
    static func isSnooze(_ identifier: String) -> Bool { identifier.hasPrefix(snoozePrefix) }
    static func isLegacy(_ identifier: String) -> Bool { legacyPrefixes.contains { identifier.hasPrefix($0) } }

    /// 从标识符反查物品，snooze 和到期提醒都认。
    static func itemID(for identifier: String) -> UUID? {
        let rest: Substring
        if isExpiry(identifier) {
            rest = identifier.dropFirst(expiryPrefix.count)
        } else if isSnooze(identifier) {
            rest = identifier.dropFirst(snoozePrefix.count)
        } else {
            return nil
        }
        guard let head = rest.split(separator: ".").first else { return nil }
        return UUID(uuidString: String(head))
    }
}

/// 通知队列的纯计算部分（方案 §39、§41）：谁该在什么时候被提醒、装不下的怎么淘汰、
/// 队列里已有的要不要动。全部从物品现算，不额外存一份队列副本，
/// 所以 App 重启后重建出来的队列和重启前必然一致。
enum ReminderQueue {
    /// iOS 待投递通知有数量上限，普通提醒只占这么多，剩下的位置留给 snooze。
    static let regularCapacity = 56
    static let snoozeCapacity = 6
    /// 只排到这么多天以内：更远的通知没有意义，也会被系统淘汰。
    static let horizonDays = 120

    struct Candidate {
        let item: ExpiryItem
        let offset: Int
        let fireAt: Date

        var identifier: String { NotificationIdentifier.expiry(itemID: item.id, offset: offset) }
    }

    /// 系统里已经排着的东西：标识符 + 当时排的时刻。
    struct Pending {
        let identifier: String
        let fireAt: Date?
    }

    struct Delta {
        var toAdd: [Candidate] = []
        var toRemove: [String] = []
        var keeping: [String] = []
    }

    /// 触发时刻按分钟对齐：系统就是按分钟投递的，对齐之后
    /// 「队列里这条和候选是不是同一条」才是精确比较，不需要容差。
    static func rounded(_ date: Date, calendar: Calendar = ExpiryEngine.calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    static func candidates(
        for items: [ExpiryItem],
        now: Date = Date(),
        preferredHour: Int = ReminderPolicy.reminderHour,
        calendar: Calendar = ExpiryEngine.calendar
    ) -> [Candidate] {
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: now) ?? now
        return items.filter(\.isActive).flatMap { item in
            item.reminderOffsets.compactMap { offset -> Candidate? in
                let fireAt = rounded(ExpiryEngine.notificationDate(
                    forExpiry: ExpiryEngine.effectiveExpiryDate(for: item, calendar: calendar),
                    minutesBefore: offset,
                    preferredHour: preferredHour,
                    calendar: calendar
                ), calendar: calendar)
                guard fireAt > now, fireAt <= horizon else { return nil }
                return Candidate(item: item, offset: offset, fireAt: fireAt)
            }
        }
    }

    /// 最近触发的优先，同标识符只留一条，截到容量内。
    static func scheduled(
        _ candidates: [Candidate],
        capacity: Int = regularCapacity
    ) -> [Candidate] {
        var seen: Set<String> = []
        var chosen: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.fireAt < $1.fireAt }) {
            guard seen.insert(candidate.identifier).inserted else { continue }
            chosen.append(candidate)
            if chosen.count == capacity { break }
        }
        return chosen
    }

    /// 只算差额（方案 §39）：已经排好、时刻也没变的一条都不动，
    /// 改日期只动那一条，删除物品才撤掉它的通知。snooze 永远不在撤除范围内。
    static func delta(
        pending: [Pending],
        desired: [Candidate],
        capacity: Int = regularCapacity
    ) -> Delta {
        var result = Delta()
        var expiryPending: [String: Date?] = [:]
        for entry in pending {
            if isSnooze(entry.identifier) { continue }
            if isLegacy(entry.identifier) {
                result.toRemove.append(entry.identifier)
                continue
            }
            guard isExpiry(entry.identifier) else { continue }
            expiryPending[entry.identifier] = entry.fireAt
        }

        let chosen = scheduled(desired, capacity: capacity)
        var desiredIDs: Set<String> = []
        for candidate in chosen {
            desiredIDs.insert(candidate.identifier)
            if let existing = expiryPending[candidate.identifier], existing == candidate.fireAt {
                result.keeping.append(candidate.identifier)
                continue
            }
            result.toAdd.append(candidate)
            // 到期日改了：标识符还是同一个，但时刻不对，先撤再排。
            if expiryPending[candidate.identifier] != nil {
                result.toRemove.append(candidate.identifier)
            }
        }
        for identifier in expiryPending.keys where !desiredIDs.contains(identifier) {
            result.toRemove.append(identifier)
        }

        result.toRemove.sort()
        result.keeping.sort()
        return result
    }

    private static func isSnooze(_ identifier: String) -> Bool { NotificationIdentifier.isSnooze(identifier) }
    private static func isLegacy(_ identifier: String) -> Bool { NotificationIdentifier.isLegacy(identifier) }
    private static func isExpiry(_ identifier: String) -> Bool { NotificationIdentifier.isExpiry(identifier) }
}

/// 通知按钮的分组标识（方案 §35、§39）：一件物品的按钮集合由「动作分组 + 分类」
/// 完全决定，所以按这两样预先注册，通知上的说法和 App 里就是同一句话。
enum ReminderCategory {
    static let identifierPrefix = "saury.reminder."
    static let actionPrefix = "saury.action."
    /// 通知正文里带回物品用的键，App 从通知打开时靠它定位。
    static let itemIDKey = "expiryItemID"
    static let fireAtKey = "fireAt"

    static func identifier(for item: ExpiryItem) -> String {
        // 标识符必须唯一对应一套按钮：同一个键下出现两套动作，
        // 先注册的那套会赢，另一件物品的按钮就悄悄变了。
        let key = actions(for: item).map(\.rawValue).joined(separator: ".")
        return "\(identifierPrefix)\(item.category.rawValue).\(key)"
    }

    /// 通知上不放「归档」：那件事适合在 App 里做，不适合在锁屏上一滑手点掉。
    /// 也算不出下一次就不放「续期」：锁屏问不了新日期，一个点了什么都
    /// 不会发生的按钮比少一个按钮更糟。
    static func actions(for item: ExpiryItem) -> [ExpiryAction] {
        ExpiryActionGroup(for: item).actions.filter { action in
            action != .renewed || item.nextOccurrence != nil
        } + [.snoozed]
    }

    static func actionIdentifier(_ action: ExpiryAction) -> String {
        "\(actionPrefix)\(action.rawValue)"
    }

    static func action(for identifier: String) -> ExpiryAction? {
        guard identifier.hasPrefix(actionPrefix) else { return nil }
        return ExpiryAction(rawValue: String(identifier.dropFirst(actionPrefix.count)))
    }
}
