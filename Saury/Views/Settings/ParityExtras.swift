import SwiftUI
import StoreKit

/// 第一笔订阅保存后的提醒引导：开启 / 以后再说。
struct ReminderPromptView: View {
    var onFinish: () -> Void

    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        VStack(spacing: 18) {
            AmbientSwing(angle: 9) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                    .padding(26)
                    .background(Circle().fill((Color(hex: preferences.accentHex) ?? .accentColor).opacity(0.14)))
            }
            .padding(.top, 34)
            .staged(0, edge: .top)

            Text("开启续费提醒")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .staged(1, delay: 0.05)

            Text("我们会在每个订阅扣费前提醒你，免得忘了取消试用或被自动续费。开启后可随时在「设置 → 通知」里关闭。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .staged(2, delay: 0.1)

            Button {
                SelectionHaptics.impact(.medium)
                Task {
                    let granted = await SubscriptionScheduler.shared.requestAuthorization()
                    preferences.notificationsEnabled = granted
                    onFinish()
                }
            } label: {
                Text("开启提醒")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(Color(hex: preferences.accentHex) ?? .accentColor))
            }
            .buttonStyle(Pressable(scale: 0.96, animation: Motion.pop))
            .padding(.horizontal, 24)
            .staged(3, delay: 0.15)

