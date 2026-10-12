import SwiftUI

/// 三页引导：提醒、集中管理、花销与隐私。最后一页点「开始使用」进主界面。
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0
    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        ZStack {
            SauryTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < 2 {
                        Button("跳过") { finish() }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 20)
                            .padding(.top, 12)
                            .transition(.opacity)
                    }
                }
                .frame(height: 44)
                .animation(Motion.ui, value: page)

                TabView(selection: $page) {
                    reminderPage.tag(0)
                    collectionPage.tag(1)
                    privacyPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .indexViewStyle(.page(backgroundDisplayMode: .never))

                PageDots(count: 3, index: page)
                    .padding(.bottom, 16)

                Button {
                    if page < 2 {
                        SelectionHaptics.tick()
                        withAnimation(Motion.page) { page += 1 }
                    } else {
                        finish()
                    }
                } label: {
                    Text(page < 2 ? "继续" : "开始使用")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            Capsule().fill(Color(hex: preferences.accentHex) ?? .accentColor)
                                .shadow(color: (Color(hex: preferences.accentHex) ?? .accentColor).opacity(0.4),
                                        radius: page == 2 ? 14 : 8, y: 5)
                        )
                }
                .buttonStyle(Pressable(scale: 0.96, animation: Motion.pop))
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }

    private func finish() {
        onFinish()
    }

    // MARK: - 三页

    private var reminderPage: some View {
        VStack(spacing: 20) {
            Spacer()
            AmbientSwing(angle: 11) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                    .padding(38)
                    .background(Circle().fill((Color(hex: preferences.accentHex) ?? .accentColor).opacity(0.14)))
            }
            .staged(0, edge: .top)
            Text("别再被自动续费偷袭")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .staged(1)
            Text("每个订阅自动扣费前提醒你，\n想退留足了反应时间。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .staged(2)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var collectionPage: some View {
        VStack(spacing: 20) {
            Spacer()
            VStack(spacing: 10) {
                miniCard("视频", symbol: "play.tv.fill", color: "#FF375F", price: "¥22")
                    .staged(0, edge: .top)
                miniCard("音乐", symbol: "music.note", color: "#FF6482", price: "¥15")
                    .staged(1, edge: .top)
                miniCard("云盘", symbol: "cloud.fill", color: "#64D2FF", price: "¥6")
                    .staged(2, edge: .top)
            }
            .padding(.horizontal, 44)
            Text("一处，看清所有订阅")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .staged(3)
            Text("期见帮你把散落各处的订阅收进一个地方，\n每月花在哪一目了然。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .staged(4)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var privacyPage: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                DonutChart(
                    slices: [
                        .init(id: "a", value: 45, color: Palette.color("#0A84FF")),
                        .init(id: "b", value: 30, color: Palette.color("#BF5AF2")),
                        .init(id: "c", value: 25, color: Palette.color("#98989D"))
                    ],
                    centerText: "¥131",
                    size: 150
                )
            }
            .staged(0, edge: .top)
            .padding(.bottom, 8)
            Text("花销清楚，隐私安心")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .staged(1)
            Text("月 / 季 / 年支出、分类占比看得明明白白；\n数据只存在你的设备上，不上传任何服务器。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .staged(2)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func miniCard(_ name: String, symbol: String, color: String, price: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.color(color)))
            Text(name).font(.subheadline.weight(.medium))
            Spacer()
            Text(price).font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SauryTheme.surface))
    }
}

struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: dot == index ? 16 : 6, height: 6)
                    .animation(Motion.pop, value: index)
            }
        }
    }
}
