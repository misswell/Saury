import SwiftUI

/// 币种选择：常用币种排前面，下面是全部；长按可以把某个币种加进/移出常用。
struct CurrencyPickerSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    Section("常用币种") {
                        ForEach(commonEntries) { entry in
                            row(entry)
                        }
                    }
                    Section("全部币种") {
                        ForEach(restEntries) { entry in
                            row(entry)
                        }
                    }
                } else {
                    Section("搜索结果") {
                        ForEach(filtered) { entry in
                            row(entry)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "币种代码或名称")
            .navigationTitle("货币")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }

    private var allEntries: [CurrencyCatalog.Entry] {
        preferences.onlyCommonCurrencies ? commonEntries : CurrencyCatalog.all
    }

    private var commonEntries: [CurrencyCatalog.Entry] {
        preferences.commonCurrencies.compactMap { CurrencyCatalog.entry(for: $0) }
    }

    private var restEntries: [CurrencyCatalog.Entry] {
        CurrencyCatalog.all.filter { !preferences.commonCurrencies.contains($0.code) }
    }

    private var filtered: [CurrencyCatalog.Entry] {
        let lowered = searchText.lowercased()
        return CurrencyCatalog.all.filter {
            $0.code.lowercased().contains(lowered) || $0.name.contains(searchText)
        }
    }

    private func row(_ entry: CurrencyCatalog.Entry) -> some View {
        Button {
            selection = entry.code
            dismiss()
        } label: {
            HStack {
                Text(entry.code)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Text(entry.listTitle)
                    .foregroundStyle(.primary)
                Spacer()
                if selection == entry.code {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .contextMenu {
            Button {
                var common = preferences.commonCurrencies
                if common.contains(entry.code) {
                    common.removeAll { $0 == entry.code }
                } else {
                    common.append(entry.code)
                }
                preferences.commonCurrencies = common
            } label: {
                Label(
                    preferences.commonCurrencies.contains(entry.code) ? "移出常用" : "加入常用",
                    systemImage: "star"
                )
            }
        }
    }
}

/// 表单里的支付方式快捷选择：设置里维护的顺序就是这里的顺序。
struct PaymentQuickPicker: View {    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        NavigationStack {
            List {
                ForEach(["无"] + preferences.paymentMethods, id: \.self) { method in
                    Button {
                        selection = method
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "creditcard")
                                .foregroundStyle(.secondary)
                            Text(method).foregroundStyle(.primary)
                            Spacer()
                            if selection == method {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("支付方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }
}

/// 扣费周期：方块宫格 + 选中填充滑动，自定义时下方长出月数步进。
struct CyclePickerSheet: View {
    @Binding var cycle: BillingCycle
    @Binding var customMonths: Int
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(BillingCycle.allCases, id: \.self) { option in
                        tile(option)
                    }
                }
                .padding(.top, 6)

                if cycle == .custom {
                    HStack {
                        Text("每隔几个月扣一次").font(.subheadline)
                        Spacer()
                        Stepper(value: $customMonths, in: 1...36) {
                            Text("每 \(customMonths) 个月")
                                .font(.subheadline.monospacedDigit())
                                .contentTransition(.numericText())
                        }
                        .fixedSize()
                        .onChange(of: customMonths) { _, _ in SelectionHaptics.tick() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .sauryCard()
                    .animation(Motion.ui, value: customMonths)
                    .transition(.opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.96)))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, SauryTheme.screen)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SauryTheme.background)
            .navigationTitle("扣费周期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.bold)
                }
            }
            .animation(Motion.ui, value: cycle)
        }
    }

    private func tile(_ option: BillingCycle) -> some View {
        let isSelected = cycle == option
        return Button {
            SelectionHaptics.tick()
            cycle = option
        } label: {
            VStack(spacing: 7) {
                Image(systemName: option.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .symbolEffect(.bounce, value: isSelected)
                Text(option.title)
                    .font(.footnote.weight(isSelected ? .bold : .medium))
            }
            .foregroundStyle(isSelected ? .white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: SauryTheme.cardRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 9, y: 4)
                } else {
                    RoundedRectangle(cornerRadius: SauryTheme.cardRadius, style: .continuous)
                        .fill(SauryTheme.surface)
                }
            }
            .scaleEffect(isSelected ? 1.03 : 1)
            .animation(Motion.pop, value: isSelected)
        }
        .buttonStyle(Pressable(scale: 0.93, animation: Motion.pop))
    }
}
