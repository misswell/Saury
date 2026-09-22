import SwiftUI
import WidgetKit

/// 字段必须与主 App 的 QJWidgetSnapshot 一致：两个 target 之间只靠这份 JSON 通信。
private struct WidgetSnapshot: Codable {
    let name: String
    let expiryDate: Date
    let amountText: String?
    let days: Int
    let countdownText: String
}

private struct QJWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private struct QJWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> QJWidgetEntry {
        QJWidgetEntry(date: Date(), snapshot: WidgetSnapshot(name: "纯牛奶 1L", expiryDate: Date().addingTimeInterval(5 * 86400), amountText: "¥12.80", days: 5, countdownText: "还有 5 天"))
    }

    func getSnapshot(in context: Context, completion: @escaping (QJWidgetEntry) -> Void) {
        completion(QJWidgetEntry(date: Date(), snapshot: readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QJWidgetEntry>) -> Void) {
        let entry = QJWidgetEntry(date: Date(), snapshot: readSnapshot())
        let refresh = Calendar.current.date(byAdding: .hour, value: 6, to: Date()) ?? Date().addingTimeInterval(21600)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func readSnapshot() -> WidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: "group.com.guofeng.saury"),
              let data = defaults.data(forKey: "qijian.widgetSnapshot"),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return WidgetSnapshot(name: "还没有记录", expiryDate: Date(), amountText: nil, days: 0, countdownText: "添加第一件物品")
        }
        return snapshot
    }
}

struct QJWidget: Widget {
    let kind = "QJWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QJWidgetProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .foregroundStyle(Color(red: 0.85, green: 0.29, blue: 0.23))
                    Text("期见").font(.caption.weight(.medium))
                    Spacer()
                    if let amountText = entry.snapshot.amountText {
                        Text(amountText).font(.caption.weight(.medium))
                    }
                }
                Spacer()
                Text(entry.snapshot.name).font(.headline.weight(.medium)).lineLimit(1)
                Text(entry.snapshot.countdownText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .containerBackground(for: .widget) { Color(red: 0.98, green: 0.97, blue: 0.94) }
        }
        .configurationDisplayName("下一件要处理的事")
        .description("在到期前看见最需要决定的物品。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct QJWidgetBundle: WidgetBundle {
    var body: some Widget { QJWidget() }
}
