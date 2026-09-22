import SwiftUI

enum BillingMode: String, CaseIterable, Identifiable {
    case expense
    case amortized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: return "账单支出"
        case .amortized: return "均摊"
        }
    }
}

struct BillingView: View {
    let items: [RenewalItem]
    let onOpenItem: (RenewalItem) -> Void
    let onSettings: () -> Void

    @State private var mode: BillingMode = .expense
    @State private var selectedMonth = Date()

    private var calendar: Calendar { RenewalDateCalculator.defaultCalendar }

    private var monthItems: [RenewalItem] {
        items.filter {
            calendar.component(.year, from: $0.nextRenewalDate) == calendar.component(.year, from: selectedMonth) &&
            calendar.component(.month, from: $0.nextRenewalDate) == calendar.component(.month, from: selectedMonth)
        }
        .sorted { $0.nextRenewalDate < $1.nextRenewalDate }
    }

    private var monthSpend: Int { monthItems.reduce(0) { $0 + $1.amountMinorUnits } }

    private var monthlyEquivalentSpend: Int {
        items.reduce(0) { $0 + monthlyEquivalent(for: $1) }
    }

    private var categoryBreakdown: [CategorySpend] {
        let grouped = Dictionary(grouping: items, by: { $0.category })
        return grouped.map { category, categoryItems in
            CategorySpend(category: category, amountMinorUnits: categoryItems.reduce(0) { $0 + monthlyEquivalent(for: $1) })
        }
        .sorted { $0.amountMinorUnits > $1.amountMinorUnits }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                QJHeader(eyebrow: "支出洞察", title: "订阅花在哪里，\n一眼看清。", subtitle: "只统计你记录在期见里的订阅。", onSettings: onSettings)
                    .padding(.top, 10)

                Picker("账单模式", selection: $mode) {
                    ForEach(BillingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .tint(QJTheme.accent)
                .padding(.top, 22)

                switch mode {
                case .expense:
                    expenseContent
                case .amortized:
                    amortizedContent
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 105)
        }
    }

    private var expenseContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            monthNavigator

            HStack(spacing: 10) {
                BillingStat(title: "本月待支付", value: monthSpend.qjCurrencyText, symbol: "creditcard.fill", tint: QJTheme.accent)
                BillingStat(title: "订阅数量", value: "(monthItems.count)", symbol: "square.stack.3d.up.fill", tint: QJTheme.calm)
            }
            .padding(.top, 17)

            if monthItems.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(QJTheme.accent)
                    Text("暂无扣费记录")
                        .font(.title3.weight(.medium))
                    Text("当订阅的下次到期日进入这个月，预估支出会显示在这里。")
                        .font(.subheadline)
                        .foregroundStyle(QJTheme.subtle)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .qjCard(fill: QJTheme.elevated.opacity(0.72), radius: 22)
                .padding(.top, 18)
            } else {
                Text("本月项目")
                    .font(.headline.weight(.medium))
                    .padding(.top, 27)
                    .padding(.horizontal, 2)

                VStack(spacing: 0) {
                    ForEach(monthItems) { item in
                        Button { onOpenItem(item) } label: {
                            RenewalListRow(item: item)
                        }
                        .buttonStyle(.plain)
                        if item.id != monthItems.last?.id {
                            Divider().overlay(QJTheme.line)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .qjCard(radius: 20)
                .padding(.top, 10)
            }
        }
    }

    private var amortizedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("每月均摊")
                        .font(.caption)
                        .foregroundStyle(QJTheme.subtle)
                    Text(monthlyEquivalentSpend.qjCurrencyText)
                        .font(.system(size: 38, weight: .medium, design: .rounded))
                        .foregroundStyle(QJTheme.ink)
                }
                Spacer()
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(QJTheme.calm)
            }
            .padding(19)
            .qjCard(fill: QJTheme.calmSoft.opacity(0.72), radius: 22)
            .padding(.top, 19)

            Text("按分类")
                .font(.headline.weight(.medium))
                .padding(.top, 27)
                .padding(.horizontal, 2)

            if categoryBreakdown.isEmpty {
                Text("添加订阅后，这里会显示每月均摊支出。")
                    .font(.subheadline)
                    .foregroundStyle(QJTheme.subtle)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .qjCard(fill: QJTheme.elevated.opacity(0.72), radius: 20)
                    .padding(.top, 10)
            } else {
                VStack(spacing: 15) {
                    ForEach(categoryBreakdown) { breakdown in
                        CategorySpendRow(breakdown: breakdown, total: monthlyEquivalentSpend)
                    }
                }
                .padding(17)
                .qjCard(radius: 21)
                .padding(.top, 10)
            }

            Text("均摊会把年付和自定义周期折算为每月金额，方便判断固定支出。")
                .font(.caption)
                .foregroundStyle(QJTheme.subtle)
                .padding(.top, 13)
                .padding(.horizontal, 2)
        }
    }

    private var monthNavigator: some View {
        HStack {
            Button { changeMonth(by: -1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(monthTitle)
                .font(.subheadline.weight(.medium))
            Spacer()
            Button { changeMonth(by: 1) } label: { Image(systemName: "chevron.right") }
        }
        .foregroundStyle(QJTheme.ink)
        .padding(.top, 21)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter.string(from: selectedMonth)
    }

    private func changeMonth(by value: Int) {
        if let month = calendar.date(byAdding: .month, value: value, to: selectedMonth) {
            selectedMonth = month
        }
    }

    private func monthlyEquivalent(for item: RenewalItem) -> Int {
        switch item.cycle {
        case .yearly:
            return item.amountMinorUnits / 12
        case .customMonths:
            return item.amountMinorUnits / max(item.intervalMonths, 1)
        default:
            return item.amountMinorUnits
        }
    }
}

private struct CategorySpend: Identifiable {
    let category: RenewalCategory
    let amountMinorUnits: Int
    var id: String { category.rawValue }
}

private struct BillingStat: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(QJTheme.subtle)
            Text(value)
                .font(.title3.weight(.medium))
                .foregroundStyle(QJTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .qjCard(fill: QJTheme.elevated, radius: 18)
    }
}

private struct CategorySpendRow: View {
    let breakdown: CategorySpend
    let total: Int

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(breakdown.amountMinorUnits) / Double(total), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(breakdown.category.title, systemImage: breakdown.category.symbolName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(QJTheme.ink)
                Spacer()
                Text(breakdown.amountMinorUnits.qjCurrencyText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(QJTheme.subtle)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(QJTheme.line)
                    Capsule().fill(QJTheme.accent).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 7)
        }
    }
}
