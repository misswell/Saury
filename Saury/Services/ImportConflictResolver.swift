import Foundation

/// 把解析结果和本机库比对，算出每一行「新增 / 更新 / 跳过」（任务书 §3.2）。
///
/// 疑似重复一律「默认跳过 + 写清原因」，要用户在预览里点头才算确认 ——
/// 拿一份 CSV 悄悄覆盖别人三年没动过的订阅，是 §3.2 明令禁止的事。
/// 反过来，`编号相同` 那种是同一件事的两份记录，默认更新，而且不提供「新建」：
/// 库里 `id` 是唯一列，插同一条只会静默变成覆盖，给用户一个假的第三选项才是坑。
///
/// 全程只做值的运算，不碰库，所以这里不是主线程隔离的：解析和比对都能放到后台跑。
enum ImportConflictResolver {
    enum Decision: String, CaseIterable, Identifiable, Equatable {
        case create
        case update
        case skip

        var id: String { rawValue }

        var title: String {
            switch self {
            case .create: return "新增一条"
            case .update: return "更新本机这条"
            case .skip: return "跳过"
            }
        }

        /// 行尾那颗胶囊用的短标签：整句话在列表里排不下。
        var shortTitle: String {
            switch self {
            case .create: return "新增"
            case .update: return "更新"
            case .skip: return "跳过"
            }
        }

        var symbol: String {
            switch self {
            case .create: return "plus.circle"
            case .update: return "arrow.triangle.2.circlepath"
            case .skip: return "forward.circle"
            }
        }
    }

    /// 本机那条是怎么被认出来的。措辞要出现在界面上，所以直接写成给用户看的话。
    enum MatchKind: String, Equatable {
        case stableID = "编号相同"
        case sameContent = "内容一致"
        case sameName = "名字相同"
    }

    /// 更新会改掉的本机字段。预览页靠它把「改了哪些」写在明面上。
    struct Diff: Equatable, Identifiable {
        var field: ImportParser.Field
        var localText: String
        var incomingText: String

        var id: String { field.rawValue }
        var text: String { "\(field.rawValue)：\(localText) → \(incomingText)" }
    }

    struct Item: Identifiable, Equatable {
        /// 行 id（跟 `row.id` 一致），界面用它定位。
        let id: UUID
        var row: ImportParser.Row
        /// 比对出来的本机那一条；nil 表示库里没有。
        var local: SubscriptionDraft?
        var matchKind: MatchKind?
        var decision: Decision
        /// 默认建议：用户没改的时候按它算。
        var suggested: Decision
        /// 文件里自己和自己对上（同编号、同内容、或两行改同一条本机订阅）。
        /// 单独记一个布尔而不是靠 `reasons` 里的措辞去猜：说明会变，判据不能跟着变。
        var duplicatedInFile: Bool
        var reasons: [String]
        var diffs: [Diff]

        var isSelected: Bool { decision != .skip }
        var isBlocked: Bool { row.isBlocked }

        /// 这一行能选哪些处理法。读不出来的行只能先改字段，不能被「导」。
        var allowedDecisions: [Decision] {
            if row.isBlocked { return [.skip] }
            guard let local else { return [.create, .skip] }
            // 编号撞上了：新建这条路径根本走不通（唯一约束会静默覆盖）。
            if matchKind == .stableID, local.id == row.draft.id { return [.update, .skip] }
            return [.create, .update, .skip]
        }

        /// 界面上一眼要看到的结论：这一行会被怎么处理、为什么。
        var headline: String {
            if row.isBlocked { return "先修好这 \(row.issues.count) 个问题" }
            if let matchKind { return "\(decision.title)（\(matchKind.rawValue)）" }
            return decision.title
        }
    }

    /// 预估的最终写入数量。§3.2 要求确认前就能看见。
    struct Projection: Equatable {
        var total = 0
        var creates = 0
        var updates = 0
        var skips = 0
        var blocked = 0
        var events = 0

