import SwiftUI

struct CalendarView: View {
    let items: [ExpiryItem]
    let onOpenItem: (ExpiryItem) -> Void

    @State private var visibleMonth = Date()
    @State private var selectedDay = Date()

    private var calendar: Calendar { ExpiryEngine.calendar }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date().qjWeekdayDateText)
                    .font(.subheadline)
                    .foregroundStyle(QJTheme.subtle)

                HStack {
                    Button { changeMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(monthTitle).font(.subheadline.weight(.medium))
                    Spacer()
                    Button { changeMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                }
                .foregroundStyle(QJTheme.ink)
                .padding(.top, 18)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                    ForEach(Array(calendar.shortWeekdaySymbolsStartingMonday.enumerated()), id: \.offset) { _, weekday in
                        Text(weekday)
                            .font(.caption2)
                            .foregroundStyle(QJTheme.subtle)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(monthGrid.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(day)
                        } else {
                            Color.clear.frame(height: 41)
                        }
                    }
                }
                .padding(14)
                .qjCard()
                .padding(.top, 11)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本月有 \(monthItems.count) 件到期")
                            .font(.subheadline.weight(.medium))
                        Text("到期金额合计 \(monthSpend.text)")
                            .font(.caption)
                            .foregroundStyle(QJTheme.calm)
                    }
                    Spacer()
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(QJTheme.calm)
                }
                .padding(17)
                .background(QJTheme.calmSoft)
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                .padding(.top, 15)

                HStack(alignment: .firstTextBaseline) {
                    Text(selectedDay.qjDateText).font(.headline)
                    Spacer()
                    Text("最近")
                        .font(.caption)
                        .foregroundStyle(QJTheme.subtle)
                }
                .padding(.top, QJMetric.section)

                let selectedItems = items.filter { calendar.isDate($0.effectiveExpiryDate, inSameDayAs: selectedDay) }
                if selectedItems.isEmpty {
                    Text("这一天没有到期的东西。")
                        .font(.subheadline)
                        .foregroundStyle(QJTheme.subtle)
                        .padding(QJMetric.card)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .qjCard()
                        .padding(.top, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(selectedItems, id: \.id) { item in
                            Button { onOpenItem(item) } label: { ExpiryItemRow(item: item) }
                                .buttonStyle(.plain)
                            if item.id != selectedItems.last?.id { Divider().overlay(QJTheme.line) }
                        }
                    }
                    .padding(.horizontal, QJMetric.card)
                    .qjCard()
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, QJMetric.screen)
            .padding(.bottom, 30)
        }
        .background(QJTheme.canvas)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter.string(from: visibleMonth)
    }

    private var monthGrid: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: visibleMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth)) else { return [] }
        let weekday = calendar.component(.weekday, from: firstDay)
        let leading = (weekday + 5) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        days += range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: firstDay) }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private var monthItems: [ExpiryItem] {
        items.filter {
            calendar.component(.year, from: $0.effectiveExpiryDate) == calendar.component(.year, from: visibleMonth) &&
            calendar.component(.month, from: $0.effectiveExpiryDate) == calendar.component(.month, from: visibleMonth)
        }
    }

    private var monthSpend: QJSpendSummary {
        var summary = QJSpendSummary()
        for item in monthItems {
            guard let price = item.priceMinorUnits else { continue }
            summary.add(price, currencyCode: item.currencyCode ?? QJPreferences.defaultCurrencyCode)
        }
        return summary
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let hasItem = items.contains { calendar.isDate($0.effectiveExpiryDate, inSameDayAs: day) }
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        Button { selectedDay = day } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption.weight(isToday || isSelected ? .semibold : .regular))
                Circle()
                    .fill(hasItem ? (isSelected ? QJTheme.accent : QJTheme.calm) : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 41)
            .foregroundStyle(isSelected ? QJTheme.accent : QJTheme.ink)
            .background(isSelected ? QJTheme.accentSoft : (isToday ? QJTheme.elevated : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.qjDateText)\(hasItem ? "，有物品到期" : "")")
    }

    private func changeMonth(by value: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: value, to: visibleMonth) {
            visibleMonth = newMonth
            selectedDay = newMonth
        }
    }
}

private extension Calendar {
    var shortWeekdaySymbolsStartingMonday: [String] {
        let symbols = veryShortStandaloneWeekdaySymbols
        return Array(symbols.dropFirst()) + [symbols[0]]
    }
}
