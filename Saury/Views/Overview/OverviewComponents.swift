import SwiftUI

/// 即将扣费的卡片堆叠轮播：当前卡可以横向拖走，下一张从后面浮起来归位。
/// 拖拽跟手、松手用弹簧定位，翻页时给一次触感。
struct UpcomingChargeCarousel: View {
    let charges: [SubscriptionStats.ScheduledCharge]
    var onSelect: (SubscriptionStats.ScheduledCharge) -> Void

    @EnvironmentObject private var preferences: SubPreferences
    @State private var position = 0.0
    @State private var dragging = false

    var body: some View {
        if charges.isEmpty {
            Text("近期没有要扣的订阅")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 26)
        } else {
            VStack(spacing: 10) {
                GeometryReader { proxy in
                    ZStack {
                        ForEach(Array(charges.enumerated()), id: \.element.id) { index, charge in
                            cardLayer(charge, depth: Double(index) - position, width: proxy.size.width)
                                .onTapGesture { onSelect(charge) }
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(panGesture(width: proxy.size.width))
                }
                .frame(height: 128)

                if charges.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(charges.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == focused ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                                .frame(width: index == focused ? 14 : 5, height: 5)
                        }
                    }
                    .animation(Motion.ui, value: focused)
                }
            }
        }
    }

    private var focused: Int {
        min(max(Int(position.rounded()), 0), charges.count - 1)
    }

    @ViewBuilder
    private func cardLayer(_ charge: SubscriptionStats.ScheduledCharge, depth: Double, width: CGFloat) -> some View {
        // depth 0 = 当前卡；>0 依次退到后面；<0 表示已经翻走。
        let behind = max(depth, 0)
        let gone = min(depth, 0)
        ChargeCard(item: charge)
            .scaleEffect(depth >= 0 ? 1 - CGFloat(behind) * 0.055 : 1 + CGFloat(gone) * 0.08)
            .offset(x: depth >= 0 ? CGFloat(behind) * 14 : CGFloat(gone) * width * 0.92,
                    y: depth >= 0 ? CGFloat(behind) * 7 : CGFloat(gone) * 10)
            .opacity(depth >= 0 ? (behind > 2.4 ? 0 : 1 - behind * 0.22) : max(0, 1 + gone * 1.15))
            .zIndex(-depth)
            .allowsHitTesting(depth > -0.5)
    }

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if !dragging {
                    dragging = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                let travel = Double(value.translation.width) / Double(max(width, 1)) * 1.35
                position = clampPosition(Double(focused) + travel)
            }
            .onEnded { value in
                dragging = false
                let predicted = Double(value.predictedEndTranslation.width)
                var target = Double(focused)
                if predicted < -60, focused < charges.count - 1 { target = Double(focused + 1) }
                if predicted > 60, focused > 0 { target = Double(focused - 1) }
                if target != position { SelectionHaptics.tick() }
                withAnimation(Motion.carouselSnap) {
                    position = target
                }
            }
    }

    private func clampPosition(_ raw: Double) -> Double {
        guard charges.count > 1 else { return 0 }
        let last = Double(charges.count - 1)
        // 橡皮筋：拖过界只露出一点缝隙，松手弹回。
        if raw < 0 { return raw * 0.35 }
        if raw > last { return last + (raw - last) * 0.35 }
        return raw
    }
}

struct ChargeCard: View {
    let item: SubscriptionStats.ScheduledCharge

    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SubscriptionIconView(subscription: item.subscription, size: 40, onColorCard: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.subscription.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(item.subscription.cycleTitle)
                        .font(.caption2)
                        .opacity(0.75)
                }
                Spacer()
                Text(QJFormat.relativeDay(item.date))
                    .font(.footnote.weight(.bold))
            }
            .foregroundStyle(.white)
            Spacer(minLength: 18)
            HStack(alignment: .bottom) {
                Text(item.amount.formatted)
                    .font(SauryTheme.amountFont(size: 22))
                Spacer()
                Text(QJFormat.shortDateWithWeekday(item.date))
                    .font(.caption.weight(.medium))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
        }
        .padding(16)
        .frame(height: 128)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var cardBackground: some View {
        if preferences.coloredCards {
            CardGradient(hexes: item.subscription.colorSpec.orderedHexes.isEmpty
                ? [IconTintHelper.hexFallback(for: item.subscription, preferences: preferences)]
                : item.subscription.colorSpec.orderedHexes)
        } else {
            SauryTheme.surfaceElevated
        }
    }
}

