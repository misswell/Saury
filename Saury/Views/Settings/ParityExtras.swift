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

/// 外观设置里的 App 图标选择（自动 / 浅色 / 深色）。
struct AppIconSwitcher: View {
    @EnvironmentObject private var preferences: SubPreferences
    @State private var currentName: String? = UIApplication.shared.alternateIconName
    @State private var pendingConfirmation = false

    private enum IconChoice: String, CaseIterable {
        case auto = ""
        case light = "AppIconLight"
        case dark = "AppIconDark"

        var title: String {
            switch self {
            case .auto: return "自动"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        var assetName: String {
            switch self {
            case .auto: return "AppIcon-Auto"
            case .light: return "AppIcon-Light"
            case .dark: return "AppIcon-Dark"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("App 图标").font(.subheadline)
                Spacer()
                Text(currentName == nil ? "自动" : (currentName == IconChoice.light.rawValue ? "浅色" : "深色"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                ForEach(IconChoice.allCases, id: \.rawValue) { choice in
                    Button {
                        apply(choice)
                    } label: {
                        VStack(spacing: 6) {
                            let iconImage = UIImage(named: choice.assetName) ?? UIImage()
                            Image(uiImage: iconImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay(alignment: .bottomTrailing) {
                                    if isActive(choice) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.white, Color.accentColor)
                                            .offset(x: 4, y: 4)
                                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                                    }
                                }
                                .scaleEffect(isActive(choice) ? 1.05 : 1)
                                .shadow(color: Color.accentColor.opacity(isActive(choice) ? 0.35 : 0),
                                        radius: isActive(choice) ? 9 : 0, y: 3)
                            Text(choice.title)
                                .font(.caption2)
                                .foregroundStyle(isActive(choice) ? Color.accentColor : .secondary)
                        }
                        .animation(Motion.pop, value: currentName)
                    }
                    .buttonStyle(Pressable(scale: 0.92, animation: Motion.pop))
                }
            }
            Text("「自动」跟随系统在亮/暗色间切换，也可固定为浅色或深色。切换时系统会弹一下确认提示。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func isActive(_ choice: IconChoice) -> Bool {
        (choice == .auto && currentName == nil) || currentName == choice.rawValue
    }

    private func apply(_ choice: IconChoice) {
        let target: String? = choice == .auto ? nil : choice.rawValue
        guard target != currentName else { return }
        SelectionHaptics.impact(.light)
        UIApplication.shared.setAlternateIconName(target) { error in
            DispatchQueue.main.async {
                if error == nil {
                    currentName = target
                }
            }
        }
    }
}
