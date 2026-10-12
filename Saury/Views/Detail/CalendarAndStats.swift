import SwiftUI
import SwiftData

/// 订阅日历详情：月视图 / 全年视图切换，点某天看当天扣费。
struct SubscriptionCalendarView: View {
    let stats: SubscriptionStats

    enum Mode: Hashable { case month, year }

    @State private var mode: Mode = .month
    @State private var month = Date()
    @State private var monthDirection = 1
    @State private var selectedDay: Date?
    @Namespace private var modePill

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                modeSwitcher
                if mode == .month {
                    monthPane
                        .transition(.directionalSlide(monthDirection, distance: 30))
                }
                if mode == .year {
                    yearPane
                        .transition(.directionalSlide(monthDirection, distance: 30))
                }
            }
            .padding(.horizontal, SauryTheme.screen)
            .padding(.bottom, 24)
        }
        .background(SauryTheme.background)
        .navigationTitle("订阅日历")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("今天") {
                    monthDirection = 1
                    withAnimation(Motion.slide) {
                        month = Date()
                        selectedDay = Date()
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 0) {
            ForEach([(Mode.month, "月"), (Mode.year, "全年视图")], id: \.0) { item in
                Button {
                    SelectionHaptics.tick()
                    withAnimation(Motion.slide) { mode = item.0 }
                } label: {
                    Text(item.1)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(mode == item.0 ? Color(light: .black, dark: .white) : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if mode == item.0 {
                                Capsule(style: .continuous)
                                    .fill(SauryTheme.surfaceElevated)
                                    .matchedGeometryEffect(id: "calModePill", in: modePill)
                            }
                        }
                }
                .buttonStyle(Pressable(scale: 0.94))
            }
        }
        .padding(3)
        .background(Capsule().fill(SauryTheme.surface))
    }

    private var monthPane: some View {
        VStack(spacing: 12) {
            HStack {
                Button { moveMonth(-1) } label: {
                    Image(systemName: "chevron.left").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(Pressable(scale: 0.85))
                Spacer()
                VStack(spacing: 2) {
                    Text(QJFormat.yearMonth(month))
                        .font(.headline)
                        .contentTransition(.opacity)
                    let monthCharges = monthChargeCount
                    Text(monthCharges.count == 0 ? "本月没有扣费" : "\(monthCharges.count) 笔 · \(monthCharges.total.formatted)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button { moveMonth(1) } label: {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(Pressable(scale: 0.85))
            }
            Group {
                monthCard
                if let day = selectedDay, let charges = dayCharges(for: day) {
                    dayDetailCard(day: day, charges: charges)
                        .transition(.opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.97)))
                }
            }
            .id(month)
            // 月份是动态值，只能一张顶一张：旧月瞬间让位，所以新页几乎不淡出，
            // 否则起步那几帧会从卡片底下透出页面底色。
            .transition(.directionalSlide(monthDirection, distance: 44, fade: 0.15))
        }
    }

    private var monthChargeCount: (count: Int, total: Money) {
        let byDay = stats.chargesByDay(in: month)
        var count = 0
        var minor = 0
        let rates = ExchangeRateStore.shared.rates
        for charges in byDay.values {
            count += charges.count
            for charge in charges {
                minor += charge.amount.converting(to: stats.defaultCurrency, rates: rates).minorUnits
            }
        }
        return (count, Money(minorUnits: minor, currencyCode: stats.defaultCurrency))
    }

    private var monthCard: some View {
        VStack(spacing: 10) {
            CalendarMonthGrid(
                month: month,
                chargesByDay: stats.chargesByDay(in: month),
                iconProvider: { subscription in SubscriptionIconView(subscription: subscription, size: 24) },
                compact: false,
                selectedDay: selectedDay,
                onSelectDay: { day in
                    SelectionHaptics.tick()
                    withAnimation(Motion.ui) { selectedDay = day }
                }
            )
        }
        .padding(14)
        .sauryCard()
    }

    private func dayCharges(for day: Date) -> [SubscriptionStats.ScheduledCharge]? {
        let charges = stats.charges(on: day)
        return charges.isEmpty ? nil : charges
    }

    private func dayDetailCard(day: Date, charges: [SubscriptionStats.ScheduledCharge]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(QJFormat.shortDate(day)).font(.headline)
                    Text(QJFormat.weekdaySymbols[BillingMath.calendar.component(.weekday, from: day) - 1])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let rates = ExchangeRateStore.shared.rates
                let total = Money(
                    minorUnits: charges.reduce(0) { $0 + $1.amount.converting(to: stats.defaultCurrency, rates: rates).minorUnits },
                    currencyCode: stats.defaultCurrency
                )
                Text(total.formatted)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(Array(charges.enumerated()), id: \.element.id) { index, charge in
                Button {
                    // 点击进入详情由列表页承担；这里只做展示。
                } label: {
                    HStack(spacing: 10) {
                        SubscriptionIconView(subscription: charge.subscription, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(charge.subscription.name).font(.subheadline.weight(.medium))
                            Text(charge.subscription.cycleTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(charge.amount.formatted)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(CardPressable())
                .staged(index, delay: 0.12)
            }
        }
        .padding(14)
        .sauryCard()
    }

    private var yearPane: some View {
        let calendar = BillingMath.calendar
        let year = calendar.component(.year, from: month)
        return VStack(spacing: 12) {
            HStack {
                Button { month = calendar.date(byAdding: .year, value: -1, to: month) ?? month } label: {
                    Image(systemName: "chevron.left").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(String(year)).font(.headline)
                    Text("全年 \(yearChargeSummary.count) 笔 · \(yearChargeSummary.total.formatted)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { month = calendar.date(byAdding: .year, value: 1, to: month) ?? month } label: {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 12) {
                ForEach(1...12, id: \.self) { monthNumber in
                    yearMonthCard(year: year, monthNumber: monthNumber)
                        .staged(min(monthNumber - 1, 8), delay: 0.06)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
        }
    }

    private var yearChargeSummary: (count: Int, total: Money) {
        let calendar = BillingMath.calendar
        var count = 0
        var minor = 0
        let rates = ExchangeRateStore.shared.rates
        for monthNumber in 1...12 {
            var components = DateComponents()
            components.year = calendar.component(.year, from: month)
            components.month = monthNumber
            guard let monthDate = calendar.date(from: components) else { continue }
            for charges in stats.chargesByDay(in: monthDate).values {
                count += charges.count
                for charge in charges {
                    minor += charge.amount.converting(to: stats.defaultCurrency, rates: rates).minorUnits
                }
            }
        }
        return (count, Money(minorUnits: minor, currencyCode: stats.defaultCurrency))
    }

    private func yearMonthCard(year: Int, monthNumber: Int) -> some View {
        let calendar = BillingMath.calendar
        var components = DateComponents()
        components.year = year
        components.month = monthNumber
        let monthDate = calendar.date(from: components) ?? month
        let charges = stats.chargesByDay(in: monthDate)
        let isCurrent = calendar.isDate(monthDate, equalTo: Date(), toGranularity: .month)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(monthNumber)月")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                Spacer()
            }
            CalendarMonthGrid(
                month: monthDate,
                chargesByDay: charges,
                iconProvider: { _ in Color.clear.frame(width: 6, height: 6) },
                compact: true
            )
            .allowsHitTesting(false)
            .scaleEffect(0.8, anchor: .top)
            .frame(height: 96)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sauryCard(radius: 14)
    }

    private func moveMonth(_ delta: Int) {
        SelectionHaptics.tick()
        monthDirection = delta
        withAnimation(Motion.slide) {
            selectedDay = nil
            month = BillingMath.calendar.date(byAdding: .month, value: delta, to: month) ?? month
        }
    }
}

/// 支出分类详情：每个分类的月/年合计和它名下的订阅。
struct CategoryBreakdownView: View {
    let stats: SubscriptionStats

    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                let slices = stats.categorySlices(preferences: preferences.categories)
                ForEach(Array(slices.enumerated()), id: \.element.id) { position, slice in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(slice.category.name)
                                        .font(.headline)
                                    if slice.id == slices.first?.id {
                                        Text("👑").font(.caption)
                                    }
                                }
                                Text("全年 \(slice.yearly.formattedGrouped)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            AnimatedNumber(value: slice.monthly.majorValue,
                                           format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                                           currencyCode: slice.monthly.currencyCode).formatted },
                                           font: SauryTheme.amountFont(size: 20))
                        }
                        HStack {
                            Text("\(Int((slice.share * 100).rounded()))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(slice.category.color)
                            Spacer()
                        }
                        ForEach(slice.subscriptions) { subscription in
                            HStack(spacing: 10) {
                                SubscriptionIconView(subscription: subscription, size: 32)
                                Text(subscription.name).font(.subheadline)
                                Spacer()
                                Text(subscription.myAmount.formatted)
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .sauryCard()
                    .staged(min(position, 10))
                }
            }
            .padding(.horizontal, SauryTheme.screen)
            .padding(.bottom, 24)
        }
        .background(SauryTheme.background)
        .navigationTitle("支出分类")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 累计支付详情 + 小票。
struct TotalPaidView: View {
    let stats: SubscriptionStats

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var preferences: SubPreferences
    @Query private var subscriptions: [Subscription]

    @State private var showingReceipt = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                ForEach(Array(stats.cumulative().perSubscription.enumerated()), id: \.element.subscription.id) { index, entry in
                    rowCard(entry)
                        .staged(min(index, 10), delay: 0.12)
                }
            }
            .padding(.horizontal, SauryTheme.screen)
            .padding(.bottom, 24)
        }
        .background(SauryTheme.background)
        .navigationTitle("累计支付")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    SelectionHaptics.tick()
                    showingReceipt = true
                } label: {
                    Image(systemName: "printer")
                }
                .buttonStyle(Pressable(scale: 0.88))
            }
        }
        .sheet(isPresented: $showingReceipt) {
            ReceiptView(stats: stats)
        }
    }

    private var headerCard: some View {
        let cumulative = stats.cumulative()
        return VStack(spacing: 6) {
            Text("总累计")
                .font(.footnote)
                .foregroundStyle(.secondary)
            AnimatedNumber(value: cumulative.total.majorValue,
                           format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                           currencyCode: cumulative.total.currencyCode).formattedGrouped },
                           font: SauryTheme.amountFont(size: 34),
                           countsFromZeroOnAppear: true)
            Text("覆盖 \(cumulative.perSubscription.count) 个订阅 · 共 \(cumulative.chargeCount) 笔扣费")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .sauryCard()
    }

    private func rowCard(_ entry: (subscription: Subscription, count: Int, total: Money)) -> some View {
        HStack(spacing: 12) {
            SubscriptionIconView(subscription: entry.subscription, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.subscription.name).font(.subheadline.weight(.medium))
                Text("已扣 \(entry.count) 次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.total.formattedGrouped)
                .font(.subheadline.weight(.bold).monospacedDigit())
        }
        .padding(14)
        .sauryCard()
    }
}

