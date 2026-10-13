import SwiftUI
import SwiftData
import StoreKit
import UIKit
import os

/// 存储管理：图标缓存。
struct StorageSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var subscriptions: [Subscription]

    @State private var cacheSize: Int64 = 0
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                HStack {
                    Label("图标缓存", systemImage: "photo.on.rectangle")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.ui, value: cacheSize)
                }
                Button {
                    SelectionHaptics.tick()
                    confirmClear = true
                } label: {
                    Label("清除图标缓存", systemImage: "trash")
                }
            } header: {
                Text("存储管理")
            } footer: {
                // 「使用中」按字面算：归档和回收站里的也算（上面 `keep` 取的是整库那一条），
                // 回收站那条随时能被恢复，它的图不能当垃圾清掉。
                Text("清除已经没有任何订阅在用的图标文件。彻底删除和回收站到期清理会自动释放只属于那一条的图标；几条订阅共用一张图时，那张要等都不用了才清得掉。这里额外收的是换过图标之后留下的旧文件。当前在用的（含归档和回收站）不会被删除。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("存储管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheSize = IconImageStore.shared.cacheSizeBytes }
        .alert("确定要清除图标缓存吗？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { clearCache() }
        } message: {
            Text("将删除已不再使用的图标文件，当前订阅的图标不受影响。")
        }
    }

    private func clearCache() {
        let keep = Set(subscriptions.compactMap(\.iconImageFile))
        IconImageStore.shared.clearOrphans(keep: keep)
        cacheSize = IconImageStore.shared.cacheSizeBytes
        SelectionHaptics.success()
    }
}

/// 关于页。
struct AboutAppView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    AppIconBadge()
                    Text("期见").font(.title3.weight(.bold))
                    Text(versionText).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            Section("法律") {
                Button {
                    openURL(URL(string: "https://example.com/privacy")!)
                } label: { Label("隐私政策", systemImage: "hand.raised") }
                Button {
                    openURL(URL(string: "https://example.com/terms")!)
                } label: { Label("使用条款", systemImage: "doc.plaintext") }
            }
            Section("更新") {
                NavigationLink { VersionHistoryView() } label: {
                    Label("版本历史", systemImage: "clock.arrow.circlepath")
                }
            }
            Section("应用商店") {
                Button {
                    requestReview()
                } label: { Label("给期见打个分", systemImage: "star.bubble") }
                shareButton
            }
            Section("支持") {
                Button {
                    if let url = URL(string: "mailto:hi@example.com?subject=期见反馈") { openURL(url) }
                } label: { Label("发送反馈", systemImage: "envelope") }
                Button {
                    if let url = URL(string: "mailto:hi@example.com?subject=期见功能建议") { openURL(url) }
                } label: { Label("功能需求建议", systemImage: "lightbulb") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = URL(string: "https://apps.apple.com/app/id000000000") {
            ShareLink(item: url) {
                Label("分享期见", systemImage: "square.and.arrow.up")
            }
        }
    }
}

struct AppIconBadge: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.84, blue: 0.42), Color(red: 0.42, green: 0.62, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color(red: 0.95, green: 0.75, blue: 0.3), lineWidth: 3))
        }
        .frame(width: 74, height: 74)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
    }
}

/// 新功能页（「本次更新」）：三页轮播。
struct WhatsNewView: View {
    var standalone: Bool
    @EnvironmentObject private var preferences: SubPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if standalone {
                    Text("本次更新")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .staged(0, edge: .top)
                }
                TabView(selection: $page) {
                    whatsNewCard(
                        symbol: "square.stack.3d.up.fill",
                        title: "即将扣费，翻着看",
                        body: "即将扣费变成一叠卡片，左右滑动翻到下一笔；点右上角进日历，订阅也能展开看全年。"
                    ).tag(0)
                    whatsNewCard(
                        symbol: "list.bullet.rectangle",
                        title: "列表更紧凑，操作更顺手",
                        body: "列表、卡片、紧凑卡片三种视图随你挑；卡片上有本期进度条，长按就能置顶、归档或删除。"
                    ).tag(1)
                    whatsNewCard(
                        symbol: "paintpalette",
                        title: "拼车分摊，卡片随心配色",
                        body: "家庭或拼车的订阅可以填分摊人数，统计只算你自己那一份；卡片颜色可以手动挑，还能把两三种颜色混成渐变。"
                    ).tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 330)
                PageDots(count: 3, index: page)
                Button {
                    if page < 2 {
                        SelectionHaptics.tick()
                        withAnimation(Motion.page) { page += 1 }
                    } else {
                        preferences.lastWhatsNewVersion = Self.currentVersion
                        dismiss()
                    }
                } label: {
                    Text(page < 2 ? "继续" : "去看看")
                        .font(.headline)
                        .contentTransition(.opacity)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(Pressable(scale: 0.96, animation: Motion.pop))
                .animation(Motion.ui, value: page)
            }
            .padding(20)
        }
        .background(SauryTheme.background)
        .navigationTitle("新功能")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private func whatsNewCard(symbol: String, title: String, body: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .medium))
                .symbolEffect(.bounce, value: page)
                .foregroundStyle(Color.accentColor)
                .frame(width: 92, height: 92)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            Text(title).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sauryCard()
    }
}

