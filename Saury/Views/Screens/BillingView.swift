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
    let items: [ExpiryItem]
    let onOpenItem: (ExpiryItem) -> Void
    let onShowHistory: () -> Void

    @State private var mode: BillingMode = .expense
    @State private var selectedMonth = Date()

    private var calendar: Calendar { ExpiryEngine.calendar }

    private var monthItems: [ExpiryItem] {
        items.filter {
            calendar.component(.year, from: $0.effectiveExpiryDate) == calendar.component(.year, from: selectedMonth) &&
            calendar.component(.month, from: $0.effectiveExpiryDate) == calendar.component(.month, from: selectedMonth)
        }
        .sorted { $0.effectiveExpiryDate < $1.effectiveExpiryDate }
    }

    private var monthSpend: QJSpendSummary {
        var summary = QJSpendSummary()
        for item in monthItems {
            guard let price = item.priceMinorUnits else { continue }
            summary.add(price, currencyCode: item.currencyCode ?? QJPreferences.defaultCurrencyCode)
        }
        return summary
    }

    private var monthlyEquivalentSpend: QJSpendSummary {
        var summary = QJSpendSummary()
        for item in items { summary.addMonthlyEquivalent(of: item) }
        return summary
    }

    private var categoryBreakdown: [CategorySpend] {
        Dictionary(grouping: items, by: { $0.category }).map { category, categoryItems in
            var summary = QJSpendSummary()
            for item in categoryItems { summary.addMonthlyEquivalent(of: item) }
            return CategorySpend(category: category, summary: summary)
        }
        .sorted {
            $0.summary.amount(in: monthlyEquivalentSpend.primaryCurrency)
                > $1.summary.amount(in: monthlyEquivalentSpend.primaryCurrency)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Picker("账单模式", selection: $mode) {
                    ForEach(BillingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .tint(QJTheme.accent)

                switch mode {
                case .expense:
                    expenseContent
                case .amortized:
                    amortizedContent
                }

                historyLink
            }
            .padding(.horizontal, QJMetric.screen)
            .padding(.bottom, 30)
        }
        .background(QJTheme.canvas)
    }

    private var historyLink: some View {
        Button(action: onShowHistory) {
            HStack(spacing: 11) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(QJTheme.accent)
                Text("活动记录")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(QJTheme.ink)
                Spacer()
                Text("每一次处理和续期")
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(QJTheme.subtle)
            }
            .padding(QJMetric.card)
            .qjCard()
        }
        .buttonStyle(.plain)
        .padding(.top, QJMetric.section)
    }

    private var expenseContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            monthNavigator

            HStack(spacing: 10) {
                BillingStat(title: "本月待支付", value: monthSpend.text, symbol: "creditcard.fill", tint: QJTheme.accent)
                BillingStat(title: "到期数量", value: "\(monthItems.count)", symbol: "square.stack.3d.up.fill", tint: QJTheme.calm)
            }
            .padding(.top, 17)

            if monthItems.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(QJTheme.accent)
                    Text("暂无扣费记录")
                        .font(.title3.weight(.medium))
                    Text("当物品的到期日进入这个月，预估支出会显示在这里。")
                        .font(.subheadline)
                        .foregroundStyle(QJTheme.subtle)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .qjCard()
                .padding(.top, 18)
            } else {
                Text("本月项目")
                    .font(.headline)
                    .padding(.top, QJMetric.section)

                VStack(spacing: 0) {
                    ForEach(monthItems) { item in
                        Button { onOpenItem(item) } label: {
                            ExpiryItemRow(item: item)
                        }
                        .buttonStyle(.plain)
                        if item.id != monthItems.last?.id {
                            Divider().overlay(QJTheme.line)
                        }
                    }
                }
                .padding(.horizontal, QJMetric.card)
                .qjCard()
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
                    Text(monthlyEquivalentSpend.text)
                        .font(.system(size: 38, weight: .medium, design: .rounded))
                        .foregroundStyle(QJTheme.ink)
                }
                Spacer()
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(QJTheme.calm)
            }
            .padding(19)
            .qjCard(fill: QJTheme.calmSoft)
            .padding(.top, 19)

            Text("按分类")
                .font(.headline)
                .padding(.top, QJMetric.section)

            if categoryBreakdown.isEmpty {
                Text("记录物品和金额后，这里会显示每月均摊支出。")
                    .font(.subheadline)
                    .foregroundStyle(QJTheme.subtle)
                    .padding(QJMetric.card)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .qjCard()
                    .padding(.top, 10)
            } else {
                VStack(spacing: 15) {
                    ForEach(categoryBreakdown) { breakdown in
                        CategorySpendRow(breakdown: breakdown, total: monthlyEquivalentSpend)
                    }
                }
                .padding(QJMetric.card)
                .qjCard()
                .padding(.top, 10)
            }

            Text("均摊会把年付、季付和自定义周期折算为每月金额，方便判断固定支出。")
                .font(.caption)
                .foregroundStyle(QJTheme.subtle)
                .padding(.top, 13)
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
}

private struct CategorySpend: Identifiable {
    let category: ExpiryCategory
    let summary: QJSpendSummary
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
        .qjCard()
    }
}

private struct CategorySpendRow: View {
    let breakdown: CategorySpend
    let total: QJSpendSummary

    /// 条形长度只在同一币种内比较，取总额最大的币种作为基准。
    private var fraction: Double {
        let currency = total.primaryCurrency
        let whole = total.amount(in: currency)
        guard whole > 0 else { return 0 }
        return min(max(Double(breakdown.summary.amount(in: currency)) / Double(whole), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(breakdown.category.title, systemImage: breakdown.category.symbolName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(QJTheme.ink)
                Spacer()
                Text(breakdown.summary.text)
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