/// 小票：一张能保存/分享的收据图。
struct ReceiptView: View {
    let stats: SubscriptionStats

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences

    @State private var rendered: UIImage?
    @State private var showShare = false
    @State private var printed = false

    private let receiptNumber = "SAURY-" + Self.stamp()
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMddHHmm"
        return formatter.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SauryTheme.background.ignoresSafeArea()
                ScrollView {
                    ReceiptCanvas(
                        stats: stats,
                        receiptNumber: receiptNumber,
                        accent: Color(hex: preferences.accentHex) ?? .accentColor
                    )
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                }
                // 小票从打印机里吐出来。
                .mask(alignment: .top) {
                    Rectangle().scaleEffect(y: printed ? 1 : 0.001, anchor: .top)
                }
                .onAppear {
                    withAnimation(Motion.chart) { printed = true }
                }
            }
            .navigationTitle("小票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        renderAndShare()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let rendered {
                    ActivityShareSheet(items: [rendered])
                }
            }
        }
    }

    private func renderAndShare() {
        SelectionHaptics.impact(.light)
        let canvas = ReceiptCanvas(
            stats: stats,
            receiptNumber: receiptNumber,
            accent: Color(hex: preferences.accentHex) ?? .accentColor
        )
        let renderer = ImageRenderer(content: canvas.frame(width: 320))
        renderer.scale = 3
        rendered = renderer.uiImage
        showShare = rendered != nil
    }
}

