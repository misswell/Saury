import SwiftUI
import SwiftData
import PhotosUI
import os

/// 新增 / 编辑订阅。上半是跟图标同色的 hero 区（图标、名称、金额、币种周期），
/// 下半是分组表单。保存不弹提示，直接收。
struct AddSubscriptionView: View {
    var editing: Subscription?
    /// 外部入口（快捷指令 / 分享扩展）带进来的初值。编辑态不看这一份。
    var prefill = AddPrefill.empty

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: FormField?

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
    @State private var remindersEnabled = true
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

    /// 表单这一层的四张弹层：一次只认一张。
    ///
    /// 以前是四个 `Bool` 各挂一张 `.sheet`，可同一层 SwiftUI 只认一张：
    /// 币种那页刚收起、周期那一下点下去就是「点了没反应」（任务书 §6.3、§7.1）。
    /// 收成一条之后，四张里最多存在一张，切张必然走完上一张的退场。
    private enum Layer: Identifiable {
        case icon, currency, cycle, payment

        var id: Self { self }
    }

    @State private var layer: Layer?
    @State private var showingStartCalendar = false

    /// 「有没有没保存的改动」只跟打开时定下的锚比，不猜用户改了哪儿。
    @State private var changes = UnsavedChangesTracker()
    /// 关掉分摊只是不再计入，不该顺手抹掉原来填的份额：原值留在这儿兜底。
    @State private var loadedShareMyMinorUnits = 0
    /// 按过一次保存之后，空着的必填项才开口；平时不碎碎念。
    @State private var submitTapped = false
    @State private var showingDiscard = false
    /// 丢弃要等确认条自己收完：在它的退场动画里直接 dismiss，这一下会被系统整段吞掉
    /// —— 和 §6.3 那种「弹窗还在收、下一点已落空」是同一类坑。
    @State private var discardWhenDialogCloses = false

    @State private var heroPop = false

    /// 这次表单对应的订阅身份：新增时生成一个、编辑时沿用原 id。
    /// 保存走 upsert，所以连点两次「保存」写的还是同一行（任务书 §2.3）。
    @State private var newDraftID = UUID()
    @State private var isSaving = false
    @State private var feedback: WriteFeedback?

    private var draftID: UUID { editing?.id ?? newDraftID }

    private var isEditing: Bool { editing != nil }

