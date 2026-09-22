import SwiftUI

/// 「全部物品」页（方案 §15–§18）。搜索、筛选、排序都在 `ItemQuery` 里判定，
/// 这一页只负责把条件摆出来。
struct ItemsView: View {
    /// 未经筛选的全部物品：状态筛选要能查到已用完的记录（方案 §17）。
    let items: [ExpiryItem]
    @Binding var query: ItemQuery
    let onOpenItem: (ExpiryItem) -> Void
    let onAdd: () -> Void
    let onAction: (ExpiryAction, ExpiryItem) -> Void
    let onEdit: (ExpiryItem) -> Void

    @State private var showingFilter = false

    private var results: [ExpiryItem] { query.results(in: items) }

    private var isGroupedByUrgency: Bool {
        query.sort == .earliestExpiry || query.sort == .latestExpiry
    }

    private var batchCounts: [String: Int] {
        Dictionary(grouping: items.filter(\.isActive), by: { $0.productKey }).mapValues(\.count)
    }

    private struct UrgencySection: Identifiable {
        let urgency: ExpiryUrgency
        let items: [ExpiryItem]
        var id: String { urgency.id }
    }

    private var sections: [UrgencySection] {
        Dictionary(grouping: results, by: { $0.urgency })
            .map { UrgencySection(urgency: $0.key, items: $0.value) }
            .sorted { $0.urgency.sortWeight < $1.urgency.sortWeight }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(QJTheme.canvas)
        .searchable(text: $query.searchText, prompt: "名称、品牌、条码、批次、位置")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("排序方式", selection: $query.sort) {
                        ForEach(ItemSort.allCases) { sort in
                            Label(sort.title, systemImage: sort.symbolName).tag(sort)
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("排序方式：\(query.sort.title)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFilter = true
                } label: {
                    Image(systemName: query.isFiltering
                         ? "line.3.horizontal.decrease.circle.fill"
                         : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("筛选物品")
            }
        }
        .sheet(isPresented: $showingFilter) {
            NavigationStack {
                ItemFilterSheet(items: items, query: $query)
                    .navigationTitle("筛选")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { showingFilter = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { showingFilter = false } }
                    }
            }
            .presentationDetents([.large])
        }
    }

    private var list: some View {
        List {
            categoryChips
            if isGroupedByUrgency {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in row(item) }
                    } header: {
                        sectionHeader(section)
                    }
                }
            } else {
                Section {
                    ForEach(results) { item in row(item) }
                } header: {
                    Text("\(results.count) 件物品")
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if results.isEmpty && !items.isEmpty {
                ContentUnavailableView {
                    Label("没有符合条件的物品", systemImage: "magnifyingglass")
                } description: {
                    Text("换个关键词，或者把筛选条件放宽一点。")
                } actions: {
                    if query.isFiltering {
                        Button("清除筛选") { query = ItemQuery(sort: query.sort) }
                    }
                }
            }
        }
    }

    private var categoryChips: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ExpiryCategory.allCases) { category in
                        ChipButton(
                            title: category.title,
                            isOn: query.categories.contains(category)
                        ) {
                            if query.categories.contains(category) {
                                query.categories.remove(category)
                            } else {
                                query.categories.insert(category)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func sectionHeader(_ section: UrgencySection) -> some View {
        HStack(spacing: 6) {
            Circle().fill(section.urgency.tint).frame(width: 7, height: 7)
            Text(section.urgency.title)
            Text("\(section.items.count)").foregroundStyle(QJTheme.subtle)
        }
        .font(.footnote.weight(.semibold))
    }

    private func row(_ item: ExpiryItem) -> some View {
        Button { onOpenItem(item) } label: {
            ExpiryItemRow(item: item, batchCount: batchCounts[item.productKey] ?? 1)
        }
        .listRowBackground(QJTheme.elevated)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            ForEach(resolutionActions(for: item)) { action in
                Button(action.title(for: item)) { onAction(action, item) }
                    .tint(action == .discarded || action == .cancelled ? .red : QJTheme.calm)
            }
        }
        .swipeActions(edge: .leading) {
            Button("明天再提醒") { onAction(.snoozed, item) }
                .tint(QJTheme.subtle)
            Button("编辑") { onEdit(item) }
                .tint(.blue)
        }
        .contextMenu {
            Button("编辑", systemImage: "pencil") { onEdit(item) }
            ForEach(ExpiryAction.available(for: item)) { action in
                Button(action.title(for: item), systemImage: action.symbolName) { onAction(action, item) }
            }
        }
    }

    /// 滑动只放「把这件事处理掉」的动作（方案 §36）；归档留在详情页，
    /// 因为它不是一个日常手势。
    private func resolutionActions(for item: ExpiryItem) -> [ExpiryAction] {
        ExpiryActionGroup(for: item).actions
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有记录", systemImage: "square.grid.2x2")
        } description: {
            Text("扫描包装，期见会替你记住有效期。")
        } actions: {
            Button("添加物品") { onAdd() }
                .buttonStyle(.borderedProminent)
                .tint(QJTheme.accent)
        }
    }
}

struct ChipButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .white : QJTheme.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(isOn ? QJTheme.accent : QJTheme.elevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