        var summaryText: String {
            var parts = ["共 \(total) 行"]
            parts.append(isNothingSelected ? "一条都不导" : "新增 \(creates) 条、更新 \(updates) 条")
            if skips > 0 { parts.append("跳过 \(skips) 条") }
            if blocked > 0 { parts.append("其中 \(blocked) 条要先纠错") }
            if events > 0 { parts.append("带 \(events) 条历史事件") }
            return parts.joined(separator: "，")
        }

        var isNothingSelected: Bool { creates == 0 && updates == 0 }
    }

    struct Plan: Equatable {
        var items: [Item]
        /// 文件级说明 + 比对层面的整体结论。
        var notes: [String]

        var projection: Projection {
            var made = Projection(total: items.count)
            for item in items {
                if item.isBlocked { made.blocked += 1 }
                switch item.decision {
                case .create: made.creates += 1
                case .update: made.updates += 1
                case .skip: made.skips += 1
                }
                if item.decision != .skip { made.events += item.row.events.count }
            }
            return made
        }

        func setting(rowID: UUID, decision: Decision) -> Plan {
            var updated = self
            guard let index = updated.items.firstIndex(where: { $0.id == rowID }),
                  updated.items[index].allowedDecisions.contains(decision) else { return updated }
            updated.items[index].decision = decision
            return updated
        }

        /// 全选 / 取消全选：修不好的那些行不参与，勾上也导不进去，不如保持跳过。
        func setting(rows selected: Set<UUID>, _ shouldImport: Bool) -> Plan {
            var updated = self
            for index in updated.items.indices where selected.contains(updated.items[index].id) {
                guard updated.items[index].isBlocked == false else { continue }
                updated.items[index].decision = shouldImport
                    ? ImportConflictResolver.importableDecision(for: updated.items[index])
                    : .skip
            }
            return updated
        }

        func settingAll(_ shouldImport: Bool) -> Plan {
            setting(rows: Set(items.map(\.id)), shouldImport)
        }

        /// 修得好的那些行（读不出来的不在内：勾上也导不进去）。
        var importableItemCount: Int { items.filter { $0.isBlocked == false }.count }

        /// 「全选 / 取消全选」这颗按钮该写哪个词。
        var isEverythingSelected: Bool {
            importableItemCount > 0 && items.filter { $0.isBlocked == false }.allSatisfy { $0.isSelected }
        }

        /// 和本机对得上的行数（含文件里自己撞车的），预览的分栏数字要对得上栏里的内容。
        var duplicateItemCount: Int {
            items.filter { $0.isBlocked == false && ($0.matchKind != nil || $0.duplicatedInFile) }.count
        }

        /// 预览页的分栏：几百行的清单里人要找的只有「读不出来」和「和本机对得上」那两类，
        /// 所以按这个顺序排，空栏不占地方。
        var previewSections: [PreviewSection] {
            SectionKind.allCases.compactMap { kind in
                let members = items.filter { kind.contains($0) }
                return members.isEmpty ? nil : PreviewSection(kind: kind, items: members)
            }
        }

        /// 要落库的东西，顺序和预览里看到的一致。
        var writes: [SubscriptionRepository.ImportWrite] {
            items.compactMap { item in
                switch item.decision {
                case .skip:
                    return nil
                case .create:
                    return SubscriptionRepository.ImportWrite(draft: item.row.draft,
                                                              createdAt: item.row.createdAt,
                                                              events: item.row.events)
                case .update:
                    guard let local = item.local else { return nil }
                    return SubscriptionRepository.ImportWrite(draft: merged(item.row, into: local),
                                                              createdAt: nil,
                                                              events: item.row.events)
                }
            }
        }

    }

    /// 预览页的分栏种类。措辞直接上界面，所以按给用户看的话来写。
    enum SectionKind: String, CaseIterable, Identifiable {
        case needsFix = "要先纠错"
        case mayDuplicate = "和本机对得上"
        case fresh = "本机没有的"

        var id: String { rawValue }

