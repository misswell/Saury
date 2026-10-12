import SwiftUI
import SwiftData

/// 订阅详情。半高 sheet 弹出：状态、单价、下次扣费、花费、时间轴、其他。
struct SubscriptionDetailView: View {
    let subscription: Subscription
    var onEdit: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences
    @Query private var events: [SubscriptionEvent]

    @State private var showingEventEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                        .staged(0, edge: .top)
                    statusSection
                        .staged(1)
                    spendSection
                        .staged(2)
                    timelineSection
                        .staged(3)
                    otherSection
                        .staged(4)
                }
                .padding(.horizontal, SauryTheme.screen)
                .padding(.bottom, 30)
            }
            .background(SauryTheme.background)
            .navigationTitle("订阅详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 2) {
                        Button {
                            SelectionHaptics.tick()
                            onEdit()
                            dismiss()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color(hex: preferences.accentHex) ?? .accentColor))
                        }
                        .buttonStyle(Pressable(scale: 0.88, animation: Motion.pop))
                        Menu {
                            Button {
                                subscription.pinnedAt = subscription.isPinned ? nil : Date()
                                subscription.markUpdated()
                            } label: {
                                Label(subscription.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                            }
                            Button {
                                subscription.archivedAt = Date()
                                subscription.markUpdated()
                                dismiss()
                            } label: {
                                Label("归档", systemImage: "archivebox")
                            }
                            Button(role: .destructive) {
                                subscription.deletedAt = Date()
                                subscription.markUpdated()
                                dismiss()
                            } label: {
                                Label("移入回收站", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingEventEditor) {
                SubscriptionEventEditor(subscription: subscription)
                    .presentationDetents([.medium])
            }
        }
        #if DEBUG
        // 模拟器操作验证用（`-saury-ops`）：合成不了点击，就复刻「归档」按钮里那两行，
        // 让软删除真的写进库，再从数据库和截图外面核对。
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-saury-ops") else { return }
            try? await Task.sleep(for: .milliseconds(1000))
            subscription.archivedAt = Date()
            subscription.markUpdated()
        }
        #endif
    }

    private var relatedEvents: [SubscriptionEvent] {
        events
            .filter { $0.subscriptionID == subscription.id }
            .sorted { $0.happenedAt > $1.happenedAt }
    }

    // MARK: - 头部卡

    private var headerCard: some View {
        VStack(spacing: 10) {
            SubscriptionIconView(subscription: subscription, size: 64, onColorCard: true)
            Text(subscription.name)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 8) {
                chip(preferences.category(withID: subscription.categoryRawValue).name,
                     color: preferences.category(withID: subscription.categoryRawValue).color)
                chip(subscription.state.title, color: .white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            CardGradient(hexes: subscription.colorSpec.orderedHexes.isEmpty
                ? [IconTintHelper.hexFallback(for: subscription, preferences: preferences)]
                : subscription.colorSpec.orderedHexes)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.35)))
    }

    // MARK: - 状态

    private var statusSection: some View {
        SectionCard(title: "当前状态") {
            row("状态", value: subscription.state == .inactive ? "已停用" : "生效中")
            row("当前单价", value: priceText)
            if let next = BillingMath.nextChargeDate(for: subscription) {
                HStack {
                    Text("下次扣费").font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(QJFormat.longDate(next)).font(.subheadline.monospacedDigit())
                        Text(QJFormat.relativeDay(next))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                    }
                }
                .padding(.vertical, 9)
            }
            row("开始时间", value: QJFormat.longDate(subscription.startDate))
            if let end = subscription.endDate {
                row("结束于", value: QJFormat.longDate(end))
            }
            row("提前提醒", value: subscription.reminderDays > 0 ? "提前 \(subscription.reminderDays) 天" : "不提醒")
        }
    }

    private var priceText: String {
        let mine = subscription.myAmount
        let base = "\(mine.formatted)/\(cycleWord)"
        if preferences.showOriginalCurrency, mine.currencyCode != preferences.defaultCurrency {
            return base
        }
        return base
    }

    private var cycleWord: String {
        switch subscription.cycle {
        case .weekly: return "周"
        case .monthly: return "月"
        case .quarterly: return "季"
        case .semiannual: return "半年"
        case .yearly: return "年"
        case .custom: return "\(subscription.customMonths)月"
        case .oneTime: return "次"
        }
    }

    // MARK: - 花费

    private var spendSection: some View {
        SectionCard(title: "花费") {
            let cumulative = detailCumulative()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    AnimatedNumber(value: cumulative.total.majorValue,
                                   format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                                   currencyCode: cumulative.total.currencyCode).formattedGrouped },
                                   font: SauryTheme.amountFont(size: 24),
                                   countsFromZeroOnAppear: true)
                    Spacer()
                    Text("共 \(cumulative.count) 期")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                ForEach(Array(cumulative.periods.enumerated()), id: \.element.label) { index, period in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(priceLine) × \(period.count) 期")
                                .font(.subheadline)
                                .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                            Text(period.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(period.total.formatted)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .padding(.vertical, 7)
                    .staged(index, delay: 0.15)
                }
                if cumulative.periods.isEmpty {
                    Text("还没有发生扣费。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var priceLine: String {
        "\(subscription.myAmount.formatted)/\(cycleWord)"
    }

    private func detailCumulative() -> (total: Money, count: Int, periods: [(label: String, count: Int, total: Money)]) {
        let rates = ExchangeRateStore.shared.rates
        var buckets: [String: (count: Int, minor: Int)] = [:]
        var totalCount = 0
        var totalMinor = 0
        for event in relatedEvents where event.type == .charged {
            let amount = event.amount ?? subscription.myAmount
            let converted = amount.converting(to: preferences.defaultCurrency, rates: rates)
            let key = QJFormat.yearMonth(event.happenedAt)
            buckets[key, default: (0, 0)].count += 1
            buckets[key, default: (0, 0)].minor += converted.minorUnits
            totalCount += 1
            totalMinor += converted.minorUnits
        }
        // 手动没记过扣费时，把开始以来的计划扣费也计入「花费」——账面上的确花过。
        if totalCount == 0 {
            let calendar = BillingMath.calendar
            let dates = subscription.cycle.isRecurring
                ? BillingMath.chargeDates(for: subscription, from: subscription.startDate, to: Date())
                : (BillingMath.isStarted(subscription) ? [subscription.startDate] : [])
            for date in dates {
                let converted = subscription.myAmount.converting(to: preferences.defaultCurrency, rates: rates)
                let key = QJFormat.yearMonth(date)
                buckets[key, default: (0, 0)].count += 1
                buckets[key, default: (0, 0)].minor += converted.minorUnits
                totalCount += 1
                totalMinor += converted.minorUnits
            }
            _ = calendar
        }
        let periods = buckets
            .map { key, value in (label: key, count: value.count, total: Money(minorUnits: value.minor, currencyCode: preferences.defaultCurrency)) }
            .sorted { $0.label > $1.label }
        return (Money(minorUnits: totalMinor, currencyCode: preferences.defaultCurrency), totalCount, periods)
    }

    // MARK: - 时间轴

    private var timelineSection: some View {
        SectionCard(title: "时间轴", trailing: {
            AnyView(
                Button {
                    showingEventEditor = true
                } label: {
                    Label("添加事件", systemImage: "plus.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                }
            )
        }) {
            let list = relatedEvents
            if list.isEmpty {
                Text("还没有记录任何变更。调价、暂停、跳过几期、内购都可以记在这里，统计会跟着变。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element) { index, event in
                        HStack(spacing: 10) {
                            Image(systemName: event.type.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill((Color(hex: preferences.accentHex) ?? .accentColor).opacity(0.14)))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(event.type.title).font(.subheadline.weight(.medium))
                                    if let amount = event.amount {
                                        Text(amount.formatted)
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                    }
                                }
                                if !event.note.isEmpty {
                                    Text(event.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(QJFormat.shortDate(event.happenedAt))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    SelectionHaptics.impact(.medium)
                                    withAnimation(Motion.ui) { modelContext.delete(event) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 7)
                        .staged(min(index, 8), delay: 0.1)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .animation(Motion.ui, value: list.map { $0.id })
            }
        }
    }

    // MARK: - 其他

    private var otherSection: some View {
        SectionCard(title: "其他") {
            if !subscription.plan.isEmpty { row("套餐", value: subscription.plan) }
            if !subscription.paymentMethod.isEmpty { row("支付方式", value: subscription.paymentMethod) }
            if subscription.shareEnabled {
                row("拼车", value: shareText)
            }
            if !subscription.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("备注")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(subscription.notes)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SauryTheme.surfaceElevated))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var shareText: String {
        switch subscription.shareMode {
        case .even:
            return "\(subscription.shareHeadcount) 人均摊，我出 \(subscription.myAmount.formatted)/\(cycleWord)"
        case .custom:
            return "自定义份额 \(subscription.myAmount.formatted)/\(cycleWord)"
        }
    }

    @ViewBuilder
    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }
}

/// 详情页的小节壳。
struct SectionCard<Content: View>: View {
    let title: String
    var trailing: (() -> AnyView)?
    @ViewBuilder let content: Content

    init(title: String, trailing: (() -> AnyView)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                trailing?()
            }
            content
        }
        .padding(16)
        .sauryCard()
    }
}

/// 添加事件的小表单。
struct SubscriptionEventEditor: View {
    let subscription: Subscription

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var type: SubscriptionEventType = .charged
    @State private var amountText = ""
    @State private var note = ""
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $type) {
                    ForEach(SubscriptionEventType.allCases, id: \.self) { event in
                        Text(event.title).tag(event)
                    }
                }
                if type == .charged || type == .priceChanged || type == .inAppPurchase {
                    TextField("金额（\(subscription.currencyCode)）", text: $amountText)
                        .keyboardType(.decimalPad)
                }
                DatePicker("日期", selection: $date, displayedComponents: .date)
                TextField("备注（可选）", text: $note)
            }
            .navigationTitle("添加事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        var minor = 0
        if type == .charged || type == .priceChanged || type == .inAppPurchase {
            let normalized = amountText.replacingOccurrences(of: ",", with: ".")
            minor = Int(((Double(normalized) ?? 0) * 100).rounded())
        }
        let event = SubscriptionEvent(
            subscriptionID: subscription.id,
            type: type,
            amountMinorUnits: minor,
            currencyCode: minor != 0 ? subscription.currencyCode : "",
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            happenedAt: date
        )
        if type == .priceChanged, minor > 0 {
            subscription.priceMinorUnits = minor
        }
        modelContext.insert(event)
        subscription.markUpdated()
        SelectionHaptics.success()
        dismiss()
    }
}