    private var repository: SubscriptionRepository { SubscriptionRepository(context: modelContext) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
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
                // 换格时把那一格送到中间：数字键盘没有回车，光靠自动滚动容易停在半格上。
                .onChange(of: focusedField) { _, field in
                    guard let field else { return }
                    withAnimation(Motion.ui) { proxy.scrollTo(field, anchor: .center) }
                }
            }
            .background(SauryTheme.background)
            .navigationTitle(isEditing ? "编辑订阅" : "新增订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { cancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: submit) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("保存")
                        }
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(canSave ? Color(hex: preferences.accentHex) ?? .accentColor : Color.secondary)
                    .scaleEffect(canSave ? 1 : 0.94)
                    .animation(Motion.ui, value: canSave)
                    .animation(Motion.ui, value: isSaving)
                    // 灰着但可以点：点下去要能问出「到底差在哪」，不是给一个按不动的死按钮。
                    .accessibilityLabel(isSaving ? "正在保存" : "保存")
                }
                ToolbarItem(placement: .keyboard) {
                    keyboardBar
                }
            }
            .sheet(item: $layer) { layer in
                switch layer {
                case .icon:
                    IconPickerSheet(
                        symbol: $iconSymbol,
                        imageFile: $iconImageFile,
                        colorHex: $iconColorHex
                    )
                    .presentationDragIndicator(.visible)
                case .currency:
                    CurrencyPickerSheet(selection: $currencyCode)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                case .cycle:
                    CyclePickerSheet(cycle: $cycle, customMonths: $customMonths)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                case .payment:
                    PaymentQuickPicker(selection: $paymentMethod)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
            }
            // 用 alert 而不是 confirmationDialog：后者在表单里会贴着触发它的控件
            // 弹成小气泡，键盘还撑着的时候「继续填写」会被压到看不见，
            // 等于把两个选项变成了一个只能选丢弃的死局。
            .alert(discardTitle, isPresented: $showingDiscard) {
                Button("丢弃", role: .destructive) { discardWhenDialogCloses = true }
                Button("继续填写", role: .cancel) { }
            } message: {
                Text(discardMessage)
            }
            .onChange(of: showingDiscard) { _, closed in
                guard closed == false, discardWhenDialogCloses else { return }
                discardWhenDialogCloses = false
                dismiss()
            }
        }
        // 有没保存的改动时不让下滑手势直接收掉：不然「取消」有确认、下滑却静默丢，
        // 同一个页面上两套退出规则（任务书 §7.1 第 10 条）。
        .interactiveDismissDisabled(hasUnsavedChanges)
        .onAppear(perform: loadInitial)
        .writeFeedback($feedback)
        #if DEBUG
        .task {
            await runQAOpsIfNeeded()
            await runFormProbeIfNeeded()
            openIconLayerForProbeIfNeeded()
            await runHeroProbeIfNeeded()
        }
        #endif
    }

    /// 键盘上方那条走格子的工具条。数字键盘没有回车，缺了它就出不去。
    private var keyboardBar: some View {
        let current = focusedField
        let canGoBack = current.flatMap { chain.previous(of: $0) } != nil
        let canGoForward = current.flatMap { chain.next(of: $0) } != nil

        return HStack(spacing: 16) {
            Button(action: { moveFocus(-1) }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .bold))
            }
            .disabled(!canGoBack)
            .accessibilityLabel("上一项")

            Button(action: { moveFocus(1) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
            }
            .disabled(!canGoForward)
            .accessibilityLabel("下一项")

            Text(current.flatMap { chain.position(of: $0) } ?? "填完点保存")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(Motion.ui, value: current)

            Spacer()

            Button("完成") { focusedField = nil }
                .fontWeight(.semibold)
        }
    }

    private var discardTitle: String {
        isEditing ? "还没保存，丢弃这些修改？" : "还没保存，丢掉这次填的内容？"
    }

    private var discardMessage: String {
        isEditing
            ? "改动还没存，离开就恢复成原来的样子。"
            : "关掉之后这次填的不会留下记录。"
    }

    private func moveFocus(_ step: Int) {
        guard let current = focusedField else { return }
        let target = step < 0 ? chain.previous(of: current) : chain.next(of: current)
        withAnimation(Motion.ui) { focusedField = target }
    }

    #if DEBUG
    /// 模拟器操作验证用（`-saury-ops`）。命令里没有 Accessibility 权限，合成不了真实点击，
    /// 所以让表单自己填一次用户会填的字段，再按真的保存按钮走 `submit()`。
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
        submit()
        // 新增那一遍连按两次：真实的 `submit()` 走两遍，对外的草稿 id 却没变，
        // 所以库里必须还是一行。第二行要是冒出来，数据库那边立刻能看见。
        if editing == nil { submit() }
    }

    /// 表单与键盘剧本（`-saury-form`，任务书 §7.1）。
    ///
    /// 这台机器的命令行没有辅助功能权限，按不动键盘上方那三个按钮，所以这里按的是
    /// 那个按钮走的**同一句** `moveFocus`／`submit`／`cancel` —— 不是另搭一条演示通路。
    /// 每步先打一行时间戳：截图一张要 1.5 秒左右，靠秒数猜哪帧对哪步一定会猜错。
    private func runFormProbeIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-form") else { return }
        let steps: [(Double, String, () -> Void)] = [
            (1.2, "表单打开：焦点应落在名称，键盘已经起来", { }),
            (3.5, "下一项 → 金额：数字键盘，上方工具条该在", { moveFocus(1) }),
            (6.0, "金额填 12.3、币种切到日元：位数说不通要指着金额说", {
                priceText = "12.3"
                currencyCode = "JPY"
            }),
            (8.5, "按下保存：不许关页，名称和金额各说一句", { submit() }),
            (11.0, "修好这两处：名称填上、币种切回人民币", {
                name = "键盘验证"
                currencyCode = "CNY"
            }),
            (13.0, "展开分摊选自定义，份额 99 比总额还大", {
                shareEnabled = true
                shareMode = .custom
                shareMyText = "99"
            }),
            (15.5, "下一项 → 套餐：链子 3/5", { moveFocus(1) }),
            (17.5, "下一项 → 我的份额：链子 4/5，藏起来的那格不算", { moveFocus(1) }),
            (19.5, "结束日期开到比开始还早：那一行该说话", {
                endDateEnabled = true
                endDate = BillingMath.calendar.date(byAdding: .day, value: -3, to: startDate)!
            }),
            (22.0, "再按一次保存：日期这条拦住，页还不关", { submit() }),
            (24.5, "点取消：填过的表单该问一次丢弃", { cancel() })
        ]
        // 每步的秒数是「从表单出现算起」的绝对时刻：逐步累加会越跑越晚，
        // 截图和日志就对不上了。
        let started = Date()
        for (offset, label, action) in steps {
            let wait = offset - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            probe(label)
            action()
        }
    }

    private static let probeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")

    private func probe(_ step: String) {
        Self.probeLogger.log("表单探针 \(step, privacy: .public)")
    }

    /// 图标剧本（`-saury-icon`）要从表单进「换图标」那一层。命令行的辅助通道够不到那张
    /// sheet，只能由表单自己把层打开，之后 `IconPickerSheet` 接手。
    /// 这 1 秒只属于截图探针：表单刚挂上去那一帧开第二层，有时会被系统整段吃掉；
    /// 用户走的入口是按钮里那句 `layer = .icon`，不靠这种延时。
    private func openIconLayerForProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-saury-icon") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { layer = .icon }
    }

    /// 头像弹动与金额放大（矩阵 EON-005/007）。
    ///
    /// 命令行点不动键盘，这里直接写状态 —— 走的仍是用户打字会走的那几条同一个
    /// `.onChange` / `.focused`，不是另搭一条演示通路。
    /// 两处对帧：头像那一弹是 0.14 秒的弹簧，settle 0.07 秒必落在升程上（拍「正在弹」），
    /// 0.7 秒一定回到 1.0（拍「弹完」）；金额放那张要等 `Motion.pop` 收束，
    /// 失焦那张要等它缩回去。探针每步先打一行时间戳，外面把截图和秒数对账。
    private func runHeroProbeIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-hero") else { return }
        try? await Task.sleep(for: .seconds(1.4))
        let focusAtOpen = focusedField == .name ? "名称" : String(describing: focusedField)
        Self.heroProbeLogger.log("头像探针 表单打开：焦点在\(focusAtOpen, privacy: .public)，减少动态效果=\(reduceMotion, privacy: .public)")
        _ = await ProbeShutter.capture("hero-00-form-open", settle: 0.2)

        // ① 名字逐字变：头像画的就是名字首字，每打一个字弹一下 —— 先拍升程中间那一帧。
        name = "阿里"
        _ = await ProbeShutter.capture("hero-01-name-mid-bump", settle: 0.07)
        name = "阿里云盘"
        _ = await ProbeShutter.capture("hero-02-name-settled", settle: 0.7)

        // ② 焦点移到金额、填上数字：字形放大一档（1.32 倍，靠 `priceEditing` 派生）。
        moveFocus(1)
        priceText = "128.5"
        let zoomState = "金额放大判定：焦点在金额=\(focusedField == .price)，有内容=\(priceText.isEmpty == false)，"
            + "放大中=\(priceEditing)"
        Self.heroProbeLogger.log("头像探针 \(zoomState, privacy: .public)")
        _ = await ProbeShutter.capture("hero-03-price-zoomed", settle: 0.6)

        // ③ 失焦（等于收起键盘）：字形缩回常规大小。
        focusedField = nil
        _ = await ProbeShutter.capture("hero-04-price-normal", settle: 0.7)
        Self.heroProbeLogger.log("头像探针 收尾：失焦后放大中=\(self.priceEditing)")
    }

    private static let heroProbeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")
    #endif

    /// 保存中、名称空着、金额读不出来、分摊没填、结束日期倒挂 —— 任何一种都不许写库。
    private var canSave: Bool { report.canSave }

    /// 校验只吃原始文本，所以「读不通」和「还没填」在这里是分开的两件事。
    private var input: AddFormInput {
        AddFormInput(name: name,
                     priceText: priceText,
                     currencyCode: currencyCode,
                     shareEnabled: shareEnabled,
                     shareMode: shareMode,
                     shareText: shareMyText,
                     startDate: startDate,
                     endDateEnabled: endDateEnabled,
                     endDate: endDate)
    }

    private var report: AddFormReport { AddFormValidator.validate(input) }

    /// 键盘上下键走的格子。「我的份额」没展开时不在链子上。
    private var chain: FormFieldChain {
        FormFieldChain(showingShare: shareEnabled && shareMode == .custom)
    }

    private var nameMessage: String? { report.message(for: .name, afterSubmit: submitTapped) }
    private var priceMessage: String? { report.message(for: .price, afterSubmit: submitTapped) }
    private var shareMessage: String? { report.message(for: .share, afterSubmit: submitTapped) }

    private var hasUnsavedChanges: Bool { changes.isDirty(draft) }

    /// 金额用解析器过一遍：币种精度、千分位、负数都在这里判，
    /// 页面拿同一个结果决定能不能保存、提示什么。
    private var parsedPrice: Money? { report.parsedPrice }

    private var parsedShareMy: Money? { report.parsedShare }

    // MARK: - Hero

    private var heroTint: Color {
        if let hex = iconColorHex, let color = Color(hex: hex) { return color }
        if let file = iconImageFile {
            return IconTint.dominantColor(of: IconImageStore.shared.image(for: file)) ?? (Color(hex: preferences.accentHex) ?? .accentColor)
        }
        return Color(hex: preferences.accentHex) ?? .accentColor
    }

    /// 字段级提示：一条红底小胶囊，紧挨着它说的那一格。
    /// 没有内容时不占位，免得表单一直抖。
    @ViewBuilder
    private func fieldNote(_ issue: String?, title: String) -> some View {
        if let issue {
            HStack {
                Spacer(minLength: 0)
                Text(issue)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(red: 0.82, green: 0.21, blue: 0.21)))
                    .accessibilityLabel("\(title)这一格：\(issue)")
                Spacer(minLength: 0)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Button {
                SelectionHaptics.impact(.light)
                layer = .icon
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
            .onChange(of: iconSignature) { _, _ in bumpHeroIcon(tick: true) }
            .onChange(of: name) { _, _ in
                // 还没选图标时，头像画的就是名字首字：名字在变，头像跟着弹（矩阵 EON-005）。
                // 只在「正在填名字」这一种情况下弹，打开编辑页时回填的名字不算。
                guard focusedField == .name, iconSymbol == nil, iconImageFile == nil else { return }
                bumpHeroIcon(tick: false)
            }

            TextField("名称", text: $name)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { moveFocus(1) }
                .id(FormField.name)

            fieldNote(nameMessage, title: "名称")

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
                    // 输入过程中把裸数字放大一号：每一笔都看得清，失焦回到常规字形（矩阵 EON-007）。
                    .scaleEffect(priceEditing && !reduceMotion ? 1.32 : 1, anchor: .leading)
                    .animation(Motion.pop, value: priceEditing)
                    .id(FormField.price)
            }

            // 金额填错当场说清是哪一条规则，不等到按下保存才弹一个笼统提示。
            fieldNote(priceMessage, title: "金额")

            HStack(spacing: 8) {
                Button { layer = .currency } label: {
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

                Button { layer = .cycle } label: {
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
        .animation(Motion.ui, value: nameMessage)
        .animation(Motion.ui, value: priceMessage)
    }

    /// 图标换了就弹一下：让「选中了什么」这件事有身体反应。
    /// `tick` 分开给：选图标补一下触感；名字逐字符变只弹不响（键盘自己有声）。
    private var iconSignature: String { "\(iconSymbol ?? "")|\(iconImageFile ?? "")" }

    /// 正在填金额、且已经有内容：hero 上的数字放大一号。
    private var priceEditing: Bool { focusedField == .price && priceText.isEmpty == false }

    /// 没有图标时头像上画的那个字：名字首字，没名字就是加号。
    private var fallbackInitial: String {
        name.isEmpty ? "＋" : String(name.prefix(1)).uppercased()
    }

    private func bumpHeroIcon(tick: Bool) {
        if tick { SelectionHaptics.tick() }
        guard !reduceMotion else { return }
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
                    Text(fallbackInitial)
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
                    .submitLabel(.next)
                    .onSubmit { moveFocus(1) }
                    .id(FormField.plan)
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
            Toggle(isOn: $remindersEnabled) {
                Text("扣费提醒").font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .onChange(of: remindersEnabled) { _, on in if on { SelectionHaptics.tick() } }

            if remindersEnabled {
                Divider().overlay(SauryTheme.line).padding(.leading, 14)
                HStack {
                    Text("提前提醒").font(.subheadline)
                    Spacer()
                    Stepper(value: $reminderDays, in: 0...30) {
                        // 0 是「当天」，不是「不提醒」—— 关掉提醒用上面那个开关。
                        Text(reminderDays == 0 ? "当天" : "\(reminderDays) 天")
                            .font(.subheadline.monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    .fixedSize()
                    .onChange(of: reminderDays) { _, _ in SelectionHaptics.tick() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
                dateIssueRow
            }
        }
        .sauryCard()
        .animation(Motion.ui, value: endDateEnabled)
        .animation(Motion.ui, value: remindersEnabled)
        .animation(Motion.ui, value: report.dateIssue)
        .tint(heroTint)
    }

    /// 结束日期那行的字段级提示。日期不是键盘格子，所以不混进 `issues`。
    private var dateIssueRow: some View {
        fieldNote(report.dateIssue, title: "结束日期")
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
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
        .animation(Motion.ui, value: shareMessage)
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
                        .focused($focusedField, equals: .share)
                        .id(FormField.share)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .transition(.opacity.combined(with: .move(edge: .top)))

                // 「我出的」以前读不通就静默存 0：这一格必须当场把话说出来。
                fieldNote(shareMessage, title: "我的份额")
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
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
        let minor = shareMode == .custom
            ? (parsedShareMy?.minorUnits ?? 0)
            : Money.evenShare(totalMinorUnits: priceMinor, headcount: shareHeadcount)
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
                Button { layer = .payment } label: {
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
                .focused($focusedField, equals: .notes)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }
                .id(FormField.notes)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .sauryCard()
    }

    // MARK: - 数据

    private var priceMinor: Int { parsedPrice?.minorUnits ?? 0 }

    private func loadInitial() {
        // 只认第一次。这一页被上层弹层盖住再回来时 `onAppear` 可能又响一次，
        // 那时候重新加载会把用户正填的东西冲掉，草稿身份也会跟着换掉。
        guard changes.hasAnchor == false else { return }
        guard let subscription = editing else {
            // 每次开始一条新的录入都换一个新身份：
            // 上一次新增留下的 id 不能变成这一条的主键。
            newDraftID = UUID()
            remindersEnabled = preferences.defaultRemindersEnabled
            reminderDays = preferences.defaultReminderDays
            currencyCode = preferences.defaultCurrency
            name = prefill.name
            if let note = prefill.note, note.isEmpty == false { notes = note }
            // 分享过来的图片：进页面就已经是选好的图标，用户只要确认别的格子。
            iconImageFile = prefill.iconImageFile
            // 焦点规则是定死的：新增永远停在第一个还没填的格子上。
            // 名称被外部草稿预填过就从金额开始 —— 不是「打开时键盘出不出现看运气」。
            focusedField = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .name : .price
            changes.anchor(draft)
            return
        }
        name = subscription.name
        priceText = subscription.billAmount.amountText
        currencyCode = subscription.currencyCode
        cycle = subscription.cycle
        customMonths = subscription.customMonths
        plan = subscription.plan
        categoryID = subscription.categoryRawValue
        state = subscription.state
        startDate = subscription.startDate
        endDateEnabled = subscription.endDate != nil
        endDate = subscription.endDate ?? Date().addingTimeInterval(365 * 86400)
        remindersEnabled = subscription.remindersEnabled
        reminderDays = subscription.reminderDays
        shareEnabled = subscription.shareEnabled
        shareHeadcount = subscription.shareHeadcount
        shareMode = subscription.shareMode
        loadedShareMyMinorUnits = subscription.shareMyMinorUnits
        shareMyText = subscription.shareMode == .custom
            ? Money(minorUnits: subscription.shareMyMinorUnits, currencyCode: subscription.currencyCode).amountText
            : ""
        paymentMethod = subscription.paymentMethod.isEmpty ? "无" : subscription.paymentMethod
        notes = subscription.notes
        iconSymbol = subscription.iconSymbolName
        iconImageFile = subscription.iconImageFile
        iconColorHex = subscription.iconColorHex
        colorHexes = subscription.colorSpec.orderedHexes
        // 编辑是来看和改的，不是来打字的：不把键盘顶上去挡住 hero。
        changes.anchor(draft)
    }

    /// 按下保存。数据不对时不写库、不关页，把话说清楚是哪一格（§7.1 第 9 条）。
    private func submit() {
        guard !isSaving else { return }
        submitTapped = true

        guard report.canSave else {
            SelectionHaptics.error()
            // 把焦点送到第一个有问题的格子：那一条字段级提示就长在那儿，
            // 顺带把可能被滚出屏幕的那一行拉回来，而不是弹一句笼统的「请检查输入」。
            focusedField = report.fieldsToFix.first
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            try repository.apply(draft)
        } catch {
            // 没写进库就不关页面：用户还在原地，字段没丢，改完还能再按一次。
            SelectionHaptics.error()
            feedback = .failure(error.localizedDescription)
            return
        }
        // 成功触感、关页都排在落盘之后 —— 顺序反了就是「假装保存成功」。
        // 存成之后就不再有「没保存的改动」，退场也不用再确认。
        changes.anchor(draft)
        SelectionHaptics.success()
        dismiss()
    }

    /// 取消。空着的表单直接收；填过东西就一定问一次，不留「静默丢掉」这条路。
    private func cancel() {
        guard hasUnsavedChanges else { dismiss(); return }
        // 先收起键盘再问：键盘顶在上面会把确认框挤成半截，
        // 而一个只看得见「丢弃」的确认框比不确认更糟。
        focusedField = nil
        showingDiscard = true
    }

    /// 「我出的」这一格藏起来的时候不该顺手抹掉原值：
    /// 关掉分摊只是暂时不计入，用户上一次填的数字还得在。
    private var draftShareMyMinorUnits: Int {
        guard shareEnabled else { return loadedShareMyMinorUnits }
        guard shareMode == .custom else { return 0 }
        return parsedShareMy?.minorUnits ?? 0
    }

    /// 表单当前填的全部内容。编辑和新增都走同一份，保存才有「整字段覆盖」的语义。
    private var draft: SubscriptionDraft {
        SubscriptionDraft(
            id: draftID,
            name: name,
            plan: plan,
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
            remindersEnabled: remindersEnabled,
            reminderDays: reminderDays,
            shareEnabled: shareEnabled,
            shareHeadcount: shareHeadcount,
            shareMode: shareMode,
            shareMyMinorUnits: draftShareMyMinorUnits,
            paymentMethod: paymentMethod == "无" ? "" : paymentMethod,
            notes: notes
        )
    }
}