        var footnote: String {
            switch self {
            case .needsFix:
                return "这几行有读不出来的字段，改好之前不会写进库。点「改字段」就能当场修。"
            case .mayDuplicate:
                return "默认跳过：本机已经有一条对得上的，未经你勾选不会动它。要按文件里的值覆盖，选中这一行。"
            case .fresh:
                return "本机没有对得上的记录，默认都导进来。不想导的行点一下就跳过。"
            }
        }

        func contains(_ item: Item) -> Bool {
            switch self {
            case .needsFix: return item.isBlocked
            case .mayDuplicate: return item.isBlocked == false && (item.matchKind != nil || item.duplicatedInFile)
            case .fresh: return item.isBlocked == false && item.matchKind == nil && item.duplicatedInFile == false
            }
        }
    }

    struct PreviewSection: Identifiable {
        var kind: SectionKind
        var items: [Item]
        var id: String { kind.rawValue }
    }

    /// 一行「能被导」时该走哪条路：本机有对应记录就是更新，没有就是新增。
    static func importableDecision(for item: Item) -> Decision {
        item.local == nil ? .create : .update
    }

    /// 这一行的「更新」会真的改掉本机已有的数（不是同一条记录、而且字段确有差异）。
    /// 预览页用它决定确认前要不要再问一遍：一键全选能把几十条同名订阅的数字全换掉，
    /// 那一下必须说得出改了些什么。编号相同的那条本来就是同一个东西，覆盖它是导入的本意。
    static func willChangeLocalValues(_ item: Item) -> Bool {
        item.decision == .update && item.matchKind != .stableID && item.diffs.isEmpty == false
    }

    /// 把文件里带了的东西盖到本机那条上；文件没带的字段一条都不动。
    static func merged(_ row: ImportParser.Row, into local: SubscriptionDraft) -> SubscriptionDraft {
        // 旧版 JSON 导出本来就是这条订阅的完整快照，整份覆盖才是它该有的意思。
        if row.carriesWholeRecord {
            var whole = row.draft
            whole.id = local.id
            return whole
        }
        var mergedDraft = local
        let present = row.presentFields
        if present.contains(.name) { mergedDraft.name = row.draft.name }
        if present.contains(.amount) { mergedDraft.priceMinorUnits = row.draft.priceMinorUnits }
        if present.contains(.currency) { mergedDraft.currencyCode = row.draft.currencyCode }
        if present.contains(.cycle) {
            mergedDraft.cycle = row.draft.cycle
            mergedDraft.customMonths = row.draft.customMonths
        }
        if present.contains(.startDate) { mergedDraft.startDate = row.draft.startDate }
        if present.contains(.category) { mergedDraft.category = row.draft.category }
        // 附加列：文件给了值才覆盖，空值等于「这一列没写」。
        if row.presentExtras.contains(.plan) { mergedDraft.plan = row.base.plan }
        if row.presentExtras.contains(.notes) { mergedDraft.notes = row.base.notes }
        if row.presentExtras.contains(.paymentMethod) { mergedDraft.paymentMethod = row.base.paymentMethod }
        if row.presentExtras.contains(.state) { mergedDraft.state = row.base.state }
        mergedDraft.id = local.id
        return mergedDraft
    }

    // MARK: - 比对

