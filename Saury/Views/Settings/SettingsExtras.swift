import SwiftUI
import SwiftData
import StoreKit

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
                Text("清除已删除订阅遗留的图标文件。当前使用中的订阅图标不会被删除。")
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

/// 支持开发者：一次性打赏位（用现有终身买断产品承载，不解锁任何功能）。
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
                    .staged(0, edge: .top)
                Text("你养的不是订阅，是开发者")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .staged(1, delay: 0.05)
                Text("期见帮你看住了钱包。要是它真帮上了忙，请开发者喝杯咖啡续个命？")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .staged(2, delay: 0.1)

                tipRow(emoji: "☕️", title: "速溶咖啡", caption: "一包速溶冲下去，提神继续敲代码", price: "¥8")
                    .staged(3, delay: 0.15)
                tipRow(emoji: "🧋", title: "冰美式", caption: "冰美式续命，Bug 一个个退散", price: "¥22")
                    .staged(4, delay: 0.2)
                tipRow(emoji: "🫖", title: "冷萃咖啡", caption: "冷萃慢慢滴，功能慢慢磨", price: "¥38")
                    .staged(5, delay: 0.25)

                if let product = store.product {
                    Button {
                        SelectionHaptics.impact(.medium)
                        Task { await store.purchase(product) }
                    } label: {
                        Text(store.isPurchased ? "已支持，谢谢！" : "请开发者喝一杯")
                            .font(.headline)
                            .contentTransition(.opacity)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(Pressable(scale: 0.96, animation: Motion.pop))
                    .disabled(store.isPurchased)
                    .animation(Motion.pop, value: store.isPurchased)
                    .staged(6, delay: 0.3)
                } else {
                    Text("内购暂不可用")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("完全自愿 · 不解锁任何功能 · 一次性，不是订阅\n你都在用订阅管理 App 了，就别再给自己加一个叫期见的订阅啦 😜")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .staged(7, delay: 0.35)
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
    }

    private func tipRow(emoji: String, title: String, caption: String, price: String) -> some View {
        HStack(spacing: 12) {
            Text(emoji).font(.system(size: 28))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(price)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor))
        }
        .padding(12)
        .sauryCard()
    }
}
