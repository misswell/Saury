import SwiftUI

struct CalendarView: View {
    let items: [RenewalItem]
    let onOpenItem: (RenewalItem) -> Void
    let onSettings: () -> Void

    @State private var visibleMonth = Date()
    @State private var selectedDay = Date()

    private var calendar: Calendar { RenewalDateCalculator.defaultCalendar }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                QJHeader(eyebrow: "续费日历", title: monthTitle, subtitle: "把决定安排在扣款之前。", onSettings: onSettings)
                    .padding(.top, 10)

                HStack {
                    Button { changeMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(monthTitle).font(.subheadline.weight(.medium))
                    Spacer()
                    Button { changeMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                }
                .foregroundStyle(QJTheme.ink)
                .padding(.top, 22)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                    ForEach(calendar.shortWeekdaySymbolsStartingMonday, id: \.self) { weekday in
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
                .qjCard(radius: 22)
                .padding(.top, 11)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本月有 \(monthItems.count) 次续费")
                            .font(.subheadline.weight(.medium))
                        Text("预计支出 \(monthSpend.qjCurrencyText)")
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
                    Text(selectedDay.qjDateText).font(.headline.weight(.medium))
                    Spacer()
                    Text("最近")
                        .font(.caption)
                        .foregroundStyle(QJTheme.subtle)
                }
                .padding(.top, 25)
                .padding(.horizontal, 2)

                let selectedItems = items.filter { calendar.isDate($0.nextRenewalDate, inSameDayAs: selectedDay) }
                if selectedItems.isEmpty {
                    Text("这一天没有安排续费。")
                        .font(.subheadline)
                        .foregroundStyle(QJTheme.subtle)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .qjCard(fill: QJTheme.elevated.opacity(0.72), radius: 20)
                        .padding(.top, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(selectedItems, id: \.id) { item in
                            Button { onOpenItem(item) } label: { RenewalListRow(item: item) }
                                .buttonStyle(.plain)
                            if item.id != selectedItems.last?.id { Divider().overlay(QJTheme.line) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .qjCard(radius: 20)
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 105)
        }
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

    private var monthItems: [RenewalItem] {
        items.filter {
            calendar.component(.year, from: $0.nextRenewalDate) == calendar.component(.year, from: visibleMonth) &&
            calendar.component(.month, from: $0.nextRenewalDate) == calendar.component(.month, from: visibleMonth)
        }
    }

    private var monthSpend: Int { monthItems.reduce(0) { $0 + $1.amountMinorUnits } }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let hasItem = items.contains { calendar.isDate($0.nextRenewalDate, inSameDayAs: day) }
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
        .accessibilityLabel("\(day.qjDateText)\(hasItem ? "，有续费" : "")")
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