/// 支持开发者：三档一次性打赏，一档一个真实的 StoreKit 产品。
///
/// 这里以前是三行写死的「¥8 / ¥22 / ¥38」——那是不能按的装饰，
/// 页面底下另有一个按钮买的是同一个终身产品。任务书 §10.4 说的就是这件事：
/// 多档不同金额不得展示成一个固定售价的支付入口。
/// 现在每一档自己可点、价格由 StoreKit 给（含币种与本地化格式），
/// 成功 / 取消 / 待批准 / 验证失败 / 下架五种结果在页面上各说各的话。
struct TipJarView: View {
    @EnvironmentObject private var preferences: SubPreferences
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PurchaseStore()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("💗")
                    .font(.system(size: 56))
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
                    .accessibilityHidden(true)
                    .staged(0, edge: .top)
                Text("你养的不是订阅，是开发者")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .staged(1, delay: 0.05)
                Text("期见帮你看住了钱包。要是它真帮上了忙，请开发者喝杯咖啡续个命？")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .staged(2, delay: 0.1)

                ForEach(Array(TipTier.allCases.enumerated()), id: \.element.id) { index, tier in
                    tipRow(tier).staged(3 + index, delay: 0.15 + Double(index) * 0.05)
                }

                if store.isSellable == false {
                    Text("内购暂不可用：没从商店取到任何一档打赏产品。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .staged(6, delay: 0.3)
                }

                Button("恢复购买") { Task { await store.restore() } }
                    .font(.footnote.weight(.semibold))
                    .staged(7, delay: 0.32)

                if let notice = store.restoreNotice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                Text("完全自愿 · 不解锁任何功能 · 一次性，不是订阅\n你都在用订阅管理 App 了，就别再给自己加一个叫期见的订阅啦 😜")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .staged(8, delay: 0.35)
            }
            .padding(20)
        }
        .background(SauryTheme.background)
        .navigationTitle("请我喝杯咖啡")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .task { await store.load() }
        .animation(Motion.ui, value: store.restoreNotice)
    }

    private func tipRow(_ tier: TipTier) -> some View {
        let status = store.status(of: tier)
        return Button {
            Task { await store.buy(tier) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(tier.emoji)
                        .font(.system(size: 28))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tier.title).font(.subheadline.weight(.semibold))
                        Text(tier.caption).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    trailing(for: status, tier: tier)
                }
                // 出错时原因写在行里，不靠胶囊变红来传达（§11.2：颜色不能是唯一手段）。
                if case .problem(let reason) = status {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(red: 0.86, green: 0.24, blue: 0.24))
                        .lineLimit(3)
                }
            }
            .padding(12)
            .sauryCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98, animation: Motion.pop))
        .disabled(status == .buying || status == .unavailable)
        .accessibilityLabel(spokenLabel(for: tier, status: status))
        // 「已收到」只是一句谢谢，打赏不是一次买断：过一会儿让这一档重新可买。
        .task(id: status == .thanked) {
            guard status == .thanked else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard Task.isCancelled == false else { return }
            store.clearThanks(tier)
        }
        .animation(Motion.pop, value: status)
    }

    @ViewBuilder
    private func trailing(for status: TipStatus, tier: TipTier) -> some View {
        switch status {
        case .buying:
            ProgressView().controlSize(.small)
        case .thanked:
            Label("已收到", systemImage: "checkmark.seal.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        case .pending:
            Text("等待确认").font(.footnote).foregroundStyle(.secondary)
        case .unavailable:
            Text("暂不可用").font(.footnote).foregroundStyle(.tertiary)
        case .problem:
            Text(store.quote(of: tier)?.displayPrice ?? "—")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color(white: 0.35)))
        case .available:
            Text(store.quote(of: tier)?.displayPrice ?? "—")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor))
        }
    }

    /// 朗读要把「哪一档、多少钱、现在能不能买」说全，只念名字等于没念。
    private func spokenLabel(for tier: TipTier, status: TipStatus) -> String {
        let price = store.quote(of: tier)?.displayPrice ?? "价格未取到"
        let tail: String
        switch status {
        case .buying: tail = "，正在购买"
        case .thanked: tail = "，已收到，谢谢"
        case .pending: tail = "，等待确认"
        case .unavailable: tail = "，当前不可购买"
        case .problem: tail = "，上一次没成功"
        case .available: tail = ""
        }
        return "\(tier.title)，\(price)\(tail)。\(tier.caption)"
    }
}

