import SwiftUI

/// 首页只回答一个问题（方案 §13）：今天有什么需要处理。
/// 月度费用不在这里，那是统计页的事。
struct HomeView: View {
    /// 已经按 §14 排好序、且只含跟踪中物品的列表。
    let items: [ExpiryItem]
    let onOpenItem: (ExpiryItem) -> Void
    let onScan: () -> Void
    let onAdd: () -> Void
    let onPickUrgency: (ExpiryUrgency) -> Void
    let onPickLocation: (String) -> Void

    private static let attentionBuckets: [ExpiryUrgency] = [.expired, .today, .critical, .soon]

    private var counts: [ExpiryUrgency: Int] {
        Dictionary(grouping: items, by: { $0.urgency }).mapValues(\.count)
    }

    private var batchCounts: [String: Int] {
        Dictionary(grouping: items, by: { $0.productKey }).mapValues(\.count)
    }

    private var needsAttention: ArraySlice<ExpiryItem> {
        items.filter { $0.daysRemaining <= 7 }.prefix(5)
    }

    private var recentlyAdded: ArraySlice<ExpiryItem> {
        items.sorted { $0.createdAt > $1.createdAt }.prefix(3)
    }

    private var locationRows: [(name: String, count: Int)] {
        var seen: [String: Int] = [:]
        for item in items {
            guard let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !location.isEmpty else { continue }
            seen[location, default: 0] += 1
        }
        return LocationCatalog.usedLocations(in: items).prefix(6).map { ($0, seen[$0] ?? 0) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date().qjWeekdayDateText)
                    .font(.subheadline)
                    .foregroundStyle(QJTheme.subtle)

                if items.isEmpty {
                    firstRunCard
                        .padding(.top, 18)
                } else {
                    summaryTiles
                        .padding(.top, 18)
                    attentionGroup
                    recentGroup
                    locationGroup
                }
            }
            .padding(.horizontal, QJMetric.screen)
            .padding(.top, 6)
            .padding(.bottom, 40)
        }
        .background(QJTheme.canvas)
    }

    private var firstRunCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Image(systemName: "viewfinder")
                .font(.system(size: 27))
                .foregroundStyle(QJTheme.accent)
            Text("还没有记录")
                .font(.title3.weight(.medium))
                .foregroundStyle(QJTheme.ink)
            Text("扫描包装，期见会替你记住有效期。")
                .font(.subheadline)
                .foregroundStyle(QJTheme.subtle)
            HStack(spacing: 10) {
                Button("开始扫描", action: onScan)
                    .buttonStyle(.borderedProminent)
                    .tint(QJTheme.accent)
                Button("手动添加", action: onAdd)
                    .buttonStyle(.bordered)
                    .tint(QJTheme.ink)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .qjCard()
    }

    private var summaryTiles: some View {
        HStack(spacing: 8) {
            ForEach(Self.attentionBuckets) { bucket in
                Button { onPickUrgency(bucket) } label: {
                    VStack(spacing: 4) {
                        Text("\(counts[bucket] ?? 0)")
                            .font(.system(size: 25, weight: .medium, design: .rounded))
                            .foregroundStyle((counts[bucket] ?? 0) > 0 ? bucket.textTint : QJTheme.subtle)
                        Text(bucket.title)
                            .font(.caption2)
                            .foregroundStyle(QJTheme.subtle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .qjCard(fill: QJTheme.elevated, radius: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(bucket.title) \(counts[bucket] ?? 0) 件")
            }
        }
    }

    private var attentionGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader("最需要处理")

            if needsAttention.isEmpty {
                Text("未来 7 天没有物品到期。")
                    .font(.subheadline)
                    .foregroundStyle(QJTheme.subtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(QJMetric.card)
                    .qjCard(fill: QJTheme.calmSoft)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(needsAttention)) { item in
                        Button { onOpenItem(item) } label: {
                            ExpiryItemRow(item: item, batchCount: batchCounts[item.productKey] ?? 1)
                        }
                        .buttonStyle(.plain)
                        if item.id != needsAttention.last?.id { Divider().overlay(QJTheme.line) }
                    }
                }
                .padding(.horizontal, QJMetric.card)
                .qjCard()
            }
        }
    }

    @ViewBuilder
    private var recentGroup: some View {
        if recentlyAdded.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                GroupHeader("最近添加")
                VStack(spacing: 0) {
                    ForEach(Array(recentlyAdded)) { item in
                        Button { onOpenItem(item) } label: { ExpiryItemRow(item: item) }
                            .buttonStyle(.plain)
                        if item.id != recentlyAdded.last?.id { Divider().overlay(QJTheme.line) }
                    }
                }
                .padding(.horizontal, QJMetric.card)
                .qjCard()
            }
        }
    }

    @ViewBuilder
    private var locationGroup: some View {
        if !locationRows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GroupHeader("位置")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(locationRows, id: \.name) { row in
                        Button { onPickLocation(row.name) } label: {
                            HStack {
                                Text(row.name)
                                    .font(.subheadline)
                                    .foregroundStyle(QJTheme.ink)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(row.count)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(QJTheme.subtle)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                            .qjCard(fill: QJTheme.elevated, radius: 14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(row.name)，\(row.count) 件物品")
                    }
                }
            }
        }
    }
}

/// 分组标题。首页、物品页用的是同一套节奏。
struct GroupHeader: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(QJTheme.subtle)
            }
        }
        .padding(.top, QJMetric.section)
        .padding(.bottom, 10)
    }
}
