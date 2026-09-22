import SwiftUI

/// 筛选面板（方案 §17）。每个维度都是多选，空集表示不限。
struct ItemFilterSheet: View {
    let items: [ExpiryItem]
    @Binding var query: ItemQuery

    var body: some View {
        Form {
            Section("到期时间") {
                ForEach(ExpiryUrgency.allCases) { urgency in
                    toggleRow(urgency.title, urgency, in: \.urgencies)
                }
            }

            Section("状态") {
                ForEach(ExpiryState.allCases) { state in
                    toggleRow(state.title, state, in: \.states)
                }
            }

            Section("分类") {
                ForEach(ExpiryCategory.allCases) { category in
                    toggleRow(category.title, category, in: \.categories)
                }
            }

            Section("位置") {
                ForEach(locationOptions, id: \.self) { location in
                    toggleRow(location, location, in: \.locations)
                }
            }

            Section("记录完整度") {
                Toggle("只看有图片的", isOn: $query.hasImageOnly)
                Toggle("只看有条码的", isOn: $query.hasBarcodeOnly)
            }

            if query.isFiltering {
                Section {
                    Button("清除全部筛选", role: .destructive) {
                        query = ItemQuery(sort: query.sort)
                    }
                }
            }
        }
        .tint(QJTheme.accent)
    }

    /// 清单里的位置 + 物品实际用到但没进清单的位置。
    private var locationOptions: [String] {
        var seen = Set<String>()
        return (LocationCatalog.all + LocationCatalog.usedLocations(in: items)).filter { seen.insert($0).inserted }
    }

    private func toggleRow<T: Hashable>(_ title: String, _ value: T, in keyPath: WritableKeyPath<ItemQuery, Set<T>>) -> some View {
        Toggle(isOn: Binding(
            get: { query[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn { query[keyPath: keyPath].insert(value) } else { query[keyPath: keyPath].remove(value) }
            }
        )) {
            Text(title)
        }
    }
}