/// 收据纸面。
struct ReceiptCanvas: View {
    let stats: SubscriptionStats
    let receiptNumber: String
    let accent: Color

    var body: some View {
        let cumulative = stats.cumulative()
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                Text("QI JIAN")
                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    .tracking(6)
                Text("订阅消费小票")
                    .font(.system(size: 11, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)

            dashedLine
            infoRow("开票时间", QJFormat.longDate(Date()) + " " + timeText)
            dashedLine
            infoRow("小票号", receiptNumber)
            dashedLine

            HStack {
                Text("项目").font(.system(size: 11, design: .monospaced))
                Spacer()
                Text("金额").font(.system(size: 11, design: .monospaced))
            }
            .padding(.vertical, 6)

            ForEach(cumulative.perSubscription, id: \.subscription.id) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.subscription.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    HStack {
                        Text("× \(entry.count) 期")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.total.formatted)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                }
                .padding(.vertical, 5)
                dashedLine
            }

            HStack(alignment: .firstTextBaseline) {
                Text("合计")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                Spacer()
                Text(cumulative.total.formatted)
                    .font(.system(size: 16, weight: .heavy, design: .monospaced))
            }
            .padding(.vertical, 8)
            Text("共 \(cumulative.chargeCount) 笔扣费")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            BarcodeShape()
                .fill(.black)
                .frame(height: 40)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)

            Text("谢谢惠顾 · 仅供娱乐")
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity)
                .foregroundStyle(.secondary)
            Text("由 期见 生成")
                .font(.system(size: 9, design: .monospaced))
                .frame(maxWidth: .infinity)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(20)
        .background(Color(light: Color(white: 0.97), dark: Color(white: 0.93)))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .colorScheme(.light)
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    private var dashedLine: some View {
        DashedLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(Color(white: 0.75))
            .frame(height: 1)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced))
        }
        .padding(.vertical, 5)
    }
}

struct BarcodeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX
        var generator = SeededGenerator(seed: 42)
        while x < rect.maxX {
            let width = Double.random(in: 1.5...4, using: &generator)
            if Double.random(in: 0...1, using: &generator) > 0.45 {
                path.addRect(CGRect(x: x, y: rect.minY, width: width, height: rect.height))
            }
            x += width + Double.random(in: 1...3.5, using: &generator)
        }
        return path
    }
}

struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// 系统分享壳。
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
