import SwiftUI
import SwiftData
import PhotosUI

/// 新增 / 编辑订阅。上半是跟图标同色的 hero 区（图标、名称、金额、币种周期），
/// 下半是分组表单。保存不弹提示，直接收。
struct AddSubscriptionView: View {
    var editing: Subscription?
    var prefillName: String = ""

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences
    @FocusState private var focusedField: Field?

    enum Field { case name, price, plan, note, share }

    // MARK: - 表单状态

    @State private var name = ""
    @State private var priceText = ""
    @State private var currencyCode = "CNY"
    @State private var cycle: BillingCycle = .monthly
    @State private var customMonths = 2
    @State private var plan = ""
    @State private var categoryID = "efficiency"
    @State private var state: SubscriptionState = .autoRenew
    @State private var startDate = Date()
    @State private var endDateEnabled = false
    @State private var endDate = Date().addingTimeInterval(365 * 86400)
    @State private var reminderDays = 3
    @State private var shareEnabled = false
    @State private var shareHeadcount = 2
    @State private var shareMode: ShareMode = .even
    @State private var shareMyText = ""
    @State private var paymentMethod = "无"
    @State private var notes = ""

    @State private var iconSymbol: String? = nil
    @State private var iconImageFile: String? = nil
    @State private var iconColorHex: String? = nil
    @State private var colorHexes: [String] = []

    @State private var showingIconPicker = false
    @State private var showingCurrencyPicker = false
    @State private var showingPeriodPicker = false
    @State private var showingPaymentPicker = false
    @State private var showingStartCalendar = false

