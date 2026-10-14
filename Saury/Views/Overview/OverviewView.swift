import SwiftUI
import SwiftData
import os

/// 总览页。从上到下：月/季/年总额、待付款、即将扣费、试用中、分类支出、
/// 扣费日历、支出趋势、累计花费、快览（月均 / 平均每个）。面板可在设置里隐藏或排序。
struct OverviewView: View {
    /// 这一页的导航栈由根视图持有：换 Tab 再换回来， push 出去的那一页还在。
    @Binding var path: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var preferences: SubPreferences
    @EnvironmentObject private var sheets: SheetRouter
    @Query private var subscriptions: [Subscription]
    @Query private var events: [SubscriptionEvent]

    enum Route: Hashable {
        case calendar
        case categories
        case totalPaid
    }

    @State private var period: SubscriptionStats.StatsPeriod = .month
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                if activeSubscriptions.isEmpty {
                    emptyState
                    demoDonut
                        .transition(.opacity)
                } else {
                    panels
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            // 示例数据落地 / 首笔订阅保存时，空态和面板之间要淡入交接而不是硬切。
            .animation(Motion.page, value: activeSubscriptions.isEmpty)
            .padding(.horizontal, SauryTheme.screen)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(SauryTheme.background)
#if DEBUG
        .task { await runPeriodProbeIfNeeded() }
        .task { await runChartProbeIfNeeded() }
#endif
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .calendar: SubscriptionCalendarView(stats: stats)
            case .categories: CategoryBreakdownView(stats: stats)
            case .totalPaid: TotalPaidView(stats: stats)
            }
        }
    }

    private var activeSubscriptions: [Subscription] {
        subscriptions.filter { $0.deletedAt == nil && $0.archivedAt == nil }
    }

    private var stats: SubscriptionStats {
        SubscriptionStats(
            subscriptions: subscriptions,
            events: events,
            defaultCurrency: preferences.defaultCurrency,
            rates: ExchangeRateStore.shared.rates
        )
    }

    // MARK: - 头部

    private var header: some View {
        let total = stats.periodChargeTotal(for: period)
        return VStack(alignment: .leading, spacing: 4) {
            PeriodToggle(selection: $period)
                .padding(.bottom, 10)

            Text(period.longTitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .staged(0)
            AnimatedNumber(value: total.majorValue,
                           format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                           currencyCode: total.currencyCode).formattedGrouped },
                           font: SauryTheme.amountFont(size: 40),
                           countsFromZeroOnAppear: true)
                .foregroundStyle(.primary)
                .staged(1, delay: 0.05)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(Motion.ui, value: subtitle)
                .staged(2, delay: 0.1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let count = activeSubscriptions.count
        guard count > 0 else { return "还没有订阅，先添加一笔" }
        let phrases = ["刚刚启程，慢慢添置", "精挑细选，够用就好", "都是常用的，继续观察", "账单平稳，一切尽在掌握"]
        let phrase = phrases[min(count - 1, phrases.count - 1)]
        return "共 \(count) 笔订阅 · \(phrase)"
    }

    // MARK: - 面板

    @ViewBuilder
    private var panels: some View {
        let ordered = preferences.panelOrder.filter { !preferences.hiddenPanels.contains($0) }
        ForEach(Array(ordered.enumerated()), id: \.element) { index, panel in
            panelView(panel)
                .staged(index + 3)
        }
    }

    @ViewBuilder
    private func panelView(_ panel: OverviewPanel) -> some View {
        switch panel {
        case .pendingPayment: pendingPaymentPanel
        case .upcoming: upcomingPanel
        case .trial: trialPanel
        case .categoryBreakdown: categoryPanel
        case .calendar: calendarPanel
        case .trend: trendPanel
        case .totalPaid: totalPaidPanel
        case .quickView: quickViewPanel
        }
    }

    /// 待付款：手动续费、真有下一笔应付日期的。自动续费的到点自己扣，不算待付款。
    private var pendingPaymentPanel: some View {
        let due = SubscriptionQuery.awaitingPayment(activeSubscriptions)
        return PanelCard(title: "待付款") {
            if due.isEmpty {
                panelEmptyText("没有需要手动付款的订阅")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(due.prefix(3).enumerated()), id: \.element.id) { index, item in
                        let settle = BillingMath.nextChargeDate(for: item)
                        scheduledRow(item,
                                     caption: settle.map { "\(QJFormat.shortDate($0)) 应付款" } ?? "手动续费") {
                            sheets.present(.detail(item.id))
                        }
                        .staged(index, delay: 0.1)
                    }
                    if due.count > 3 {
                        Text("还有 \(due.count - 3) 条待付款")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 试用中：开始日还在将来的那几条 —— 先订下、到日子才生效的。
    /// 我方没有独立的试用期字段，面板名沿用竞品清单；空态和小字里把口径写清楚。
    private var trialPanel: some View {
        let pending = SubscriptionQuery.notStarted(activeSubscriptions)
        return PanelCard(title: "试用中") {
            if pending.isEmpty {
                panelEmptyText("没有还没开始的订阅")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(pending.prefix(3).enumerated()), id: \.element.id) { index, item in
                        scheduledRow(item,
                                     caption: "\(QJFormat.shortDate(item.startDate)) 开始 · \(QJFormat.countdown(item.startDate))") {
                            sheets.present(.detail(item.id))
                        }
                        .staged(index, delay: 0.1)
                    }
                    if pending.count > 3 {
                        Text("还有 \(pending.count - 3) 条还没开始")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 待付款 / 试用中两个面板的公共行：图标、名字、一行小字说明、右侧金额。点一行看详情。
    private func scheduledRow(_ subscription: Subscription,
                              caption: String,
                              onSelect: @escaping () -> Void) -> some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                SubscriptionIconView(subscription: subscription, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subscription.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(subscription.myAmount.formattedGrouped)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98))
    }

    private var upcomingPanel: some View {
        PanelCard(title: "即将扣费", showsChevron: true, onTap: { path.append(Route.calendar) }) {
            UpcomingChargeCarousel(charges: stats.upcomingCharges(limit: 12)) { charge in
                sheets.present(.detail(charge.subscription.id))
            }
        }
    }

    private var categoryPanel: some View {
        PanelCard(title: "支出分类", showsChevron: true, onTap: { path.append(Route.categories) }) {
            let slices = stats.categorySlices(preferences: preferences.categories)
            if slices.isEmpty {
                Text("还没有可统计的支出")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                HStack(spacing: 20) {
                    DonutChart(
                        slices: slices.map { .init(id: $0.id, value: $0.share, color: $0.category.color) },
                        centerText: stats.recurringTotal().formattedGrouped,
                        lineWidth: 18,
                        size: 104
                    )
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(slices.prefix(4)) { slice in
                            HStack(spacing: 8) {
                                Circle().fill(slice.category.color).frame(width: 7, height: 7)
                                Text(slice.category.name).font(.subheadline)
                                Spacer()
                                Text("\(Int((slice.share * 100).rounded()))%")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var calendarPanel: some View {
        PanelCard(title: "订阅日历", showsChevron: true, onTap: { path.append(Route.calendar) }) {
            MiniCalendarPanel(stats: stats)
        }
    }

    private var trendPanel: some View {
        PanelCard(title: "支出趋势", trailing: {
            AnyView(
                HStack(spacing: 10) {
                    trendBadge
                    Button {
                        preferences.trendChartStyle = preferences.trendChartStyle == .bars ? .line : .bars
                    } label: {
                        Image(systemName: preferences.trendChartStyle == .bars ? "chart.line.uptrend.xyaxis" : "chart.bar.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            )
        }) {
            switch preferences.trendChartStyle {
            case .bars:
                BarsChart(bars: stats.trendBars())
                    .frame(height: 130)
            case .line:
                LineChart(points: stats.trendBars().map { .init(id: $0.id, label: $0.label, value: $0.value, highlighted: $0.highlighted) })
                    .frame(height: 130)
            }
        }
    }

    /// 「较上月 +12%」这样的小胶囊；上月没花就没有比较。
    private var trendBadge: AnyView? {
        let bars = stats.trendBars()
        guard bars.count >= 2, let last = bars.last, let previous = bars.dropLast().last,
              previous.value > 0 else { return nil }
        let delta = (last.value - previous.value) / previous.value
        let text = delta >= 0 ? "+\(Int((delta * 100).rounded()))%" : "-\(Int((-delta * 100).rounded()))%"
        return AnyView(
            Text("较上月 \(text)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        )
    }

    private var totalPaidPanel: some View {
        PanelCard(title: "累计支付", showsChevron: true, onTap: { path.append(Route.totalPaid) }) {
            let totals = stats.cumulative()
            VStack(alignment: .leading, spacing: 10) {
                AnimatedNumber(value: totals.combined.majorValue,
                               format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                               currencyCode: totals.combined.currencyCode).formattedGrouped },
                               font: SauryTheme.amountFont(size: 26),
                               countsFromZeroOnAppear: true)
                // 合计里有多少是真登记过的，得一眼能看出来。
                Text("已登记 \(totals.recorded.formattedGrouped) · 预计 \(totals.projectedPast.formattedGrouped)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("覆盖 \(totals.perSubscription.count) 个订阅 · 共 \(totals.chargeCount) 笔")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.ui, value: "\(totals.perSubscription.count)-\(totals.chargeCount)")
                if !totals.perSubscription.isEmpty {
                    Divider().overlay(SauryTheme.line)
                    ForEach(Array(totals.perSubscription.prefix(3).enumerated()), id: \.element.subscription.id) { index, entry in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                            SubscriptionIconView(subscription: entry.subscription, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.subscription.name).font(.subheadline)
                                Text(entry.isAllProjected
                                     ? "预计 \(entry.projectedCount) 期"
                                     : "已登记 \(entry.recordedCount) 次 · 预计 \(entry.projectedCount) 期")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.total.formattedGrouped)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        .staged(index, delay: 0.1)
                    }
                }
            }
        }
    }

    /// 快览：月均 / 平均每个。设置里开了「快览（文字模式）」会收成一行字。
    /// 原先是永远挂在面板末尾的两块，现在按竞品清单升成正式面板 —— 可以隐藏、可以排序。
    private var quickViewPanel: some View {
        PanelCard(title: "快览") {
            let totals = stats.cumulative()
            if preferences.compactStats {
                Text("月均 \(totals.monthlyAverage.formattedGrouped) · 平均每个 \(totals.perSubscriptionAverage.formattedGrouped)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    quickStat(title: "月均", money: totals.monthlyAverage, caption: "全部摊到每月")
                    Divider().overlay(SauryTheme.line)
                    quickStat(title: "平均每个", money: totals.perSubscriptionAverage, caption: "每个订阅 · 月")
                }
            }
        }
    }

    private func quickStat(title: String, money: Money, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            AnimatedNumber(value: money.majorValue,
                           format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                           currencyCode: money.currencyCode).formattedGrouped },
                           font: SauryTheme.amountFont(size: 22),
                           countsFromZeroOnAppear: true)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func panelEmptyText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("还没有订阅")
                .font(.headline)
            Text("添加你的第一个订阅，这里会显示完整支出概览。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                sheets.present(.add(prefill: .empty))
            } label: {
                Label("添加订阅", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color(hex: preferences.accentHex) ?? .accentColor))
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .sauryCard()
    }

    private var demoDonut: some View {
        VStack(spacing: 14) {
            DonutChart(
                slices: [
                    .init(id: "a", value: 45, color: Palette.color("#0A84FF")),
                    .init(id: "b", value: 30, color: Palette.color("#BF5AF2")),
                    .init(id: "c", value: 25, color: Palette.color("#98989D"))
                ],
                centerText: "¥131",
                size: 128
            )
            Text("花销清楚，隐私安心")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("月 / 季 / 年支出、分类占比看得明明白白；数据只存在你的设备上，不上传任何服务器。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .sauryCard()
    }

    #if DEBUG
    private static let probeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")

    /// 图表连续更新（§8.4）：把「支出分类」和「支出趋势」两块临时排到最上面，让它们在同一屏里，
    /// 然后按真的周期切换和柱/线切换各来一遍。
    /// 走的全是用户那三条路：`preferences.panelOrder`（设置里就是拖这个）、
    /// `withAnimation(Motion.ui) { period = … }`（`PeriodToggle` 那一句）、
    /// `preferences.trendChartStyle`（面板右上角那个图标）。收尾把偏好放回原样。
    private func runChartProbeIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-chart") else { return }
        let orderBefore = preferences.panelOrder
        let styleBefore = preferences.trendChartStyle
        try? await Task.sleep(for: .milliseconds(1600))
        ProbeMarker.shared.mark("图表 起步 减少动态效果=\(reduceMotion) 面板=\(panelTitles(orderBefore))")
        withAnimation(Motion.ui) {
            preferences.panelOrder = [.categoryBreakdown, .trend] + OverviewPanel.allCases.filter {
                $0 != .categoryBreakdown && $0 != .trend
            }
        }
        try? await Task.sleep(for: .milliseconds(1200))
        for (next, gap) in [(SubscriptionStats.StatsPeriod.year, 2.2),
                            (.quarter, 2.2),
                            (.month, 2.4)] {
            let slices = stats.categorySlices(preferences: preferences.categories).count
            Self.probeLogger.log("图表探针 周期→\(next.title, privacy: .public) 分类数=\(slices) 柱数=\(stats.trendBars().count)")
            SelectionHaptics.tick()
            withAnimation(Motion.ui) { period = next }
            try? await Task.sleep(for: .milliseconds(Int(gap * 1000)))
        }
        // 柱 ↔ 线：同一份数据换一种画法，两边的生长/形变都要跟着。
        withAnimation(Motion.ui) { preferences.trendChartStyle = .line }
        Self.probeLogger.log("图表探针 切到折线")
        try? await Task.sleep(for: .milliseconds(1400))
        SelectionHaptics.tick()
        withAnimation(Motion.ui) { period = .quarter }
        try? await Task.sleep(for: .milliseconds(2200))
        withAnimation(Motion.ui) { preferences.trendChartStyle = .bars }
        Self.probeLogger.log("图表探针 切回柱状")
        try? await Task.sleep(for: .milliseconds(1400))
        withAnimation(Motion.ui) { preferences.panelOrder = orderBefore }
        preferences.trendChartStyle = styleBefore
        ProbeMarker.shared.mark("图表 收尾 偏好已放回 周期=\(period.title)")
    }

    private func panelTitles(_ order: [OverviewPanel]) -> String {
        order.map(\.title).joined(separator: "/")
    }

    /// 周期连点：月 → 季 → 年 来回切，间隔 240ms，比一轮数字滚动（620ms）短。
    /// 于是后一次切换一定打在前一次还没数完的时候（§9.2「数据更新时立即切换统计周期」），
    /// 而每一次都走 `PeriodToggle` 按钮里那同一句 `withAnimation(Motion.ui) { selection = period }`。
    /// 日志先把**该屏应落到的那个合计**打出来，录屏最后一帧再和它对账。
    private func runPeriodProbeIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-period") else { return }
        try? await Task.sleep(for: .milliseconds(1600))
        ProbeMarker.shared.mark("周期 起步 选中 \(period.title)")
        let script: [(SubscriptionStats.StatsPeriod, Double)] = [
            (.quarter, 0.24), (.year, 0.24), (.month, 1.4),
            (.year, 0.12), (.month, 0.12), (.year, 0.12), (.month, 2.2),
        ]
        for (next, gap) in script {
            let total = stats.periodChargeTotal(for: next)
            let line = "→ \(next.title) 应落合计 \(String(format: "%.2f", total.majorValue))（切换前选中 \(period.title)）"
            Self.probeLogger.log("周期探针 \(line, privacy: .public)")
            SelectionHaptics.tick()
            withAnimation(Motion.ui) { period = next }
            try? await Task.sleep(for: .milliseconds(Int(gap * 1000)))
        }
        let settled = stats.periodChargeTotal(for: period)
        let last = "收尾 选中 \(period.title) 真值 \(String(format: "%.2f", settled.majorValue))"
        ProbeMarker.shared.mark("周期 \(last)")
    }
    #endif
}

/// 月 / 季 / 年 切换胶囊。
struct PeriodToggle: View {
    @Binding var selection: SubscriptionStats.StatsPeriod

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SubscriptionStats.StatsPeriod.allCases, id: \.self) { period in
                Button {
                    guard selection != period else { return }
                    SelectionHaptics.tick()
                    withAnimation(Motion.ui) { selection = period }
                } label: {
                    Text(period.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == period ? .primary : .secondary)
                        .scaleEffect(selection == period ? 1 : 0.96)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background {
                            if selection == period {
                                Capsule(style: .continuous)
                                    .fill(SauryTheme.surfaceElevated)
                                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "periodPill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .animation(Motion.ui, value: selection)
            }
        }
        .padding(3)
        .background(Capsule().fill(SauryTheme.surface))
    }
}

/// 总览面板的壳：灰字标题 + 右上箭头 + 内容。
struct PanelCard<Content: View>: View {
    let title: String
    var showsChevron: Bool
    var trailing: (()) -> AnyView?
    var onTap: (() -> Void)?
    @ViewBuilder let content: Content

    init(
        title: String,
        showsChevron: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) where Content: View {
        self.title = title
        self.showsChevron = showsChevron
        self.onTap = onTap
        self.trailing = { _ in nil }
        self.content = content()
    }

    init(
        title: String,
        showsChevron: Bool = false,
        onTap: (() -> Void)? = nil,
        trailing: @escaping (()) -> AnyView?,
        @ViewBuilder content: () -> Content
    ) where Content: View {
        self.title = title
        self.showsChevron = showsChevron
        self.onTap = onTap
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailingView = trailing(()) {
                    trailingView
                } else if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(16)
        .sauryCard()
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}
