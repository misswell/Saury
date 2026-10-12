import SwiftUI
import SwiftData

/// 订阅列表的筛选器：分类 / 状态 / 支付方式 / 币种，多选，存偏好。
struct SubscriptionFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences
    @Query private var subscriptions: [Subscription]

    private var usedPaymentMethods: [String] {
        var seen: [String] = []
        for subscription in subscriptions where !subscription.paymentMethod.isEmpty {
            if !seen.contains(subscription.paymentMethod) { seen.append(subscription.paymentMethod) }
        }
        return seen
    }

    private var usedCurrencies: [String] {
        var seen: [String] = []
        for subscription in subscriptions {
            if !seen.contains(subscription.currencyCode) { seen.append(subscription.currencyCode) }
        }
        return seen
    }

    var body: some View {
        NavigationStack {
            List {
                Section("分类") {
                    chipGrid(preferences.categories.map { ($0.id, $0.name) }, selected: Binding(
                        get: { preferences.listFilters.categoryIDs },
                        set: { preferences.listFilters.categoryIDs = $0 }
                    ))
                }
                Section("状态") {
                    chipGrid(SubscriptionState.allCases.map { ($0.rawValue, $0.title) }, selected: Binding(
                        get: { preferences.listFilters.states.map(\.rawValue) },
                        set: { preferences.listFilters.states = $0.compactMap(SubscriptionState.init(rawValue:)) }
                    ))
                }
                if !usedPaymentMethods.isEmpty {
                    Section("支付方式") {
                        chipGrid(usedPaymentMethods.map { ($0, $0) }, selected: Binding(
                            get: { preferences.listFilters.paymentMethods },
                            set: { preferences.listFilters.paymentMethods = $0 }
                        ))
                    }
                }
                if !usedCurrencies.isEmpty {
                    Section("币种") {
                        chipGrid(usedCurrencies.map { ($0, $0) }, selected: Binding(
                            get: { preferences.listFilters.currencies },
                            set: { preferences.listFilters.currencies = $0 }
                        ))
                    }
                }
                Section {
                    Button("清除全部筛选") { preferences.listFilters = .init() }
                        .foregroundStyle(Color.accentColor)
                }
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func chipGrid(_ items: [(id: String, title: String)], selected: Binding<[String]>) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.id) { item in
                let isOn = selected.wrappedValue.contains(item.id)
                Button {
                    SelectionHaptics.tick()
                    if isOn {
                        selected.wrappedValue.removeAll { $0 == item.id }
                    } else {
                        selected.wrappedValue.append(item.id)
                    }
                } label: {
                    Text(item.title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(isOn ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(isOn ? Color.accentColor : SauryTheme.surfaceElevated)
                        )
                        .overlay(Capsule().stroke(isOn ? Color.clear : SauryTheme.line, lineWidth: 1))
                        .scaleEffect(isOn ? 1.05 : 1)
                        .shadow(color: isOn ? Color.accentColor.opacity(0.4) : .clear, radius: 6, y: 3)
                }
                .buttonStyle(Pressable(scale: 0.92, animation: Motion.pop))
                .animation(Motion.pop, value: isOn)
            }
        }
    }
}

/// 简易流式布局：筛选项宽度不一，按行排。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
