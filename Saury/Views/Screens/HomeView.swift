import SwiftUI

struct HomeView: View {
    let items: [RenewalItem]
    let onOpenItem: (RenewalItem) -> Void
    let onAdd: () -> Void
    let onSettings: () -> Void

    private var nextItem: RenewalItem? { items.first }
    private var upcomingItems: ArraySlice<RenewalItem> { items.dropFirst().prefix(5) }
    private var monthlySpend: Int {
        items.reduce(0) { total, item in
            switch item.cycle {
            case .yearly: return total + item.amountMinorUnits / 12
            case .customMonths: return total + item.amountMinorUnits / max(item.intervalMonths, 1)
            default: return total + item.amountMinorUnits
            }
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 31, height: 31)
                        .background(QJTheme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("期见")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(QJTheme.ink)
                    Spacer()
                }
                .padding(.bottom, 22)

                QJHeader(
                    eyebrow: Date().qjWeekdayDateText,
                    title: "先提醒，再决定\n要不要继续。",
                    onSettings: onSettings
                )

                if let nextItem {
                    Button { onOpenItem(nextItem) } label: { FocusRenewalCard(item: nextItem) }
                        .buttonStyle(.plain)
                        .padding(.top, 22)
                } else {
                    EmptyRenewalCard(onAdd: onAdd)
                        .padding(.top, 22)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("接下来")
                        .font(.headline.weight(.medium))
                    Spacer()
                    Text("未来 30 天")
                        .font(.caption)
                        .foregroundStyle(QJTheme.subtle)
                }
                .padding(.top, 27)
                .padding(.horizontal, 2)

                if upcomingItems.isEmpty {
                    Text(nextItem == nil ? "添加第一个订阅，期见会在续费前提醒你。" : "目前没有更多即将到期的订阅。")
                        .font(.subheadline)
                        .foregroundStyle(QJTheme.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .qjCard(fill: QJTheme.elevated.opacity(0.72), radius: 20)
                        .padding(.top, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(upcomingItems), id: \.id) { item in
                            Button { onOpenItem(item) } label: { RenewalListRow(item: item) }
                                .buttonStyle(.plain)
                            if item.id != upcomingItems.last?.id { Divider().overlay(QJTheme.line) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .qjCard(radius: 20)
                    .padding(.top, 10)
                }

                HStack(spacing: 8) {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(QJTheme.calm)
                    Text(monthlySpend > 0 ? "如果取消不需要的续费，本月可少支出 \(monthlySpend.qjCurrencyText)" : "先记录订阅，期见会帮你看清每月固定支出")
                        .font(.caption)
                        .foregroundStyle(QJTheme.subtle)
                }
                .padding(.top, 14)
                .padding(.horizontal, 3)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 100)
        }
    }
}

private struct FocusRenewalCard: View {
    let item: RenewalItem
    private var days: Int { RenewalDateCalculator.daysUntil(item.nextRenewalDate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ServiceIcon(item: item, size: 42, light: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(item.cycle.title + (item.isAutoRenewing ? " · 自动续费" : " · 手动续费"))
                        .font(.caption)
                        .opacity(0.72)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.white)
            Text(days >= 0 ? "\(days)" : "已到期")
                .font(.system(size: 55, weight: .medium, design: .rounded))
                .tracking(-2)
                .foregroundStyle(.white)
                .padding(.top, 22)
            Text(days >= 0 ? "天后到期" : "请尽快处理")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
            HStack {
                Text(item.nextRenewalDate.qjWeekdayDateText)
                Spacer()
                Text(item.formattedAmount)
                    .font(.title3.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.82))
            .padding(.top, 21)
        }
        .padding(19)
        .background(QJTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.16))
                .frame(width: 132, height: 132)
                .offset(x: 32, y: -42)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(days)天后到期，金额\(item.formattedAmount)")
    }
}

private struct EmptyRenewalCard: View {
    let onAdd: () -> Void
    var body: some View {
        Button(action: onAdd) {
            VStack(alignment: .leading, spacing: 13) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 27))
                Text("还没有需要提醒的订阅")
                    .font(.title3.weight(.medium))
                Text("记录一个订阅，提前留出取消或继续的时间。")
                    .font(.subheadline)
                    .foregroundStyle(QJTheme.subtle)
            }
            .foregroundStyle(QJTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .qjCard(fill: QJTheme.elevated, radius: 24)
        }
        .buttonStyle(.plain)
    }
}

struct ServiceIcon: View {
    let item: RenewalItem
    let size: CGFloat
    var light = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(light ? .white.opacity(0.86) : QJTheme.accentSoft)
            Image(systemName: item.category.symbolName)
                .font(.system(size: size * 0.40, weight: .medium))
                .foregroundStyle(light ? QJTheme.accent : QJTheme.accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct RenewalListRow: View {
    let item: RenewalItem
    private var days: Int { RenewalDateCalculator.daysUntil(item.nextRenewalDate) }

    var body: some View {
        HStack(spacing: 11) {
            ServiceIcon(item: item, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(QJTheme.ink)
                    .lineLimit(1)
                Text(item.cycle.title)
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(days >= 0 ? "\(days) 天" : "已到期")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(QJTheme.ink)
                Text(item.formattedAmount)
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
