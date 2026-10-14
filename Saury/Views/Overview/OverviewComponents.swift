import SwiftUI
import os

/// 手势的一帧输入。真的 `DragGesture.Value` 和录屏探针都换算成这一个结构再喂给视图，
/// 于是「录到的那一段」和「用户手指走的那一段」是同一段代码，不是两条通路。
struct CarouselGestureFrame {
    /// 相对起手的横向位移（点）。
    var translationPixelsX: CGFloat
    /// 预测终点相对当前点的额外位移（点）：松手那一帧才有意义。
    var predictedExtraPixelsX: CGFloat
    var time: Date

    init(translationPixelsX: CGFloat, predictedExtraPixelsX: CGFloat = 0, time: Date = Date()) {
        self.translationPixelsX = translationPixelsX
        self.predictedExtraPixelsX = predictedExtraPixelsX
        self.time = time
    }

    init(of value: DragGesture.Value) {
        self.translationPixelsX = value.translation.width
        self.predictedExtraPixelsX = 0
        self.time = value.time
    }

    init(endedBy value: DragGesture.Value) {
        self.translationPixelsX = value.translation.width
        self.predictedExtraPixelsX = value.predictedEndTranslation.width - value.translation.width
        self.time = value.time
    }
}

/// 即将扣费的卡片堆叠轮播：当前卡可以横向拖走，下一张从后面浮起来归位。
///
/// 位置由 `CarouselTrack` 逐帧积分出来，屏幕上那一个值就是模型里的值 ——
/// 所以定位动画进行到一半手指再搭上来，能直接从当前位置接着拖，不用先跳一下（§9.2）。
struct UpcomingChargeCarousel: View {
    let charges: [SubscriptionStats.ScheduledCharge]
    var onSelect: (SubscriptionStats.ScheduledCharge) -> Void

    @EnvironmentObject private var preferences: SubPreferences
    /// 减少动态效果时不再弹：位移取消，落点判断一条不少（§9.4）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var track = CarouselTrack(pageCount: 0)
    /// 当前看的是哪一张。数据换了一批之后按它重算页码，而不是攥着旧下标（§8.1）。
    @State private var focusedID: String?
    @State private var dragging = false
    @State private var lastTick = Date()
    #if DEBUG
    /// 录屏探针（`-saury-fling`）在跑：只有它在跑的时候才逐帧打点。
    @State private var probing = false
    private static let probeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")
    #endif

