import SwiftUI
import SwiftData
import os

/// 订阅详情。半高 sheet 弹出：状态、单价、下次扣费、花费、时间轴、其他。
struct SubscriptionDetailView: View {
    let subscription: Subscription

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences
    @Query private var events: [SubscriptionEvent]

    /// 这一页自己的那一层。编辑本页和记一笔新事件都从这里走：
    /// 同一层挂两张 sheet，SwiftUI 只认第一张，第二张点下去没反应。
    private enum Layer: Identifiable {
        case subscriptionEditor
        case eventEditor

        var id: Self { self }
    }

    @State private var layer: Layer?
    @State private var feedback: WriteFeedback?

    private var repository: SubscriptionRepository { SubscriptionRepository(context: modelContext) }
    /// 触感、撤销、那句话的写法跟列表页同一份实现（`SubscriptionActions`）。
    /// 失败提示挂在本页那一条上（sheet 会盖住根视图的），撤销入口挂根视图（这一页一关就没了）。
    private var actions: SubscriptionActions {
        SubscriptionActions(repository: repository, local: $feedback)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                        .staged(0, edge: .top)
                    statusSection
                        .staged(1)
                    spendSection
                        .staged(2)
                    timelineSection
                        .staged(3)
                    otherSection
                        .staged(4)
                }
                .padding(.horizontal, SauryTheme.screen)
                .padding(.bottom, 30)
            }
            .background(SauryTheme.background)
            .navigationTitle("订阅详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 2) {
                        Button {
                            SelectionHaptics.tick()
                            // 编辑挂在本页自己这一层：不关详情、不换父层的 sheet，
                            // 所以关掉编辑就是回到刚才那条订阅。
                            layer = .subscriptionEditor
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color(hex: preferences.accentHex) ?? .accentColor))
                        }
                        .buttonStyle(Pressable(scale: 0.88, animation: Motion.pop))
                        Menu {
                            Button {
                                actions.setPinned([subscription], !subscription.isPinned)
                            } label: {
                                Label(subscription.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                            }
                            Button(action: archiveSubscription) {
                                Label("归档", systemImage: "archivebox")
                            }
                            Menu {
                                ForEach(SubscriptionState.allCases, id: \.self) { state in
                                    Button {
                                        actions.setState([subscription], to: state)
                                    } label: {
                                        if subscription.state == state {
                                            Label(state.title, systemImage: "checkmark")
                                        } else {
                                            Text(state.title)
                                        }
                                    }
                                }
                            } label: {
                                Label("状态：\(subscription.state.title)", systemImage: "circle.lefthalf.filled")
                            }
                            Button(role: .destructive) {
                                // 落成了才关页；没落成页面留在原地，错误显示在本页那条上。
                                if actions.moveToTrash([subscription]) { dismiss() }
                            } label: {
                                Label("移入回收站", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .sheet(item: $layer) { layer in
                switch layer {
                case .subscriptionEditor:
                    AddSubscriptionView(editing: subscription)
                        .presentationDragIndicator(.visible)
                case .eventEditor:
                    SubscriptionEventEditor(subscription: subscription)
                        .presentationDetents([.medium])
                }
            }
        }
        .writeFeedback($feedback)
        #if DEBUG
        // 模拟器操作验证用。命令里没有辅助功能权限，合成不了点击，就直接调界面上那个按钮
        // 走的同一个方法，让这一层真的把改动写进库，再从数据库和截图外面核对。
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-saury-ops") {
                opsProbe("详情出现，1 秒后按归档")
                try? await Task.sleep(for: .milliseconds(1000))
                archiveSubscription()
            }
            if arguments.contains("-saury-nav") {
                // 详情→编辑：按的就是工具栏那支笔的同一句 `layer = .subscriptionEditor`。
                // 每一步都留一行日志：截图只能证明「这一帧长什么样」，
                // 外面按秒去猜哪一帧是哪一步猜不准，时间戳才对得上。
                probe("详情出现")
                try? await Task.sleep(for: .milliseconds(1400))
                layer = .subscriptionEditor
                probe("打开编辑层")
                // 再把编辑关掉：这一层是详情自己挂的，关掉之后该还看见这一条的详情，
                // 而不是连详情页一起掉回列表。
                try? await Task.sleep(for: .seconds(6))
                layer = nil
                probe("关掉编辑层")
            }
        }
        #endif
    }

    #if DEBUG
    /// 导航探针的时间戳。类别单开一个 `probe`，读日志时不用在满屏 data 里捞。
    private static let probeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")

    private func probe(_ step: String) {
        Self.probeLogger.log("导航探针 \(step, privacy: .public)")
    }

    /// 同一层的两步分属两个剧本：`-saury-nav` 看的是详情页的栈，`-saury-ops` 看的是归档闭环。
    /// 打同一个标签，读日志时就分不出哪一步是谁跑的了。
    private func opsProbe(_ step: String) {
        Self.probeLogger.log("操作探针 \(step, privacy: .public)")
    }
    #endif

    /// 归档：写库成功后才关页。失败的话页面留在原地，错误显示在本页那条上。
    private func archiveSubscription() {
        let archived = actions.archive([subscription])
        #if DEBUG
        opsProbe(archived ? "归档成功，撤销条该在根视图上" : "归档失败，错误显示在本页那一条上")
        #endif
        if archived { dismiss() }
    }

    private var relatedEvents: [SubscriptionEvent] {
        events
            .filter { $0.subscriptionID == subscription.id }
            .sorted { $0.happenedAt > $1.happenedAt }
    }

    // MARK: - 头部卡

    private var headerCard: some View {
        VStack(spacing: 10) {
            SubscriptionIconView(subscription: subscription, size: 64, onColorCard: true)
            Text(subscription.name)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 8) {
                chip(preferences.category(withID: subscription.categoryRawValue).name,
                     color: preferences.category(withID: subscription.categoryRawValue).color)
                chip(subscription.state.title, color: .white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            CardGradient(hexes: subscription.colorSpec.orderedHexes.isEmpty
                ? [IconTintHelper.hexFallback(for: subscription, preferences: preferences)]
                : subscription.colorSpec.orderedHexes)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.35)))
    }

    // MARK: - 状态

    private var statusSection: some View {
        SectionCard(title: "当前状态") {
            row("状态", value: subscription.state == .inactive ? "已停用" : "生效中")
            row("当前单价", value: priceText)
            if let next = BillingMath.nextChargeDate(for: subscription) {
                HStack {
                    Text("下次扣费").font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(QJFormat.longDate(next)).font(.subheadline.monospacedDigit())
                        Text(QJFormat.relativeDay(next))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                    }
                }
                .padding(.vertical, 9)
            }
            row("开始时间", value: QJFormat.longDate(subscription.startDate))
            if let end = subscription.endDate {
                row("结束于", value: QJFormat.longDate(end))
            }
            // 开关和天数各说各的：0 天是「扣费当天」，不是「不提醒」（§5.1）。
            row("扣费提醒", value: subscription.remindersEnabled
                ? (subscription.reminderDays == 0 ? "扣费当天" : "提前 \(subscription.reminderDays) 天")
                : "不提醒")
        }
    }

    private var priceText: String {
        let mine = subscription.myAmount
        let base = "\(mine.formatted)/\(cycleWord)"
        if preferences.showOriginalCurrency, mine.currencyCode != preferences.defaultCurrency {
            return base
        }
        return base
    }

    private var cycleWord: String {
        switch subscription.cycle {
        case .weekly: return "周"
        case .monthly: return "月"
        case .quarterly: return "季"
        case .semiannual: return "半年"
        case .yearly: return "年"
        case .custom: return "\(subscription.customMonths)月"
        case .oneTime: return "次"
        }
    }

    // MARK: - 花费

    private var spendSection: some View {
        SectionCard(title: "花费") {
            let totals = detailStats.cumulative()
            let buckets = detailStats.monthlyBuckets()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    AnimatedNumber(value: totals.combined.majorValue,
                                   format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                                   currencyCode: totals.combined.currencyCode).formattedGrouped },
                                   font: SauryTheme.amountFont(size: 24),
                                   countsFromZeroOnAppear: true)
                    Spacer()
                    Text("共 \(totals.chargeCount) 期")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                ForEach(Array(buckets.enumerated()), id: \.element.monthStart) { index, bucket in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(priceLine) × \(bucket.chargeCount) 期")
                                .font(.subheadline)
                                .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                            Text(QJFormat.yearMonth(bucket.monthStart)
                                 + (bucket.recordedCount == 0 ? " · 预计" : " · 登记 \(bucket.recordedCount)"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(bucket.total.formatted)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .padding(.vertical, 7)
                    .staged(index, delay: 0.15)
                }
                if buckets.isEmpty {
                    Text("还没有发生扣费。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if totals.recordedCount > 0, totals.projectedCount > 0 {
                    Text("其中 \(totals.recordedCount) 笔是你登记过的，\(totals.projectedCount) 笔按周期推算。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 详情页不再自己算一遍：同一批数字全部出自统计服务，
    /// 这样详情、总览、小票看到的累计一定一致。
    private var detailStats: SubscriptionStats {
        SubscriptionStats(subscriptions: [subscription],
                          events: relatedEvents,
                          defaultCurrency: preferences.defaultCurrency,
                          rates: ExchangeRateStore.shared.rates)
    }

    private var priceLine: String {
        "\(subscription.myAmount.formatted)/\(cycleWord)"
    }

    // MARK: - 时间轴

    private var timelineSection: some View {
        SectionCard(title: "时间轴", trailing: {
            AnyView(
                Button {
                    layer = .eventEditor
                } label: {
                    Label("添加事件", systemImage: "plus.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                }
            )
        }) {
            let list = relatedEvents
            if list.isEmpty {
                Text("还没有记录任何变更。调价、暂停、跳过几期、内购都可以记在这里，统计会跟着变。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element) { index, event in
                        HStack(spacing: 10) {
                            Image(systemName: event.type.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill((Color(hex: preferences.accentHex) ?? .accentColor).opacity(0.14)))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(event.type.title).font(.subheadline.weight(.medium))
                                    if let amount = event.amount {
                                        Text(amount.formatted)
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                    }
                                }
                                if !event.note.isEmpty {
                                    Text(event.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(QJFormat.shortDate(event.happenedAt))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    actions.remove(event)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 7)
                        .staged(min(index, 8), delay: 0.1)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .animation(Motion.ui, value: list.map { $0.id })
            }
        }
    }

    // MARK: - 其他

    private var otherSection: some View {
        SectionCard(title: "其他") {
            if !subscription.plan.isEmpty { row("套餐", value: subscription.plan) }
            if !subscription.paymentMethod.isEmpty { row("支付方式", value: subscription.paymentMethod) }
            if subscription.shareEnabled {
                row("拼车", value: shareText)
            }
            if !subscription.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("备注")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(subscription.notes)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SauryTheme.surfaceElevated))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var shareText: String {
        switch subscription.shareMode {
        case .even:
            return "\(subscription.shareHeadcount) 人均摊，我出 \(subscription.myAmount.formatted)/\(cycleWord)"
        case .custom:
            return "自定义份额 \(subscription.myAmount.formatted)/\(cycleWord)"
        }
    }

    @ViewBuilder
    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }
}

/// 详情页的小节壳。
struct SectionCard<Content: View>: View {
    let title: String
    var trailing: (() -> AnyView)?
    @ViewBuilder let content: Content

    init(title: String, trailing: (() -> AnyView)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                trailing?()
            }
            content
        }
        .padding(16)
        .sauryCard()
    }
}

/// 添加事件的小表单。
struct SubscriptionEventEditor: View {
    let subscription: Subscription

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var type: SubscriptionEventType = .charged
    @State private var amountText = ""
    @State private var note = ""
    @State private var date = Date()
    /// 这一次登记的稳定身份：连点两次「保存」补的是同一条记录，不会记成两笔钱。
    @State private var eventID = UUID()
    @State private var isSaving = false
    @State private var feedback: WriteFeedback?

    private var repository: SubscriptionRepository { SubscriptionRepository(context: modelContext) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $type) {
                    ForEach(SubscriptionEventType.allCases, id: \.self) { event in
                        Text(event.title).tag(event)
                    }
                }
                if takesAmount {
                    TextField("金额（\(subscription.currencyCode)）", text: $amountText)
                        .keyboardType(.decimalPad)
                    if let issue = amountIssue {
                        Text(issue.message)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                DatePicker("日期", selection: $date, displayedComponents: .date)
                TextField("备注（可选）", text: $note)
            }
            .navigationTitle("添加事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("保存")
                        }
                    }
                    .fontWeight(.semibold)
                    .animation(Motion.ui, value: isSaving)
                    .disabled(!canSave)
                    .accessibilityLabel(isSaving ? "正在保存" : "保存")
                }
            }
        }
        .writeFeedback($feedback)
    }

    private var takesAmount: Bool {
        type == .charged || type == .priceChanged || type == .inAppPurchase
    }

    private var parsedAmount: Money? {
        guard takesAmount else { return nil }
        return try? MoneyParsing.parse(amountText, currencyCode: subscription.currencyCode).get()
    }

    /// 填了却解析不出来就直接拦住：按下保存只会存成 0，等于把用户记的那笔钱记丢。
    private var amountIssue: MoneyParsing.Failure? {
        guard takesAmount else { return nil }
        return MoneyParsing.validate(amountText, currencyCode: subscription.currencyCode)
    }

    private var canSave: Bool { amountIssue == nil && !isSaving }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let minor = parsedAmount?.minorUnits ?? 0
        let draft = SubscriptionEventDraft(
            id: eventID,
            subscriptionID: subscription.id,
            type: type,
            amountMinorUnits: minor,
            currencyCode: minor != 0 ? subscription.currencyCode : "",
            note: note,
            happenedAt: date
        )
        do {
            // 调价「改价 + 留痕」是仓库里的一次写入，页面不再自己拼。
            try repository.record(draft)
        } catch {
            SelectionHaptics.error()
            feedback = .failure(error.localizedDescription)
            return
        }
        SelectionHaptics.success()
        dismiss()
    }
}