/// 小玩具：抽一个订阅 + 几条真算出来的冷知识。
///
/// 竞品设置里的「小玩具」「其他」两页在录屏中从未展开过，里面有什么不可判定 ——
/// 这两页是我方自己的设计（矩阵 EON-071 只对齐「入口存在」这件事，不声称内容一致）。
struct ToysView: View {
    @EnvironmentObject private var preferences: SubPreferences
    @EnvironmentObject private var sheets: SheetRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var subscriptions: [Subscription]

    @State private var seed = UUID()
    @State private var picked: Subscription?

    /// 抽签与冷知识都只看在册的；「登记过」那条按全库算。
    private var rows: [Subscription] {
        subscriptions.filter { $0.deletedAt == nil && $0.archivedAt == nil }
    }

    var body: some View {
        List {
            Section {
                if let picked {
                    Button {
                        sheets.present(.detail(picked.id))
                    } label: {
                        pickedCard(picked)
                    }
                    .buttonStyle(Pressable(scale: 0.98, animation: Motion.pop))
                    .id(picked.id)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                } else {
                    Text(rows.isEmpty ? "先添加几笔订阅，再来抽签。" : "点下面的按钮，抽到哪个今天就用哪个。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    roll()
                } label: {
                    Label(picked == nil ? "帮我选一个" : "再抽一次", systemImage: "dice")
                }
                .disabled(rows.isEmpty)
            } header: {
                Text("今天用哪个")
            } footer: {
                Text("在在册的订阅里公平抽一条；置顶的不进抽签池 —— 置顶是找得快，不是每次都被翻牌子。")
            }
            Section {
                LabeledContent("登记过", value: "\(subscriptions.count) 笔")
                if let oldest = SubscriptionQuery.oldest(rows) {
                    LabeledContent("陪我最久", value: "\(oldest.name) · \(QJFormat.shortDate(oldest.startDate)) 起")
                }
                if let priciest = SubscriptionQuery.priciest(rows,
                                                             defaultCurrency: preferences.defaultCurrency,
                                                             rates: ExchangeRateStore.shared.rates) {
                    LabeledContent("最贵的一笔", value: "\(priciest.name) · \(priciest.myAmount.formattedGrouped)")
                }
            } header: {
                Text("冷知识")
            } footer: {
                Text("「登记过」按库里的全部算，含归档和回收站；另外两条只看在册的。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("小玩具")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .task { await runGapProbeIfNeeded() }
        #endif
    }

    #if DEBUG
    /// 对齐缺口探针（矩阵 EON-071）在小玩具页这一头：抽一次、再抽一次，各拍一帧。
    /// 对账两件事：抽出来的是库里的真行（把名字和金额读出来），第二次会换人。
    private func runGapProbeIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-gaps") else { return }
        try? await Task.sleep(for: .seconds(1.4))
        _ = await ProbeShutter.capture("gaps-02-toys-before", settle: 0.3)
        roll()
        try? await Task.sleep(for: .seconds(0.9))
        let first = picked.map { "\($0.name) · \($0.myAmount.formattedGrouped)" } ?? "没抽出来"
        Self.gapProbeLogger.log("对齐探针 小玩具第一次抽：\(first, privacy: .public)，池子 \(self.rows.count) 条")
        _ = await ProbeShutter.capture("gaps-02-toys-picked", settle: 0.6)
        roll()
        try? await Task.sleep(for: .seconds(0.9))
        let second = picked.map { "\($0.name) · \($0.myAmount.formattedGrouped)" } ?? "没抽出来"
        Self.gapProbeLogger.log("对齐探针 小玩具第二次抽：\(second, privacy: .public)，换人了=\(first != second)")
        _ = await ProbeShutter.capture("gaps-03-toys-reroll", settle: 0.6)
    }

    private static let gapProbeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")
    #endif

    private func pickedCard(_ subscription: Subscription) -> some View {
        HStack(spacing: 12) {
            SubscriptionIconView(subscription: subscription, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subscription.cycle.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(subscription.myAmount.formattedGrouped)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .sauryCard()
        .contentShape(Rectangle())
    }

    private func roll() {
        guard rows.isEmpty == false else { return }
        SelectionHaptics.impact(.light)
        var candidate: Subscription?
        // 抽到和上一次同一条就再摇一颗 seed，最多四颗 —— 池子小的时候抽中重复
        // 会被当成「按钮坏了」；四颗还撞同一个人就认了，随机本来就允许重复。
        for _ in 0..<4 {
            seed = UUID()
            candidate = SubscriptionQuery.randomPick(rows, seed: seed,
                                                     defaultCurrency: preferences.defaultCurrency,
                                                     rates: ExchangeRateStore.shared.rates)
            if candidate?.id != picked?.id || rows.count == 1 { break }
        }
        if reduceMotion {
            picked = candidate
        } else {
            withAnimation(Motion.pop) { picked = candidate }
        }
    }
}

/// 其他：版本与数据概况，外加一键复制诊断信息。
///
/// 与 `ToysView` 同一个前提：竞品这一页内容不可判定，这里是我方自己的设计（矩阵 EON-071）。
struct MiscSettingsView: View {
    @Query private var subscriptions: [Subscription]
    @Query private var events: [SubscriptionEvent]

    @State private var copied = false

    var body: some View {
        List {
            Section("版本") {
                LabeledContent("版本", value: versionText)
                LabeledContent("系统", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                LabeledContent("机型", value: deviceText)
            }
            Section("数据概况") {
                LabeledContent("订阅", value: "在册 \(liveCount) · 归档 \(archivedCount) · 回收站 \(trashedCount)")
                LabeledContent("账单事件", value: "\(events.count) 条")
            }
            Section {
                Button {
                    copyDiagnostics()
                } label: {
                    Label(copied ? "已复制" : "复制诊断信息", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .disabled(copied)
            } footer: {
                Text("复制的内容只有版本与条数这类信息，不含订阅名称、金额或任何备注 —— 发给开发者排查问题时不会带上你的隐私。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("其他")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .task { await runGapProbeIfNeeded() }
        #endif
    }

    #if DEBUG
    /// 对齐缺口探针（矩阵 EON-071）在「其他」页这一头：拍一帧本页，
    /// 按「复制诊断信息」按钮走的同一个方法，再把剪贴板读回来对账 ——
    /// 证明复制出去的就是这页上此刻显示的那些数字，且不含任何订阅名和金额。
    private func runGapProbeIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-gaps") else { return }
        try? await Task.sleep(for: .seconds(1.4))
        _ = await ProbeShutter.capture("gaps-04-misc-top", settle: 0.8)
        copyDiagnostics()
        try? await Task.sleep(for: .milliseconds(450))
        let pasted = UIPasteboard.general.string ?? "（剪贴板读不出来）"
        let digest = pasted.replacingOccurrences(of: "\n", with: " ／ ")
        Self.gapProbeLogger.log("对齐探针 其他页复制出来的：\(digest, privacy: .public)")
        _ = await ProbeShutter.capture("gaps-05-misc-copied", settle: 0.6)
    }

    private static let gapProbeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")
    #endif

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    /// 真机给的是 iPhone17,1 这样的机型代号；模拟器里是 arm64 / x86_64。
    private var machineIdentifier: String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    private var deviceText: String { "\(UIDevice.current.model) · \(machineIdentifier)" }

    private var liveCount: Int {
        subscriptions.filter { $0.deletedAt == nil && $0.archivedAt == nil }.count
    }

    private var archivedCount: Int {
        subscriptions.filter { $0.deletedAt == nil && $0.archivedAt != nil }.count
    }

    private var trashedCount: Int { subscriptions.filter { $0.deletedAt != nil }.count }

    private func copyDiagnostics() {
        let text = """
        期见 · 诊断信息
        版本：\(versionText)
        系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        机型：\(deviceText)
        订阅：在册 \(liveCount) · 归档 \(archivedCount) · 回收站 \(trashedCount)
        账单事件：\(events.count) 条
        """
        UIPasteboard.general.string = text
        SelectionHaptics.success()
        withAnimation(Motion.ui) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Motion.ui) { copied = false }
        }
    }
}
