import SwiftUI

/// 活动记录（方案 §38）。
///
/// 这份记录的本质是原图的历史：扫进来的每一件都留着当时那张包装照片，
/// 有图就把缩略图摆在行首，点开还能再看一次那行喷码（方案 §34）。
struct HistoryView: View {
    let events: [ExpiryEvent]

    private var resolutions: [ExpiryEvent] { events.filter { $0.eventType.isResolution } }

    /// 取消和丢弃都是「本来要花却没花」的钱，这两类一起算才说明问题。
    private var avoidedSpend: QJSpendSummary {
        var summary = QJSpendSummary()
        for event in resolutions where event.eventType == .cancelled || event.eventType == .discarded {
            guard let price = event.priceMinorUnits else { continue }
            summary.add(price, currencyCode: event.currencyCode ?? QJPreferences.defaultCurrencyCode)
        }
        return summary
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    HistoryStat(title: "已处理", value: "\(resolutions.count) 次")
                    HistoryStat(title: "省下的支出", value: avoidedSpend.text)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("最近记录") {
                if events.isEmpty {
                    Text("扫进来的每一件、提醒之后做出的每一次决定，都会记在这里。")
                        .font(.subheadline)
                        .foregroundStyle(QJTheme.subtle)
                } else {
                    ForEach(events) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(QJTheme.canvas)
    }
}

private struct HistoryStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(QJTheme.subtle)
            Text(value).font(.title3.weight(.medium)).foregroundStyle(QJTheme.calm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(QJMetric.card)
        .qjCard(fill: QJTheme.calmSoft)
    }
}

private struct EventRow: View {
    let event: ExpiryEvent

    @State private var photo: UIImage?
    @State private var showingOriginal = false

    var body: some View {
        HStack(spacing: 11) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(event.itemName).font(.subheadline.weight(.medium))
                Text(event.eventType.title + " · " + event.happenedAt.qjShortDateTimeText)
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
            }
            Spacer()
            if let price = event.priceMinorUnits {
                Text(QJMoney.text(price, currencyCode: event.currencyCode ?? QJPreferences.defaultCurrencyCode))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(QJTheme.subtle)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if event.imageIdentifier != nil { showingOriginal = true } }
        .sheet(isPresented: $showingOriginal) {
            StoredOriginalView(identifier: event.imageIdentifier, title: event.itemName)
        }
        .accessibilityElement(children: .combine)
    }

    /// 有原图的记录把图压在动作图标上（方案 §34）；手动处理的那些没有图，剩下的就是图标。
    private var leading: some View {
        Image(systemName: event.eventType.symbolName)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 46, height: 46)
            .foregroundStyle(event.eventType.isResolution ? QJTheme.calm : QJTheme.accent)
            .background(event.eventType.isResolution ? QJTheme.calmSoft : QJTheme.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .task(id: event.imageIdentifier) {
                photo = await StoredImageLoader.load(event.imageIdentifier)
            }
    }
}
