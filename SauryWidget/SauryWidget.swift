import SwiftUI
import WidgetKit

private struct WidgetSnapshot: Codable {
    let name: String
    let nextRenewalDate: Date
    let amountText: String
    let days: Int
}

private struct QJWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private struct QJWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> QJWidgetEntry {
        QJWidgetEntry(date: Date(), snapshot: WidgetSnapshot(name: "设计工具 Pro", nextRenewalDate: Date().addingTimeInterval(5 * 86400), amountText: "¥68.00", days: 5))
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
        guard let defaults = UserDefaults(suiteName: "group.com.guofeng.saury"), let data = defaults.data(forKey: "qijian.widgetSnapshot"), let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return WidgetSnapshot(name: "还没有订阅", nextRenewalDate: Date(), amountText: "添加一个提醒", days: 0)
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
                    Text(entry.snapshot.amountText).font(.caption.weight(.medium))
                }
                Spacer()
                Text(entry.snapshot.name).font(.headline.weight(.medium)).lineLimit(1)
                Text(entry.snapshot.days > 0 ? "还有 \(entry.snapshot.days) 天到期" : "今天需要处理")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .containerBackground(for: .widget) { Color(red: 0.98, green: 0.97, blue: 0.94) }
        }
        .configurationDisplayName("最近一次续费")
        .description("在到期前看见最需要决定的订阅。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct QJWidgetBundle: WidgetBundle {
    var body: some Widget { QJWidget() }
}