    static func resolve(table: ImportParser.Table, local: [SubscriptionDraft]) -> Plan {
        let localByID = Dictionary(local.map { ($0.id, $0) }) { first, _ in first }
        let localByName = Dictionary(local.map { (nameKey($0.name), $0) }) { first, _ in first }
        var claimedStableID: [UUID: String] = [:]
        var claimedContent: [String: String] = [:]
        var claimedLocal: [UUID: String] = [:]
        var items: [Item] = []

        for row in table.rows {
            var reasons: [String] = []
            var kind: MatchKind?
            var match: SubscriptionDraft?
            var duplicatedInFile = false

            // 1. 稳定编号优先：它比名字可靠得多，撞上就是同一条。
            if let stableID = row.stableID, let hit = localByID[stableID] {
                match = hit
                kind = .stableID
                reasons.append("本机已经有一条编号相同的订阅（\(hit.name)），默认按更新处理")
            }
            // 2. 没有编号就按名字找候选；名字相同、金额币种周期也相同 → 内容一致。
            if match == nil, let hit = localByName[nameKey(row.draft.name)], nameKey(row.draft.name).isEmpty == false {
                match = hit
                kind = isSameRecord(hit, row.draft) ? .sameContent : .sameName
                if kind == .sameContent {
                    reasons.append("本机已经有一条一模一样的（\(hit.name)），默认不重复导")
                } else {
                    reasons.append("本机有一条同名的订阅（\(hit.name)），数字不一样。要用文件里的值覆盖，得你亲自选中「更新本机这条」")
                }
            }

            // 3. 文件内部自己撞车：同一个编号 / 同样内容出现两次，或者两行改同一条本机订阅。
            //    这些一律默认跳过 —— 都写的话后一条会静默盖掉前一条，等于凭空丢一行。
            if let stableID = row.stableID, let earlier = claimedStableID[stableID] {
                reasons.append("文件里\(earlier)也是这个编号，两条只导一条")
                duplicatedInFile = true
            }
            if let stableID = row.stableID { claimedStableID[stableID] = row.sourceLabel }
            let contentKey = recordKey(row.draft)
            if let earlier = claimedContent[contentKey] {
                reasons.append("文件里\(earlier)和本行内容一致，第二条按重复处理")
                duplicatedInFile = true
            }
            claimedContent[contentKey] = row.sourceLabel
            if let match, let earlier = claimedLocal[match.id] {
                reasons.append("本机这条已经被\(earlier)认领了，两行改同一条只会留下后写的，第二条建议跳过")
                duplicatedInFile = true
            }
            if let match { claimedLocal[match.id] = row.sourceLabel }

            // 默认建议要经得起「用户什么都不改直接点确认」：
            // 只有「本机没有」和「编号相同（就是同一条）」这两种情况可以自动写；
            // 内容一致、只认得出同名、文件里自己撞车的，都默认跳过，等人在预览里点头。
            var suggested: Decision
            if row.isBlocked || duplicatedInFile {
                suggested = .skip
            } else if match == nil {
                suggested = .create
            } else {
                suggested = kind == .stableID ? .update : .skip
            }

            let item = Item(id: row.id,
                            row: row,
                            local: match,
                            matchKind: kind,
                            decision: suggested,
                            suggested: suggested,
                            duplicatedInFile: duplicatedInFile,
                            reasons: reasons,
                            diffs: match == nil ? [] : diffs(of: row, against: match!,
                                                             categories: table.categories))
            items.append(item)
        }

        var notes = table.notes
        let blocked = items.filter { $0.isBlocked }.count
        if blocked > 0 { notes.append("有 \(blocked) 行读不出来，点进去改好字段才能导") }
        let sameContent = items.filter { $0.matchKind == .sameContent }.count
        if sameContent > 0 { notes.append("有 \(sameContent) 行和本机记录一模一样，默认不重复导") }
        let duplicated = items.filter { $0.duplicatedInFile }.count
        if duplicated > 0 { notes.append("文件里另有 \(duplicated) 行自己撞了车（同编号或同内容），默认只导先出现的那条") }
        let sameName = items.filter { $0.matchKind == .sameName }.count
        if sameName > 0 { notes.append("有 \(sameName) 行只认得出同名订阅，默认跳过；要覆盖请在预览里选中「更新本机这条」") }
        return Plan(items: items, notes: notes)
    }

    /// 用户在预览里改了某一行的字段之后重新比对。
    ///
    /// 行 id 在 `Table.editing` 里保持不变，所以已经点过的选择要留住 —— 改一个字段
    /// 不该把另外 200 行的勾选清空。两种情况例外：没点过的行跟着新的默认建议走
    /// （读不出来的行本来就是被迫跳过，修好了就该回到它该有的建议上），
    /// 以及新状态不允许那个选择（比如编号撞上了就没有「新建」这条路）。
    static func reresolve(table: ImportParser.Table,
                          local: [SubscriptionDraft],
                          previous: Plan) -> Plan {
        var next = resolve(table: table, local: local)
        let before = Dictionary(previous.items.map { ($0.id, $0) }) { first, _ in first }
        for index in next.items.indices {
            guard let old = before[next.items[index].id], old.decision != old.suggested else { continue }
            if next.items[index].allowedDecisions.contains(old.decision) {
                next.items[index].decision = old.decision
            }
        }
        return next
    }