            Button("以后再说") { onFinish() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
                .staged(4, delay: 0.2)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// 关于页里的「版本历史」。
struct VersionHistoryView: View {
    private struct VersionEntry: Identifiable {
        let version: String
        let date: String
        let notes: [String]

        var id: String { version }
    }

    private let entries: [VersionEntry] = [
        VersionEntry(version: "1.1", date: "2026 年 10 月", notes: [
            "期见转向订阅管理：即将扣费、分类支出、扣费日历、支出趋势、累计支付与小票",
            "图标库 / App Store 搜索 / 网址 / 相册四种图标来源，卡片颜色自动或手动渐变",
            "拼车分摊、多币种与实时汇率、回收站与归档、iCloud 同步",
            "旧「到期物品」时代的订阅记录自动迁入"
        ]),
        VersionEntry(version: "1.0", date: "2026 年 9 月", notes: [
            "期见上线：到期决策助手，扫描包装记录保质期",
            "分阶段提醒队列与通知快捷操作、Widget、备份"
        ])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("v\(entry.version)")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Spacer()
                            Text(entry.date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(entry.notes, id: \.self) { note in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(Color.accentColor.opacity(0.7)).frame(width: 5, height: 5).padding(.top, 6)
                                Text(note)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sauryCard()
                    .staged(index, edge: .top)
                }
            }
            .padding(.horizontal, SauryTheme.screen)
            .padding(.vertical, 14)
        }
        .background(SauryTheme.background)
        .navigationTitle("版本历史")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一个格子 = 一个真实的备用图标名。
///
/// 抽成 view 外面的独立类型，是为了让 XCTest 能直接问「点『深色』到底把什么名字
/// 交给系统」—— 这件事以前藏在私有嵌套枚举里，测不到。
enum AppIconChoice: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    /// nil 表示「不指定备用图标」，也就是用主图标。
    /// 「自动」不是我们自己在亮/暗之间切图：iOS 18 起系统会拿主图标做亮色/暗色/染色三种外观，
    /// 交给系统才是这一档真正的语义。
    var alternateName: String? {
        switch self {
        case .auto: return nil
        case .light: return "AppIconLight"
        case .dark: return "AppIconDark"
        }
    }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 设置页那三块格子的预览图资源名（由 `scripts/make-app-icon-variants.swift` 生成）。
    var previewAssetName: String {
        switch self {
        case .auto: return "AppIcon-Auto"
        case .light: return "AppIcon-Light"
        case .dark: return "AppIcon-Dark"
        }
    }

    /// 系统当前那个名字对应哪一档。认不出来（比如老版本留下的名字）就当主图标。
    static func matching(_ alternateName: String?) -> AppIconChoice {
        guard let alternateName else { return .auto }
        return allCases.first { $0.alternateName == alternateName } ?? .auto
    }
}

/// 打包产物里到底带了哪些备用图标。
///
/// 唯一事实来源是 Info.plist 的 `CFBundleIcons`：资源没进包、
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` 没配，这里就是空的。
/// 页面据此决定摆不摆那三个格子，而不是摆三个点了必然失败的按钮（§10.3）。
struct AppIconConfiguration: Equatable {
    /// 这台设备/这个包支不支持换图标。
    let supportsAlternateIcons: Bool
    /// Info.plist 里真配了名字的备用图标集合。
    let alternateNames: Set<String>

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:],
         supportsAlternateIcons: Bool = UIApplication.shared.supportsAlternateIcons) {
        self.supportsAlternateIcons = supportsAlternateIcons
        self.alternateNames = AppIconConfiguration.alternateNames(in: info)
    }

    /// iPhone 和 iPad 各有一份图标配置（`CFBundleIcons` / `CFBundleIcons~ipad`），取并集。
    static func alternateNames(in info: [String: Any]) -> Set<String> {
        var names: Set<String> = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] as? [String: Any] else { continue }
            for section in ["CFBundleAlternateIcons", "CFBundleAlternateIcons~ipad"] {
                guard let alternates = icons[section] as? [String: Any] else { continue }
                names.formUnion(alternates.keys)
            }
        }
        return names
    }

    /// 「自动」不需要配用图标 —— 主图标一定在包里。
    func isAvailable(_ choice: AppIconChoice) -> Bool {
        guard supportsAlternateIcons else { return false }
        guard let name = choice.alternateName else { return true }
        return alternateNames.contains(name)
    }
}

/// 换图标这件事的「谁去换」。抽出来只为一件事：
/// 「系统返回错误」这一条必须在测试里演得出来，而不是等人去点坏一次。
protocol AppIconApplying {
    var currentAlternateIconName: String? { get }
    func apply(_ name: String?, completion: @escaping (Error?) -> Void)
}

extension AppIconApplying {
    var currentChoice: AppIconChoice { .matching(currentAlternateIconName) }
}

struct SystemAppIconApplier: AppIconApplying {
    var currentAlternateIconName: String? { UIApplication.shared.alternateIconName }

    func apply(_ name: String?, completion: @escaping (Error?) -> Void) {
        UIApplication.shared.setAlternateIconName(name, completionHandler: completion)
    }
}

/// 那三格现在是什么状态：选了哪档、哪档在路上、有没有报错。
///
/// 值类型 + 把「该不该发请求」答成 `Intent`，是为了让 §10.3 那句
/// 「系统返回错误时 UI 不显示假成功状态」成为一条能跑断言的规则，而不是一句承诺。
struct AppIconSelection: Equatable {
    private(set) var current: AppIconChoice
    /// 正在等系统回话的那一档。非空时不接受第二下。
    private(set) var pending: AppIconChoice?
    /// 页面上要摊出来的那句话（nil = 没话）。
    private(set) var failure: String?
    let configuration: AppIconConfiguration

    init(configuration: AppIconConfiguration, current: AppIconChoice = .auto) {
        self.configuration = configuration
        self.current = current
    }

    /// 点了一格。要不要真的去换，由这里说 —— view 只负责把 `Intent` 交给系统。
    enum Intent: Equatable {
        /// 什么都不该发生（已经是这一档，或者上一笔还没回话）。
        case ignore
        /// 把这个名字交给系统。
        case apply(String?)
        /// 这一档按不了，原因写在页面上。
        case refused(String)
    }

    mutating func tap(_ choice: AppIconChoice) -> Intent {
        guard configuration.supportsAlternateIcons else {
            failure = "这台设备不支持更换 App 图标，没有改动。"
            return .refused(failure!)
        }
        guard configuration.isAvailable(choice) else {
            let name = choice.alternateName ?? choice.title
            failure = "这个包里没找到备用图标「\(name)」，没有改动。"
            return .refused(failure!)
        }
        guard pending == nil, choice != current else { return .ignore }
        pending = choice
        failure = nil
        return .apply(choice.alternateName)
    }

    /// 系统回话了。`systemName` 是回话那一刻系统真正记着的图标名。
    ///
    /// 选中态一律跟着 `systemName` 走，成功失败都一样 —— 图标是系统记的账，
    /// 我们只是转述。实测模拟器上出现过「返回了错误、名字却已经改了」，
    /// 跟着系统走就不会两种情况下都说假话。
    mutating func completed(systemName: String?, error: Error?) {
        let target = pending
        pending = nil
        guard let target else { return }
        current = .matching(systemName)
        guard let error else {
            failure = nil
            return
        }
        failure = current == target
            ? "系统返回了错误，但图标已经换成「\(target.title)」：\(error.localizedDescription)"
            : "系统没接受这次切换：\(error.localizedDescription)"
    }

    /// 回到这一页时以系统为准（用户可能在别处换过，或者系统自己重置了）。
    mutating func readFromSystem(_ name: String?) {
        guard pending == nil else { return }
        current = .matching(name)
    }
}

/// 外观设置里的 App 图标选择（自动 / 浅色 / 深色）。
struct AppIconSwitcher: View {
    @EnvironmentObject private var preferences: SubPreferences

    @State private var selection = AppIconSelection(
        configuration: AppIconConfiguration(),
        current: .matching(UIApplication.shared.alternateIconName)
    )
    private let applier: AppIconApplying = SystemAppIconApplier()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("App 图标").font(.subheadline)
                Spacer()
                Text(selection.configuration.supportsAlternateIcons ? selection.current.title : "不可更换")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                ForEach(AppIconChoice.allCases) { choice in
                    tile(choice)
                }
            }
            footnote
            if let failure = selection.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.86, green: 0.24, blue: 0.24))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 6)
        .animation(Motion.ui, value: selection.failure)
        .animation(Motion.pop, value: selection.current)
        // 图标名是系统记的，不是我们记的：回到这一页要以系统为准。
        .onAppear {
            selection.readFromSystem(UIApplication.shared.alternateIconName)
            #if DEBUG
            // 命令行点不动这一格，所以探针直接调那一下要调的同一个方法：
            // 换到和现在不同的那一档，看这一页最后把结果说成什么样。
            if selection.pending == nil,
               CommandLine.arguments.contains("-saury-icon") {
                tap(selection.current == .dark ? .light : .dark)
            }
            #endif
        }
    }

    @ViewBuilder
    private var footnote: some View {
        if selection.configuration.supportsAlternateIcons == false {
            Text("这台设备不给 App 换图标（系统限制，或打包时没配备用图标）。下面三个格子只是预览。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("「自动」用主图标，由系统决定亮/暗/染色那一版；也可以固定选浅色或深色。"
                 + "选完以系统记下的那一个为准，系统没接受会在这下面说出来。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let selectable = selection.configuration.isAvailable(choice)
        return Button {
            tap(choice)
        } label: {
            VStack(spacing: 6) {
                preview(choice)
                    .frame(width: 56, height: 56)
                    .overlay {
                        if !selectable {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if selection.current == choice {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 4, y: 4)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .overlay {
                        if selection.current == choice {
                            // 对勾之外还有一圈描边：选中不能只靠一个颜色的差别来说话（§11.2）。
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
                    .scaleEffect(selection.current == choice ? 1.05 : 1)
                    .shadow(color: Color.accentColor.opacity(selection.current == choice ? 0.35 : 0),
                            radius: selection.current == choice ? 9 : 0, y: 3)
                Text(choice.title)
                    .font(.caption2)
                    .foregroundStyle(selection.current == choice ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(Pressable(scale: 0.92, animation: Motion.pop))
        .disabled(selection.pending != nil)
        .accessibilityLabel("\(choice.title)图标")
        .accessibilityValue(selection.current == choice ? "已选用" : (selectable ? "未选用" : "不可选用"))
        .accessibilityHint(selectable ? "点按切换到这一档" : "")
    }

    /// 预览图取不到时不能留一块白：那是「资源没进包」最该被看见的样子。
    @ViewBuilder
    private func preview(_ choice: AppIconChoice) -> some View {
        if let image = UIImage(named: choice.previewAssetName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: "questionmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tap(_ choice: AppIconChoice) {
        switch selection.tap(choice) {
        case .ignore, .refused:
            if selection.failure != nil { SelectionHaptics.error() }
            return
        case .apply(let name):
            SelectionHaptics.impact(.light)
            let applier = self.applier
            applier.apply(name) { error in
                DispatchQueue.main.async {
                    selection.completed(systemName: applier.currentAlternateIconName, error: error)
                    if error != nil { SelectionHaptics.error() }
                }
            }
        }
    }
}