    private var ids: [String] { charges.map(\.id) }

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
                    TimelineView(.animation(minimumInterval: nil, paused: !track.isSettling)) { timeline in
                        stack(width: proxy.size.width)
                            .onChange(of: timeline.date) { _, now in
                                guard track.isSettling else { lastTick = now; return }
                                track.advance(dt: now.timeIntervalSince(lastTick))
                                lastTick = now
                            }
                    }
#if DEBUG
                    .task { await runFlingProbeIfNeeded(width: proxy.size.width) }
#endif
                }
                .frame(height: 128)

                if charges.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(charges.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == track.focusedPage
                                      ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                                .frame(width: index == track.focusedPage ? 14 : 5, height: 5)
                        }
                    }
                    .animation(Motion.ui, value: track.focusedPage)
                }
            }
            .onAppear(perform: realign)
            .onChange(of: ids) { _, _ in realign() }
            .onChange(of: reduceMotion) { _, off in track.animatesSettle = !off }
        }
    }

    @ViewBuilder
    private func stack(width: CGFloat) -> some View {
        ZStack {
            ForEach(Array(charges.enumerated()), id: \.element.id) { index, charge in
                cardLayer(charge, depth: Double(index) - track.position, width: width)
                    .onTapGesture { onSelect(charge) }
            }
        }
        .contentShape(Rectangle())
        // minimumDistance 8：一 tap 一 drag 挂在同一层，靠阈值分家。
        // 阈值留 0 的话轻点一下也会被手势抢走，卡片就再也点不动了。
        .gesture(panGesture(width: width))
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
        DragGesture(minimumDistance: 8)
            .onChanged { frameChanged(CarouselGestureFrame(of: $0), width: width) }
            .onEnded { frameEnded(CarouselGestureFrame(endedBy: $0), width: width) }
    }

    /// 起手与跟手。手指那一帧和录屏探针那一帧进的是同一个方法，
    /// 录到的就是用户会看到的那一段代码。
    private func frameChanged(_ frame: CarouselGestureFrame, width: CGFloat) {
        if !dragging {
            dragging = true
            track.animatesSettle = !reduceMotion
            track.beginDrag(now: frame.time)
            lastTick = Date()
            probeLog("down position=\(plain(track.position)) anchor=\(plain(track.anchor))")
        }
        // 每一帧都只往起手那一格上加位移；`focused` 会跳，anchor 不会。
        let crossed = track.drag(translationInPages: CarouselTrack.pages(fromPixelsX: frame.translationPixelsX,
                                                                        width: width),
                                 now: frame.time)
        if crossed != nil { SelectionHaptics.tick() }
        #if DEBUG
        if probing { probeLog("drag x=\(plain(frame.translationPixelsX)) position=\(plain(track.position)) page=\(track.focusedPage)") }
        #endif
    }

    private func frameEnded(_ frame: CarouselGestureFrame, width: CGFloat) {
        dragging = false
        let extra = CarouselTrack.pages(fromPixelsX: frame.predictedExtraPixelsX, width: width)
        let goal = track.release(predictedExtraPages: extra)
        lastTick = Date()
        // 手指跨过的每一格已经响过一次了；这里只在「落点反悔」时补一下。
        if goal != Double(track.focusedPage) { SelectionHaptics.tick() }
        probeLog("up goal=\(plain(goal)) position=\(plain(track.position)) page=\(track.focusedPage)")
    }

    private func probeLog(_ line: String) {
        #if DEBUG
        guard probing else { return }
        Self.probeLogger.log("轮播探针 \(line, privacy: .public)")
        #endif
    }

    /// 换数据不改身份：还在的那张卡继续占着屏幕，位置变了就滑过去。
    private func realign() {
        if track.pageCount != charges.count { track.resize(pageCount: charges.count) }
        let anchored = CarouselTrack.reindex(focused: focusedID, after: ids, position: track.position)
        focusedID = anchored.focused
        track.reanchor(to: anchored.position, animated: true, whileDragging: dragging)
        track.animatesSettle = !reduceMotion
    }

    private func plain(_ value: Double) -> String { String(format: "%.3f", value) }
    private func plain(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }

    #if DEBUG
    /// 「不仅要测试慢速拖动，还要测试反复快速左右甩动」（任务书 §8.1）。
    ///
    /// 这一台机器的命令行没有辅助功能权限，合成不了真手指，所以这里灌的是 `CarouselGestureFrame`
    /// —— 手势回调把 `DragGesture.Value` 换算成它，探针直接造它，两条路进的是同一个
    /// `frameChanged` / `frameEnded`。甩与甩之间只歇 90ms，比一轮定位（~440ms）短，
    /// 于是每一枪都打在上一轮动画中间，这就是 §9.2 的「进行到 50% 时再次触发」。
    /// 逐帧打点：位置、页码、最后停在半张卡还是一张卡。
    private func runFlingProbeIfNeeded(width: CGFloat) async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-fling") else { return }
        probing = true
        try? await Task.sleep(for: .milliseconds(1200))
        ProbeMarker.shared.mark("轮播 start cards=\(track.pageCount) position=\(plain(track.position)) "
                 + "range=\(plain(track.bounds.lowerBound))…\(plain(track.bounds.upperBound)) "
                 + "减少动态效果=\(reduceMotion)")
        for stroke in 0..<4 {
            let side: CGFloat = stroke % 2 == 0 ? -1 : 1
            let reach = 150 + CGFloat(stroke) * 45
            for frame in 0..<8 {
                frameChanged(CarouselGestureFrame(translationPixelsX: side * reach * CGFloat(frame + 1) / 8,
                                                  predictedExtraPixelsX: side * reach * 0.5),
                             width: width)
                try? await Task.sleep(for: .nanoseconds(16_000_000))
            }
            frameEnded(CarouselGestureFrame(translationPixelsX: side * reach,
                                            predictedExtraPixelsX: side * reach * 0.6),
                       width: width)
            try? await Task.sleep(for: .milliseconds(90))
        }
        // 让弹簧走完再看它停在哪儿：停在两张卡中间就是不合格。
        try? await Task.sleep(for: .milliseconds(1600))
        let rest = track.position
        ProbeMarker.shared.mark("轮播 rest position=\(plain(rest)) page=\(track.focusedPage) settling=\(track.isSettling) "
                 + "wholePage=\(abs(rest - rest.rounded()) < 0.002) "
                 + "inside=\(track.bounds.contains(rest))")
        probing = false
    }
    #endif
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
