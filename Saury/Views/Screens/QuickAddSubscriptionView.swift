import SwiftUI

struct SubscriptionTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let priceMinorUnits: Int
    let currencyCode: String
    let recurrence: ExpiryRecurrence
    let category: ExpiryCategory
    let symbolName: String

    var draft: ExternalItemDraft {
        ExternalItemDraft(
            name: name,
            priceMinorUnits: priceMinorUnits,
            currencyCode: currencyCode,
            expiryDate: Calendar.current.date(byAdding: .month, value: recurrence == .yearly ? 12 : 1, to: Date()),
            recurrence: recurrence,
            category: category
        )
    }
}

struct QuickAddSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (ExternalItemDraft) -> Void
    let onCustom: () -> Void

    @State private var searchText = ""

    private let templates: [SubscriptionTemplate] = [
        SubscriptionTemplate(id: "bilibili", name: "哔哩哔哩", priceMinorUnits: 1900, currencyCode: "CNY", recurrence: .monthly, category: .subscription, symbolName: "play.rectangle.fill"),
        SubscriptionTemplate(id: "taobao", name: "淘宝 88VIP", priceMinorUnits: 8800, currencyCode: "CNY", recurrence: .yearly, category: .subscription, symbolName: "bag.fill"),
        SubscriptionTemplate(id: "iqiyi", name: "爱奇艺", priceMinorUnits: 2500, currencyCode: "CNY", recurrence: .monthly, category: .subscription, symbolName: "play.tv.fill"),
        SubscriptionTemplate(id: "netease", name: "网易云音乐", priceMinorUnits: 1800, currencyCode: "CNY", recurrence: .monthly, category: .subscription, symbolName: "music.note"),
        SubscriptionTemplate(id: "meituan", name: "美团会员", priceMinorUnits: 1500, currencyCode: "CNY", recurrence: .monthly, category: .subscription, symbolName: "m.circle.fill"),
        SubscriptionTemplate(id: "icloud", name: "iCloud+", priceMinorUnits: 2500, currencyCode: "CNY", recurrence: .monthly, category: .subscription, symbolName: "icloud.fill"),
        SubscriptionTemplate(id: "chatgpt", name: "ChatGPT Plus", priceMinorUnits: 2000, currencyCode: "USD", recurrence: .monthly, category: .subscription, symbolName: "sparkles"),
        SubscriptionTemplate(id: "tencent-video", name: "腾讯视频", priceMinorUnits: 2000, currencyCode: "CNY", recurrence: .monthly, category: .subscription, symbolName: "play.tv.fill"),
        SubscriptionTemplate(id: "youku", name: "优酷", priceMinorUnits: 2500, currencyCode: "CNY", recurrence: .monthly, category: .subscription, symbolName: "play.rectangle.fill"),
        SubscriptionTemplate(id: "baidu", name: "百度网盘", priceMinorUnits: 3000, currencyCode: "CNY", recurrence: .monthly, category: .subscription, symbolName: "externaldrive.fill"),
        SubscriptionTemplate(id: "notion", name: "Notion", priceMinorUnits: 1000, currencyCode: "USD", recurrence: .monthly, category: .subscription, symbolName: "note.text"),
        SubscriptionTemplate(id: "netflix", name: "Netflix", priceMinorUnits: 1599, currencyCode: "USD", recurrence: .monthly, category: .subscription, symbolName: "film.fill")
    ]

    private var filteredTemplates: [SubscriptionTemplate] {
        templates.filter { item in
            item.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Button(action: onCustom) {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(QJTheme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("自己填写")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(QJTheme.ink)
                                Text("名称、金额、日期和提醒都由你决定")
                                    .font(.caption)
                                    .foregroundStyle(QJTheme.subtle)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(QJTheme.subtle)
                        }
                        .padding(15)
                        .qjCard(fill: QJTheme.accentSoft)
                    }
                    .buttonStyle(.plain)

                    Text("常用订阅")
                        .font(.headline)
                        .padding(.top, 3)

                    if filteredTemplates.isEmpty {
                        ContentUnavailableView(
                            "没有找到匹配的服务",
                            systemImage: "magnifyingglass",
                            description: Text("换个关键词，或者自己填写一条。")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else {
                        LazyVStack(spacing: 9) {
                            ForEach(filteredTemplates) { item in
                                Button { onSelect(item.draft) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.symbolName)
                                            .font(.system(size: 17, weight: .medium))
                                            .foregroundStyle(QJTheme.accent)
                                            .frame(width: 36, height: 36)
                                            .background(QJTheme.accentSoft)
                                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.name)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(QJTheme.ink)
                                            Text("约 \(QJMoney.text(item.priceMinorUnits, currencyCode: item.currencyCode)) · \(item.recurrence.title)")
                                                .font(.caption)
                                                .foregroundStyle(QJTheme.subtle)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(QJTheme.subtle)
                                    }
                                    .padding(13)
                                    .qjCard()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, QJMetric.screen)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .background(QJTheme.canvas)
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索服务或物品")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

}