    /// 名字相同但数字不同时，把差异列出来 —— 用户要确认的就是这几个数。
    /// 分类要按名字说：本机存的是 UUID，直接印出来就是一串没人看得懂的字符。
    static func diffs(of row: ImportParser.Row,
                      against local: SubscriptionDraft,
                      categories: [SubscriptionCategory] = []) -> [Diff] {
        let incoming = row.draft
        var made: [Diff] = []
        if row.presentFields.contains(.name), nameKey(incoming.name) != nameKey(local.name) {
            made.append(Diff(field: .name, localText: local.name, incomingText: incoming.name))
        }
        if row.presentFields.contains(.amount), incoming.priceMinorUnits != local.priceMinorUnits {
            made.append(Diff(field: .amount,
                             localText: Money(minorUnits: local.priceMinorUnits, currencyCode: local.currencyCode).amountText,
                             incomingText: Money(minorUnits: incoming.priceMinorUnits, currencyCode: incoming.currencyCode).amountText))
        }
        if row.presentFields.contains(.currency), incoming.currencyCode != local.currencyCode {
            made.append(Diff(field: .currency, localText: local.currencyCode, incomingText: incoming.currencyCode))
        }
        if row.presentFields.contains(.cycle), cycleKey(incoming) != cycleKey(local) {
            made.append(Diff(field: .cycle, localText: cycleText(local), incomingText: cycleText(incoming)))
        }
        if row.presentFields.contains(.startDate),
           BillingMath.calendar.startOfDay(for: incoming.startDate) != BillingMath.calendar.startOfDay(for: local.startDate) {
            made.append(Diff(field: .startDate,
                             localText: QJFormat.longDate(local.startDate),
                             incomingText: QJFormat.longDate(incoming.startDate)))
        }
        if row.presentFields.contains(.category), incoming.category != local.category {
            made.append(Diff(field: .category,
                             localText: categoryName(local.category, in: categories),
                             incomingText: categoryName(incoming.category, in: categories)))
        }
        return made
    }

    /// 认不出的分类 id 也要说得出话：校验阶段已经把它落到「其他」，这里跟着落一次。
    private static func categoryName(_ id: String, in categories: [SubscriptionCategory]) -> String {
        if let hit = categories.first(where: { $0.id == id }) { return hit.name }
        if id == DefaultCategories.fallback.id { return DefaultCategories.fallback.name }
        return id
    }

    private static func nameKey(_ text: String) -> String {
        ImportParser.normalizeHeader(text)
    }

    private static func cycleKey(_ draft: SubscriptionDraft) -> String {
        draft.cycle == .custom ? "\(draft.cycle.rawValue):\(max(draft.customMonths, 1))" : draft.cycle.rawValue
    }

    private static func cycleText(_ draft: SubscriptionDraft) -> String {
        draft.cycle == .custom ? "每 \(max(draft.customMonths, 1)) 个月" : draft.cycle.title
    }

    /// 「同一条记录」的判据：名字 + 金额 + 币种 + 周期。
    /// 日期不参与 —— 从别的账本导出来时起始日期常被改成「今天」，那也该算重复。
    private static func isSameRecord(_ local: SubscriptionDraft, _ incoming: SubscriptionDraft) -> Bool {
        nameKey(local.name) == nameKey(incoming.name)
            && local.priceMinorUnits == incoming.priceMinorUnits
            && local.currencyCode == incoming.currencyCode
            && cycleKey(local) == cycleKey(incoming)
    }

    private static func recordKey(_ draft: SubscriptionDraft) -> String {
        "\(nameKey(draft.name))|\(draft.priceMinorUnits)|\(draft.currencyCode)|\(cycleKey(draft))"
    }
}
