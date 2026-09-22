import SwiftUI

struct SubscriptionTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let amountMinorUnits: Int
    let currencyCode: String
    let cycle: RenewalCycle
    let category: RenewalCategory
    let symbolName: String

    var draft: ExternalRenewalDraft {
        ExternalRenewalDraft(
            name: name,
            amountMinorUnits: amountMinorUnits,
            currencyCode: currencyCode,
            renewalDate: Calendar.current.date(byAdding: .month, value: cycle == .yearly ? 12 : 1, to: Date()),
            cycle: cycle,
            source: "quick-add"
        )
    }
}

struct QuickAddSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (ExternalRenewalDraft) -> Void
    let onCustom: () -> Void

    @State private var searchText = ""
    @State private var selectedCategory: RenewalCategory?

    private let templates: [SubscriptionTemplate] = [
        SubscriptionTemplate(id: "bilibili", name: "哔哩哔哩", amountMinorUnits: 1900, currencyCode: "CNY", cycle: .monthly, category: .entertainment, symbolName: "play.rectangle.fill"),
        SubscriptionTemplate(id: "taobao", name: "淘宝 88VIP", amountMinorUnits: 8800, currencyCode: "CNY", cycle: .yearly, category: .entertainment, symbolName: "bag.fill"),
        SubscriptionTemplate(id: "iqiyi", name: "爱奇艺", amountMinorUnits: 2500, currencyCode: "CNY", cycle: .monthly, category: .entertainment, symbolName: "play.tv.fill"),
        SubscriptionTemplate(id: "netease", name: "网易云音乐", amountMinorUnits: 1800, currencyCode: "CNY", cycle: .monthly, category: .entertainment, symbolName: "music.note"),
        SubscriptionTemplate(id: "meituan", name: "美团会员", amountMinorUnits: 1500, currencyCode: "CNY", cycle: .monthly, category: .wellness, symbolName: "m.circle.fill"),
        SubscriptionTemplate(id: "icloud", name: "iCloud+", amountMinorUnits: 2500, currencyCode: "CNY", cycle: .monthly, category: .storage, symbolName: "icloud.fill"),
        SubscriptionTemplate(id: "chatgpt", name: "ChatGPT Plus", amountMinorUnits: 2000, currencyCode: "USD", cycle: .monthly, category: .productivity, symbolName: "sparkles"),
        SubscriptionTemplate(id: "tencent-video", name: "腾讯视频", amountMinorUnits: 2000, currencyCode: "CNY", cycle: .monthly, category: .entertainment, symbolName: "play.tv.fill"),
        SubscriptionTemplate(id: "youku", name: "优酷", amountMinorUnits: 2500, currencyCode: "CNY", cycle: .monthly, category: .entertainment, symbolName: "play.rectangle.fill"),
        SubscriptionTemplate(id: "baidu", name: "百度网盘", amountMinorUnits: 3000, currencyCode: "CNY", cycle: .monthly, category: .storage, symbolName: "externaldrive.fill"),
        SubscriptionTemplate(id: "notion", name: "Notion", amountMinorUnits: 1000, currencyCode: "USD", cycle: .monthly, category: .productivity, symbolName: "note.text"),
        SubscriptionTemplate(id: "netflix", name: "Netflix", amountMinorUnits: 1599, currencyCode: "USD", cycle: .monthly, category: .entertainment, symbolName: "film.fill")
    ]

    private var filteredTemplates: [SubscriptionTemplate] {
        templates.filter { item in
            let matchesSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.name.localizedCaseInsensitiveContains(searchText)
            let matchesCategory = selectedCategory == nil || item.category == selectedCategory
            return matchesSearch && matchesCategory
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("添加订阅")
                            .font(.largeTitle.weight(.semibold))
                        Text("选择常用服务快速开始，也可以完全自定义。")
                            .font(.subheadline)
                            .foregroundStyle(QJTheme.subtle)
                    }

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(QJTheme.subtle)
                        TextField("搜索服务", text: $searchText)
                            .textInputAutocapitalization(.never)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(QJTheme.subtle)
                            }
                        }
                    }
                    .padding(.horizontal, 13)
                    .frame(minHeight: 47)
                    .qjCard(fill: QJTheme.surface, radius: 15)

                    categoryPicker

                    Button(action: onCustom) {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(QJTheme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("自定义订阅")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(QJTheme.ink)
                                Text("名称、金额、周期和提醒都由你决定")
                                    .font(.caption)
                                    .foregroundStyle(QJTheme.subtle)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(QJTheme.subtle)
                        }
                        .padding(15)
                        .qjCard(fill: QJTheme.accentSoft.opacity(0.72), radius: 19)
                    }
                    .buttonStyle(.plain)

                    Text("常用服务")
                        .font(.headline.weight(.medium))
                        .padding(.top, 3)

                    if filteredTemplates.isEmpty {
                        Text("没有找到匹配的服务，试试自定义订阅。")
                            .font(.subheadline)
                            .foregroundStyle(QJTheme.subtle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .qjCard(fill: QJTheme.elevated.opacity(0.72), radius: 19)
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
                                            Text("约 (item.amountMinorUnits.qjCurrencyText) · (item.cycle.title)")
                                                .font(.caption)
                                                .foregroundStyle(QJTheme.subtle)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(QJTheme.subtle)
                                    }
                                    .padding(13)
                                    .qjCard(fill: QJTheme.elevated, radius: 17)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(QJTheme.canvas)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(title: "全部", category: nil)
                ForEach(RenewalCategory.allCases) { category in
                    categoryChip(title: category.title, category: category)
                }
            }
        }
    }

    private func categoryChip(title: String, category: RenewalCategory?) -> some View {
        Button { selectedCategory = category } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(selectedCategory == category ? QJTheme.surface : QJTheme.subtle)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(selectedCategory == category ? QJTheme.ink : QJTheme.elevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
