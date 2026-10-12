import SwiftUI

/// 列表形态的一行。
struct SubscriptionListRow: View {
    let subscription: Subscription
    var onTap: () -> Void

    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                SubscriptionIconView(subscription: subscription, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(subscription.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if subscription.state == .inactive {
                            tag("已停用")
                        } else if !BillingMath.isStarted(subscription) {
                            tag("未开始")
                        }
                    }
                    Text(metaLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(QJFormat.monthDayShort(nextDate)) \(QJFormat.countdown(nextDate))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(displayAmount.formatted)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text("/\(cycleShort)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if preferences.showOriginalCurrency, originalText != displayAmount.formatted {
                        Text(originalText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .sauryCard()
        }
        .buttonStyle(CardPressable())
    }

    private var metaLine: String {
        let category = preferences.category(withID: subscription.categoryRawValue)
        var parts = [category.name]
        if !subscription.plan.isEmpty { parts.append(subscription.plan) }
        if !subscription.paymentMethod.isEmpty { parts.append(subscription.paymentMethod) }
        if subscription.shareEnabled { parts.append("拼车 \(subscription.shareHeadcount) 人") }
        return parts.joined(separator: " · ")
    }

    private var nextDate: Date {
        BillingMath.nextChargeDate(for: subscription) ?? subscription.startDate
    }

    private var displayAmount: Money {
        subscription.myAmount.converting(to: preferences.defaultCurrency, rates: ExchangeRateStore.shared.rates)
    }

    private var originalText: String {
        subscription.myAmount.formatted
    }

    private var cycleShort: String {
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

    @ViewBuilder
    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(SauryTheme.surfaceElevated))
    }
}

/// 卡片 / 紧凑卡片格子。
struct SubscriptionCardCell: View {
    let subscription: Subscription
    var compact: Bool
    var onTap: () -> Void

    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack(alignment: .top) {
                    SubscriptionIconView(subscription: subscription, size: compact ? 26 : 34)
                    Spacer()
                    if !BillingMath.isStarted(subscription) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(subscription.name)
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !compact {
                        HStack(spacing: 4) {
                            Text(displayAmount.formatted)
                                .font(SauryTheme.amountFont(size: 15))
                                .foregroundStyle(.white)
                            Text("/\(cycleShort)")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        Text(QJFormat.monthDayShort(nextDate))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                if !compact, let next = BillingMath.nextChargeDate(for: subscription) {
                    CycleProgressBar(subscription: subscription, nextCharge: next)
                }
            }
            .padding(compact ? 10.0 : 14.0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
        }
        .buttonStyle(CardPressable())
    }

    private var nextDate: Date {
        BillingMath.nextChargeDate(for: subscription) ?? subscription.startDate
    }

    private var displayAmount: Money {
        subscription.myAmount.converting(to: preferences.defaultCurrency, rates: ExchangeRateStore.shared.rates)
    }

    private var cycleShort: String {
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

    @ViewBuilder
    private var cardBackground: some View {
        if preferences.coloredCards {
            CardGradient(hexes: subscription.colorSpec.orderedHexes.isEmpty
                ? [IconTintHelper.hexFallback(for: subscription, preferences: preferences)]
                : subscription.colorSpec.orderedHexes)
        } else {
            SauryTheme.surfaceElevated
        }
    }
}

/// 本期进度条：从上次扣费到下次扣费走了多少。
struct CycleProgressBar: View {
    let subscription: Subscription
    let nextCharge: Date

    @State private var grown = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white)
                    .frame(width: grown ? max(4, proxy.size.width * fraction) : 4)
            }
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(Motion.chart) { grown = true }
        }
    }

    private var fraction: CGFloat {
        let cycleDays = BillingMath.approximateCycleDays(for: subscription)
        guard cycleDays > 0 else { return 0 }
        let remaining = max(BillingMath.daysUntil(nextCharge), 0)
        return CGFloat(min(max(1 - Double(remaining) / cycleDays, 0), 1))
    }
}

/// 紧凑列表行：比标准行矮一截，一屏能看到更多订阅。
struct CompactListRow: View {
    let subscription: Subscription

    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        HStack(spacing: 10) {
            SubscriptionIconView(subscription: subscription, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(subscription.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !BillingMath.isStarted(subscription) {
                        Text("未开始")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(QJFormat.monthDayShort(nextDate)) · \(cycleShort)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(displayAmount.formatted)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SauryTheme.surface))
        .contentShape(Rectangle())
    }

    private var nextDate: Date {
        BillingMath.nextChargeDate(for: subscription) ?? subscription.startDate
    }

    private var displayAmount: Money {
        subscription.myAmount.converting(to: preferences.defaultCurrency, rates: ExchangeRateStore.shared.rates)
    }

    private var cycleShort: String {
        switch subscription.cycle {
        case .weekly: return "周付"
        case .monthly: return "月付"
        case .quarterly: return "季付"
        case .semiannual: return "半年付"
        case .yearly: return "年付"
        case .custom: return "\(subscription.customMonths)月付"
        case .oneTime: return "一次性"
        }
    }
}