    @State private var heroPop = false

    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    hero
                        .staged(0, edge: .top)
                    colorSection
                        .staged(1)
                    basicSection
                        .staged(2)
                    reminderSection
                        .staged(3)
                    shareSection
                        .staged(4)
                    paymentSection
                        .staged(5)
                }
                .padding(.horizontal, SauryTheme.screen)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(SauryTheme.background)
            .navigationTitle(isEditing ? "编辑订阅" : "新增订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .fontWeight(.bold)
                        .foregroundStyle(canSave ? Color(hex: preferences.accentHex) ?? .accentColor : Color.secondary)
                        .scaleEffect(canSave ? 1 : 0.94)
                        .animation(Motion.ui, value: canSave)
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingIconPicker) {
                IconPickerSheet(
                    symbol: $iconSymbol,
                    imageFile: $iconImageFile,
                    colorHex: $iconColorHex
                )
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingCurrencyPicker) {
                CurrencyPickerSheet(selection: $currencyCode)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingPeriodPicker) {
                CyclePickerSheet(cycle: $cycle, customMonths: $customMonths)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingPaymentPicker) {
                PaymentQuickPicker(selection: $paymentMethod)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .interactiveDismissDisabled(focusedField != nil)
        .onAppear(perform: loadInitial)
        #if DEBUG
        .task { await runQAOpsIfNeeded() }
        #endif
    }

    #if DEBUG
    /// 模拟器操作验证用（`-saury-ops`）。命令里没有 Accessibility 权限，合成不了真实点击，
    /// 所以让表单自己填一次用户会填的字段，再按真的保存按钮走 `save()`。
    /// 新增和编辑共用一个入口，靠 `editing` 分支；结论要从数据库和截图外部核对，这里不算数。
    private func runQAOpsIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-ops") else { return }
        try? await Task.sleep(for: .milliseconds(1000))
        if editing != nil {
            priceText = "68"
            cycle = .yearly
            state = .inactive
        } else {
            name = "QA 自动验证"
            plan = "标准版"
            priceText = "25"
            currencyCode = "CNY"
            cycle = .monthly
            reminderDays = 3
        }
        save()
    }
    #endif

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Hero

    private var heroTint: Color {
        if let hex = iconColorHex, let color = Color(hex: hex) { return color }
        if let file = iconImageFile {
            return IconTint.dominantColor(of: IconImageStore.shared.image(for: file)) ?? (Color(hex: preferences.accentHex) ?? .accentColor)
        }
        return Color(hex: preferences.accentHex) ?? .accentColor
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Button {
                SelectionHaptics.impact(.light)
                showingIconPicker = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    heroIcon
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: heroTint.opacity(0.35), radius: 12, y: 6)
                        .scaleEffect(heroPop ? 1.07 : 1)
                    Image(systemName: "paperclip")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(white: 0.25).opacity(0.9)))
                        .offset(x: 4, y: 4)
                }
            }
            .buttonStyle(Pressable(scale: 0.94, animation: Motion.pop))
            .padding(.top, 4)
            .onChange(of: iconSignature) { _, _ in bumpHeroIcon() }

            TextField("名称", text: $name)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { focusedField = .price }

            HStack(spacing: 6) {
                Text(CurrencyCatalog.symbol(for: currencyCode))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .opacity(priceText.isEmpty && focusedField != .price ? 1 : 0.85)
                TextField("0", text: $priceText)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .price)
                    .frame(width: 90)
            }

            HStack(spacing: 8) {
                Button { showingCurrencyPicker = true } label: {
                    HStack(spacing: 4) {
                        Text(currencyCode).font(.footnote.weight(.bold))
                            .contentTransition(.opacity)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.white.opacity(0.22)))
                }
                .buttonStyle(Pressable(scale: 0.92))

                Button { showingPeriodPicker = true } label: {
                    HStack(spacing: 4) {
                        Text(cycleTitle).font(.footnote.weight(.bold))
                            .contentTransition(.opacity)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.white.opacity(0.22)))
                }
                .buttonStyle(Pressable(scale: 0.92))
            }
            .animation(Motion.ui, value: cycleTitle)
            .animation(Motion.ui, value: currencyCode)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [heroTint.opacity(0.85), heroTint],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(Motion.page, value: heroTint)
    }

    /// 图标换了就弹一下：让「选中了什么」这件事有身体反应。
    private var iconSignature: String { "\(iconSymbol ?? "")|\(iconImageFile ?? "")" }

    private func bumpHeroIcon() {
        SelectionHaptics.tick()
        withAnimation(.spring(duration: 0.14, bounce: 0.5)) { heroPop = true }
        withAnimation(Motion.pop.delay(0.14)) { heroPop = false }
    }

    private var heroIcon: some View {
        Group {
            if let file = iconImageFile, let image = IconImageStore.shared.image(for: file) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let symbol = iconSymbol, UIImage(systemName: symbol) != nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.white.opacity(0.25))
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.white.opacity(0.25))
                    Text(name.isEmpty ? "＋" : String(name.prefix(1)).uppercased())
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var cycleTitle: String {
        if case .custom = cycle { return "每 \(customMonths) 月" }
        return cycle.title
    }

    // MARK: - 卡片颜色

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("卡片颜色").font(.subheadline.weight(.medium))
                Spacer()
                RoundedRectangle(cornerRadius: 3)
                    .fill(colorPreviewGradient)
                    .frame(width: 46, height: 12)
            }
            HStack(spacing: 12) {
                autoColorDot
                ForEach(Palette.colors.prefix(6), id: \.self) { hex in
                    colorDot(hex: hex)
                }
                Text("…").font(.caption).foregroundStyle(.tertiary)
            }
            .animation(Motion.pop, value: colorHexes)
            HStack(spacing: 8) {
                ForEach(Palette.gradients, id: \.self) { gradient in
                    gradientPill(gradient)
                }
            }
            .animation(Motion.pop, value: colorHexes)
            Text("列表卡片的底色。「自动」从图标里取颜色，黑白图标用灰色。也可以自己选：点一个是单色，点两三个是渐变，数字是顺序（1 是主色）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .sauryCard()
    }

    private var colorPreviewGradient: AnyShapeStyle {
        if colorHexes.isEmpty { return AnyShapeStyle(heroTint) }
        return AnyShapeStyle(LinearGradient(colors: colorHexes.compactMap { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing))
    }

    private var autoColorDot: some View {
        Button {
            SelectionHaptics.tick()
            colorHexes = []
        } label: {
            Text("自动")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(colorHexes.isEmpty ? .white : .primary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(colorHexes.isEmpty ? heroTint : SauryTheme.surfaceElevated))
                .overlay(Circle().stroke(colorHexes.isEmpty ? Color.white : .clear, lineWidth: 2))
                .scaleEffect(colorHexes.isEmpty ? 1.06 : 1)
        }
        .buttonStyle(Pressable(scale: 0.9))
    }

    private func colorDot(hex: String) -> some View {
        let selected = colorHexes.contains(hex)
        return Button {
            SelectionHaptics.tick()
            toggleColor(hex)
        } label: {
            Circle()
                .fill(Palette.color(hex))
                .frame(width: 40, height: 40)
                .overlay(colorBadge(hex))
                .scaleEffect(selected ? 1.06 : 1)
                .shadow(color: selected ? Palette.color(hex).opacity(0.5) : .clear, radius: 6, y: 3)
        }
        .buttonStyle(Pressable(scale: 0.9))
    }

    private func gradientPill(_ gradient: [String]) -> some View {
        let selected = colorHexes == gradient
        return Button {
            SelectionHaptics.tick()
            colorHexes = gradient
        } label: {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: gradient.compactMap { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing))
                .frame(width: 40, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Color.primary : .clear, lineWidth: 2)
                )
                .scaleEffect(selected ? 1.08 : 1)
        }
        .buttonStyle(Pressable(scale: 0.9))
    }

    private func toggleColor(_ hex: String) {
        if colorHexes == [hex] {
            colorHexes = []
        } else if colorHexes.count == 1, colorHexes[0] == hex {
            colorHexes = []
        } else if colorHexes.contains(hex) {
            colorHexes.removeAll { $0 == hex }
        } else {
            colorHexes.append(hex)
            if colorHexes.count > 3 { colorHexes = [hex] }
        }
    }

    @ViewBuilder
    private func colorBadge(_ hex: String) -> some View {
        if let index = colorHexes.firstIndex(of: hex) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("套餐").font(.subheadline)
                Spacer()
                TextField("如 Plus", text: $plan)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .plan)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider().overlay(SauryTheme.line).padding(.leading, 14)

            pickerRow("分类", value: categoryTitle) {
                Menu {
                    Picker("分类", selection: $categoryID) {
                        ForEach(preferences.categories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                } label: {
                    pickerLabel
                }
            }
            Divider().overlay(SauryTheme.line).padding(.leading, 14)

            pickerRow("状态", value: state.title) {
                Menu {
                    Picker("状态", selection: $state) {
                        ForEach(SubscriptionState.allCases, id: \.self) { state in
                            Text(state.title).tag(state)
                        }
                    }
                } label: {
                    pickerLabel
                }
            }
            Divider().overlay(SauryTheme.line).padding(.leading, 14)

            pickerRow("开始时间", value: QJFormat.longDate(startDate), showsChevron: true,
                      expanded: showingStartCalendar) {
                Button { withAnimation(Motion.ui) { showingStartCalendar.toggle() } } label: { pickerLabel }
            }

            if showingStartCalendar {
                DatePicker(
                    "",
                    selection: $startDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(heroTint)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.97)))
            }
        }
        .sauryCard()
        .animation(Motion.ui, value: showingStartCalendar)
    }

    private var categoryTitle: String {
        preferences.category(withID: categoryID).name
    }

    private var pickerLabel: some View {
        HStack(spacing: 4) {
            Text("").hidden()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func pickerRow<Picker: View>(_ title: String, value: String, showsChevron: Bool = false,
                                         expanded: Bool = false, @ViewBuilder picker: () -> Picker) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            picker()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            } else {
                Text(value).font(.subheadline)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .animation(Motion.ui, value: value)
        .animation(Motion.ui, value: expanded)
    }

    // MARK: - 提醒与结束

    private var reminderSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("提前提醒").font(.subheadline)
                Spacer()
                Stepper(value: $reminderDays, in: 0...30) {
                    Text(reminderDays == 0 ? "不提醒" : "\(reminderDays) 天")
                        .font(.subheadline.monospacedDigit())
                        .contentTransition(.numericText())
                }
                .fixedSize()
                .onChange(of: reminderDays) { _, _ in SelectionHaptics.tick() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .animation(Motion.ui, value: reminderDays)
            Divider().overlay(SauryTheme.line).padding(.leading, 14)

            Toggle(isOn: $endDateEnabled) {
                Text("设置结束日期").font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .onChange(of: endDateEnabled) { _, on in if on { SelectionHaptics.tick() } }

            if endDateEnabled {
                Divider().overlay(SauryTheme.line).padding(.leading, 14)
                DatePicker("结束于", selection: $endDate, displayedComponents: .date)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.97)))
            }
        }
        .sauryCard()
        .animation(Motion.ui, value: endDateEnabled)
        .tint(heroTint)
    }

    // MARK: - 分摊

    private var shareSection: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $shareEnabled) {
                Text("费用分摊").font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .onChange(of: shareEnabled) { _, on in if on { SelectionHaptics.tick() } }

            if shareEnabled {
                shareRows
                    .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98)))
            }
        }
        .sauryCard()
        .animation(Motion.ui, value: shareEnabled)
        .animation(Motion.ui, value: shareMode)
        .tint(heroTint)
    }

    private var shareRows: some View {
        VStack(spacing: 0) {
            Divider().overlay(SauryTheme.line).padding(.leading, 14)
            HStack {
                Text("总人数（含自己）").font(.subheadline)
                Spacer()
                Stepper(value: $shareHeadcount, in: 2...20) {
                    Text("\(shareHeadcount) 人")
                        .font(.subheadline.monospacedDigit())
                        .contentTransition(.numericText())
                }
                .fixedSize()
                .onChange(of: shareHeadcount) { _, _ in SelectionHaptics.tick() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .animation(Motion.ui, value: shareHeadcount)
            Divider().overlay(SauryTheme.line).padding(.leading, 14)

            HStack {
                Text("分摊方式").font(.subheadline)
                Spacer()
                Menu {
                    Picker("分摊方式", selection: $shareMode) {
                        ForEach(ShareMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(shareMode.title).font(.subheadline)
                            .contentTransition(.opacity)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if shareMode == .custom {
                Divider().overlay(SauryTheme.line).padding(.leading, 14)
                HStack {
                    Text("我的份额").font(.subheadline)
                    Spacer()
                    TextField("0", text: $shareMyText)
                        .font(.subheadline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .frame(width: 90)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().overlay(SauryTheme.line).padding(.leading, 14)
            HStack {
                Text("我每期付").font(.subheadline)
                Spacer()
                Text(mySharePerCycle)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if shareMode == .even {
                Divider().overlay(SauryTheme.line).padding(.leading, 14)
                HStack {
                    Text("其余每人").font(.subheadline)
                    Spacer()
                    Text(mySharePerCycle)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("上面的金额填账单上的总额。总览、月均和各项统计只计入你的份额。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .padding(.top, 4)
        }
    }

    private var mySharePerCycle: String {
        let minor: Int
        if shareMode == .custom {
            minor = Int(((Double(shareMyText.replacingOccurrences(of: ",", with: ".")) ?? 0) * 100).rounded())
        } else {
            minor = Int((Double(priceMinor) / Double(shareHeadcount)).rounded())
        }
        return Money(minorUnits: minor, currencyCode: currencyCode).formatted + "/" + cycleShort
    }

    private var cycleShort: String {
        switch cycle {
        case .weekly: return "周"
        case .monthly: return "月"
        case .quarterly: return "季"
        case .semiannual: return "半年"
        case .yearly: return "年"
        case .custom: return "\(customMonths)月"
        case .oneTime: return "次"
        }
    }

    // MARK: - 支付方式与备注

    private var paymentSection: some View {
        VStack(spacing: 0) {
            pickerRow("支付方式", value: paymentMethod, showsChevron: false) {
                Button { showingPaymentPicker = true } label: {
                    HStack(spacing: 4) {
                        Text(paymentMethod).font(.subheadline)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Divider().overlay(SauryTheme.line).padding(.leading, 14)
            TextField("写点什么，如账号、优惠、共享成员…", text: $notes, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...3)
                .focused($focusedField, equals: .note)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .sauryCard()
    }

    // MARK: - 数据

    private var priceMinor: Int {
        Int(((Double(priceText.replacingOccurrences(of: ",", with: ".")) ?? 0) * 100).rounded())
    }

    private func loadInitial() {
        guard let subscription = editing else {
            reminderDays = preferences.defaultReminderDays
            currencyCode = preferences.defaultCurrency
            if !prefillName.isEmpty {
                name = prefillName
                focusedField = .price
            }
            return
        }
        name = subscription.name
        priceText = subscription.priceMinorUnits % 100 == 0
            ? String(subscription.priceMinorUnits / 100)
            : String(format: "%.2f", subscription.priceMajor)
        currencyCode = subscription.currencyCode
        cycle = subscription.cycle
        customMonths = subscription.customMonths
        plan = subscription.plan
        categoryID = subscription.categoryRawValue
        state = subscription.state
        startDate = subscription.startDate
        endDateEnabled = subscription.endDate != nil
        endDate = subscription.endDate ?? Date().addingTimeInterval(365 * 86400)
        reminderDays = subscription.reminderDays
        shareEnabled = subscription.shareEnabled
        shareHeadcount = subscription.shareHeadcount
        shareMode = subscription.shareMode
        shareMyText = subscription.shareMode == .custom
            ? String(format: "%.2f", Double(subscription.shareMyMinorUnits) / 100)
            : ""
        paymentMethod = subscription.paymentMethod.isEmpty ? "无" : subscription.paymentMethod
        notes = subscription.notes
        iconSymbol = subscription.iconSymbolName
        iconImageFile = subscription.iconImageFile
        iconColorHex = subscription.iconColorHex
        colorHexes = subscription.colorSpec.orderedHexes
    }

    private func save() {
        let shareMyMinor = shareMode == .custom
            ? Int(((Double(shareMyText.replacingOccurrences(of: ",", with: ".")) ?? 0) * 100).rounded())
            : 0

        if let subscription = editing {
            subscription.name = name.trimmingCharacters(in: .whitespaces)
            subscription.plan = plan.trimmingCharacters(in: .whitespaces)
            subscription.iconSymbolName = iconSymbol
            subscription.iconImageFile = iconImageFile
            subscription.iconColorHex = iconColorHex
            subscription.colorSpec = CardColorSpec(hexes: colorHexes)
            subscription.priceMinorUnits = priceMinor
            subscription.currencyCode = currencyCode
            subscription.cycle = cycle
            subscription.customMonths = customMonths
            subscription.categoryRawValue = categoryID
            subscription.state = state
            subscription.startDate = startDate
            subscription.endDate = endDateEnabled ? endDate : nil
            subscription.reminderDays = reminderDays
            subscription.shareEnabled = shareEnabled
            subscription.shareHeadcount = shareHeadcount
            subscription.shareMode = shareMode
            subscription.shareMyMinorUnits = shareMyMinor
            subscription.paymentMethod = paymentMethod == "无" ? "" : paymentMethod
            subscription.notes = notes
            subscription.markUpdated()
        } else {
            let subscription = Subscription(
                name: name.trimmingCharacters(in: .whitespaces),
                plan: plan.trimmingCharacters(in: .whitespaces),
                iconSymbolName: iconSymbol,
                iconImageFile: iconImageFile,
                iconColorHex: iconColorHex,
                colorSpec: CardColorSpec(hexes: colorHexes),
                priceMinorUnits: priceMinor,
                currencyCode: currencyCode,
                cycle: cycle,
                customMonths: customMonths,
                category: categoryID,
                state: state,
                startDate: startDate,
                endDate: endDateEnabled ? endDate : nil,
                reminderDays: reminderDays,
                shareEnabled: shareEnabled,
                shareHeadcount: shareHeadcount,
                shareMode: shareMode,
                shareMyMinorUnits: shareMyMinor,
                paymentMethod: paymentMethod == "无" ? "" : paymentMethod,
                notes: notes
            )
            modelContext.insert(subscription)
        }
        SelectionHaptics.success()
        dismiss()
    }
}

extension Subscription {
    var priceMajor: Double { Double(priceMinorUnits) / 100 }
}
