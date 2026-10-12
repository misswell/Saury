import SwiftUI
import SwiftData

/// 总览页。从上到下：月/季/年总额、即将扣费、分类支出、扣费日历、
/// 支出趋势、累计花费、月均/平均每个。面板可在设置里隐藏或排序。
struct OverviewView: View {
    var onSelectTab: (MainTab) -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var preferences: SubPreferences
    @Query private var subscriptions: [Subscription]

    enum Route: Hashable {
        case calendar
        case categories
        case totalPaid
    }

    @State private var path = NavigationPath()
    @State private var period: SubscriptionStats.StatsPeriod = .month
    @State private var selectedSubscription: Subscription?
    @State private var editingSubscription: Subscription?
    @State private var showAdd = false

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
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .calendar: SubscriptionCalendarView(stats: stats)
            case .categories: CategoryBreakdownView(stats: stats)
            case .totalPaid: TotalPaidView(stats: stats)
            }
        }
        .sheet(item: $selectedSubscription) { subscription in
            SubscriptionDetailView(subscription: subscription) {
                editingSubscription = subscription
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingSubscription) { subscription in
            AddSubscriptionView(editing: subscription)
        }
        .sheet(isPresented: $showAdd) {
            AddSubscriptionView()
        }
    }

    private var activeSubscriptions: [Subscription] {
        subscriptions.filter { $0.deletedAt == nil && $0.archivedAt == nil }
    }

    private var stats: SubscriptionStats {
        SubscriptionStats(
            subscriptions: subscriptions,
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
        averagePanels
            .staged(ordered.count + 3)
    }

    @ViewBuilder
    private func panelView(_ panel: OverviewPanel) -> some View {
        switch panel {
        case .upcoming: upcomingPanel
        case .categoryBreakdown: categoryPanel
        case .calendar: calendarPanel
        case .trend: trendPanel
        case .totalPaid: totalPaidPanel
        }
    }

    private var upcomingPanel: some View {
        PanelCard(title: "即将扣费", showsChevron: true, onTap: { path.append(Route.calendar) }) {
            UpcomingChargeCarousel(charges: stats.upcomingCharges(limit: 12)) { charge in
                selectedSubscription = charge.subscription
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
            let cumulative = stats.cumulative()
            VStack(alignment: .leading, spacing: 10) {
                AnimatedNumber(value: cumulative.total.majorValue,
                               format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                               currencyCode: cumulative.total.currencyCode).formattedGrouped },
                               font: SauryTheme.amountFont(size: 26),
                               countsFromZeroOnAppear: true)
                Text("覆盖 \(cumulative.perSubscription.count) 个订阅 · 共 \(cumulative.chargeCount) 笔扣费")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.ui, value: "\(cumulative.perSubscription.count)-\(cumulative.chargeCount)")
                if !cumulative.perSubscription.isEmpty {
                    Divider().overlay(SauryTheme.line)
                    ForEach(Array(cumulative.perSubscription.prefix(3).enumerated()), id: \.element.subscription.id) { index, entry in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                            SubscriptionIconView(subscription: entry.subscription, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.subscription.name).font(.subheadline)
                                Text("已扣 \(entry.count) 次")
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

    /// 月均 / 平均每个：设置里开了「快览」会变成文字行，这里先做卡片形态。
    @ViewBuilder
    private var averagePanels: some View {
        if preferences.compactStats {
            let cumulative = stats.cumulative()
            Text("月均 \(cumulative.monthlyAverage.formattedGrouped) · 平均每个 \(cumulative.perSubscriptionAverage.formattedGrouped)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 12) {
                let cumulative = stats.cumulative()
                statCard(title: "月均", money: cumulative.monthlyAverage, caption: "全部摊到每月")
                statCard(title: "平均每个", money: cumulative.perSubscriptionAverage, caption: "每个订阅 · 月")
            }
        }
    }

    private func statCard(title: String, money: Money, caption: String) -> some View {
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
        .padding(14)
        .sauryCard()
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
                showAdd = true
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
