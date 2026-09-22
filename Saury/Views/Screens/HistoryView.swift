import SwiftUI

struct HistoryView: View {
    let decisions: [DecisionRecord]
    let onSettings: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                QJHeader(eyebrow: "决定记录", title: "每一次续费，\n都值得想一想。", subtitle: "取消和继续都会留在这里。", onSettings: onSettings)
                    .padding(.top, 10)

                let cancelled = decisions.filter { $0.action == .cancelled }.reduce(0) { $0 + $1.amountMinorUnits }
                HStack(spacing: 10) {
                    HistoryStat(title: "已取消", value: "\(decisions.filter { $0.action == .cancelled }.count) 次", color: QJTheme.calm)
                    HistoryStat(title: "预计少支出", value: cancelled.qjCurrencyText, color: QJTheme.calm)
                }
                .padding(.top, 22)

                Text("最近决定")
                    .font(.headline.weight(.medium))
                    .padding(.top, 27)
                    .padding(.horizontal, 2)

                if decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 26))
                            .foregroundStyle(QJTheme.accent)
                        Text("还没有决定记录")
                            .font(.title3.weight(.medium))
                        Text("每次提醒后的选择，都会帮助你更清楚地知道哪些订阅值得留下。")
                            .font(.subheadline)
                            .foregroundStyle(QJTheme.subtle)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .qjCard(radius: 22)
                    .padding(.top, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(decisions, id: \.id) { decision in
                            DecisionRow(decision: decision)
                            if decision.id != decisions.last?.id { Divider().overlay(QJTheme.line) }
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
}

private struct HistoryStat: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(QJTheme.subtle)
            Text(value).font(.title3.weight(.medium)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .qjCard(fill: QJTheme.calmSoft, radius: 18)
    }
}

private struct DecisionRow: View {
    let decision: DecisionRecord

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: decision.action == .cancelled ? "checkmark" : (decision.action == .continued ? "arrow.clockwise" : "pause.fill"))
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(decision.action == .cancelled ? QJTheme.calm : QJTheme.accent)
                .background(decision.action == .cancelled ? QJTheme.calmSoft : QJTheme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.itemName).font(.subheadline.weight(.medium)).foregroundStyle(QJTheme.ink)
                Text(decision.action.title + " · " + decision.happenedAt.qjShortDateTimeText)
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
            }
            Spacer()
            Text(decision.amountMinorUnits.qjCurrencyText)
                .font(.caption.weight(.medium))
                .foregroundStyle(QJTheme.subtle)
        }
        .padding(.vertical, 11)
    }
}