/// 卡片配色的兜底色：没有手动配色时从图标取主色，取不到退主题色。
@MainActor
enum IconTintHelper {
    static func color(for subscription: Subscription, preferences: SubPreferences) -> Color {
        if let hex = subscription.iconColorHex, let color = Color(hex: hex) { return color }
        if let file = subscription.iconImageFile {
            return IconTint.dominantColor(of: IconImageStore.shared.image(for: file))
                ?? Color(hex: preferences.accentHex) ?? .accentColor
        }
        return Color(hex: preferences.accentHex) ?? .accentColor
    }

    static func hexFallback(for subscription: Subscription, preferences: SubPreferences) -> String {
        if let hex = subscription.iconColorHex { return hex }
        return preferences.accentHex
    }
}

/// 总览里嵌的迷你月历：数字 + 当天扣费的订阅小图标。
struct MiniCalendarPanel: View {
    let stats: SubscriptionStats

    @State private var month = Date()
    @State private var direction = 1

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    moveMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(Pressable(scale: 0.8))
                Spacer()
                Text(QJFormat.yearMonth(month))
                    .font(.footnote.weight(.medium))
                    .contentTransition(.opacity)
                Spacer()
                Button {
                    moveMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(Pressable(scale: 0.8))
            }
            CalendarMonthGrid(
                month: month,
                chargesByDay: stats.chargesByDay(in: month),
                iconProvider: { subscription in SubscriptionIconView(subscription: subscription, size: 20) },
                compact: true
            )
            .id(month)
            .transition(.directionalSlide(direction, distance: 26, fade: 0.15))
        }
        .animation(Motion.slide, value: month)
    }

    private func moveMonth(_ delta: Int) {
        SelectionHaptics.tick()
        direction = delta
        month = BillingMath.calendar.date(byAdding: .month, value: delta, to: month) ?? month
    }
}

/// 月份网格。总览迷你版和日历详情页共用：紧凑版只放小图标，详情版可以选中某天。
struct CalendarMonthGrid<Icon: View>: View {
    let month: Date
    let chargesByDay: [Date: [SubscriptionStats.ScheduledCharge]]
    var iconProvider: (Subscription) -> Icon
    var compact: Bool
    var selectedDay: Date?
    var onSelectDay: ((Date) -> Void)?

    var body: some View {
        let calendar = BillingMath.calendar
        let days = Self.monthDays(for: month)
        VStack(spacing: compact ? 8 : 10) {
            HStack {
                ForEach(QJFormat.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<days.count / 7, id: \.self) { row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let day = days[row * 7 + column]
                        dayCell(day)
                    }
                }
            }
        }
        .environment(\.calendar, calendar)
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        ZStack(alignment: .top) {
            if let day {
                let charges = chargesByDay[BillingMath.calendar.startOfDay(for: day)] ?? []
                let isSelected = selectedDay != nil && BillingMath.calendar.isDate(selectedDay!, inSameDayAs: day)
                VStack(spacing: 3) {
                    Text(String(BillingMath.calendar.component(.day, from: day)))
                        .font(.subheadline.monospacedDigit().weight(isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(isSelected ? Color.accentColor : .clear)
                        )
                        .scaleEffect(isSelected ? 1.06 : 1)
                        .animation(Motion.pop, value: isSelected)
                    if !charges.isEmpty {
                        if compact {
                            HStack(spacing: 2) {
                                ForEach(charges.prefix(2)) { charge in
                                    iconProvider(charge.subscription)
                                }
                                if charges.count > 2 {
                                    Text("+\(charges.count - 2)")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            HStack(spacing: 3) {
                                ForEach(charges.prefix(3)) { charge in
                                    iconProvider(charge.subscription)
                                }
                            }
                        }
                    } else {
                        Spacer().frame(height: compact ? 20 : 24)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onSelectDay?(day) }
            } else {
                Color.clear.frame(height: compact ? 50 : 56)
            }
        }
    }

    /// 一个自然月按周对齐的日期表；开头的 nil 补齐周首空位。
    static func monthDays(for month: Date) -> [Date?] {
        let calendar = BillingMath.calendar
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        var days: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        var cursor = interval.start
        while cursor < interval.end {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? interval.end
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }
}
