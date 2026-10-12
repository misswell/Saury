import SwiftUI
import UIKit

/// 触感：动效不止是看的，切换 / 确认 / 成功各给一下。
enum SelectionHaptics {
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// 全站动效词汇表。曲线全部用「快起步 + 长收束」的阻尼弹簧：
/// 竞品 EON 的 sheet 是 400ms 无回弹、数字滚动 150ms、环形图 650ms 近似线性，
/// 我们在同一节奏上补齐它没有的部分（分级入场、图表生长、按压反馈、跨页衔接）。
enum Motion {
    /// 页面级：sheet 进出、tab 切换。起步快、尾巴长、不回弹。
    static let page = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.46)
    /// 整段位移（翻页、翻月）：行程要铺在时间轴上。
    /// page 那条太前载 —— 70ms 就走完 90% 的路，剩下全是看不见的余量，
    /// 翻页会像「闪一下黑屏再显形」。
    static let slide = Animation.timingCurve(0.32, 0.08, 0.24, 1, duration: 0.44)
    /// 组件级：胶囊指示器、开关、展开收起。
    static let ui = Animation.spring(duration: 0.34, bounce: 0.12, blendDuration: 0)
    /// 弹一下：图标抓取成功、数字落定、按钮回弹。
    static let pop = Animation.spring(duration: 0.5, bounce: 0.34, blendDuration: 0)
    /// 列表行、卡片入场。
    static let entry = Animation.spring(duration: 0.5, bounce: 0.1, blendDuration: 0)
    /// 卡片堆叠翻页定位：甩出去的那一下有轻微回弹。
    static let carouselSnap = Animation.spring(duration: 0.5, bounce: 0.18, blendDuration: 0)
    /// 图表：环形扫描、柱子生长。
    static let chart = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.86)
    /// 数字滚动：比竞品的 150ms 更慢一点，看得清位数，但收得更干净。
    static let number = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.62)
    /// 分级入场的级差。
    static let stagger = 0.055

    /// 归一化时间 -> 进度。bounce=0 是纯 ease-out，越大回弹越明显。
    static func spring(_ x: Double, bounce: Double = 0) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if bounce <= 0 { return 1 - pow(1 - x, 4.2) }
        let decay = 5.5 + (1 - min(bounce, 0.9)) * 6
        let freq = 1.1 + bounce * 2.6
        return 1 - exp(-decay * x) * cos(.pi * freq * x)
    }
}

// MARK: - 滚动数字

/// 真正按帧插值的金额：数值变化时从旧值滚到新值，位数逐位翻动。
/// 竞品的数字是「整串模糊一闪」，这里是可插值的弹簧滚动 + 落定时轻微放大。
struct AnimatedNumber: View {
    let value: Double
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var font: Font = SauryTheme.amountFont(size: 40)
    var duration: Double = 0.62
    var bounce: Double = 0
    /// 首次出现时是否从 0 数上来。
    var countsFromZeroOnAppear: Bool = false

    @State private var from = 0.0
    @State private var target: Double
    @State private var startDate = Date.distantPast
    @State private var running = false
    @State private var settle = false

    init(value: Double, format: @escaping (Double) -> String = { String(format: "%.2f", $0) },
         font: Font = SauryTheme.amountFont(size: 40),
         duration: Double = 0.62, bounce: Double = 0,
         countsFromZeroOnAppear: Bool = false) {
        self.value = value
        self.format = format
        self.font = font
        self.duration = duration
        self.bounce = bounce
        self.countsFromZeroOnAppear = countsFromZeroOnAppear
        _target = State(initialValue: value)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !running)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startDate)
            let x = min(max(elapsed / duration, 0), 1)
            let current = from + (target - from) * Motion.spring(x, bounce: bounce)
            Text(format(running ? current : target))
                .font(font)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .scaleEffect(settle ? 1.03 : 1)
        }
        .onAppear {
            from = countsFromZeroOnAppear ? 0 : target
            if countsFromZeroOnAppear { roll(to: target) }
        }
        .onChange(of: value) { previous, next in
            guard next != previous else { return }
            roll(to: next)
        }
    }

    private func roll(to next: Double) {
        from = currentDisplayValue()
        target = next
        startDate = Date()
        withAnimation(.easeOut(duration: 0.12)) { settle = true }
        running = true
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation(.spring(duration: 0.35, bounce: 0.25)) { settle = false }
            running = false
        }
    }

    private func currentDisplayValue() -> Double {
        let x = min(max(Date().timeIntervalSince(startDate) / duration, 0), 1)
        return from + (target - from) * Motion.spring(x, bounce: bounce)
    }
}

// MARK: - 分级入场

private struct StagedAppearance: ViewModifier {
    let index: Int
    var delay: Double = 0
    var edge: Edge = .bottom
    var enabled: Bool = true
    @State private var shown = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : (edge == .bottom ? 18 : -10))
                .scaleEffect(shown ? 1 : 0.97)
                .blur(radius: shown ? 0 : 4)
                .onAppear {
                    withAnimation(Motion.entry.delay(delay + Double(index) * Motion.stagger)) {
                        shown = true
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// 第 index 个元素依次入场：位移 + 缩放 + 去模糊。
    func staged(_ index: Int, delay: Double = 0, edge: Edge = .bottom, enabled: Bool = true) -> some View {
        modifier(StagedAppearance(index: index, delay: delay, edge: edge, enabled: enabled))
    }
}

// MARK: - 按压反馈

/// 按下去缩一点、松手弹簧回位。竞品的按钮只有高亮，没有形变。
struct Pressable: ButtonStyle {
    var scale: CGFloat = 0.955
    var animation: Animation = Motion.ui

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.1) : animation,
                       value: configuration.isPressed)
    }
}

/// 卡片整体可按时的反馈：轻缩 + 阴影收紧。
struct CardPressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? 0.02 : 0)
            .animation(configuration.isPressed ? .easeOut(duration: 0.09) : Motion.pop,
                       value: configuration.isPressed)
    }
}

extension View {
    func pressable() -> some View { buttonStyle(Pressable()) }
}

// MARK: - 胶囊指示器（跨选项位移）

/// 用 matchedGeometryEffect 让选中底色在选项之间滑动，而不是瞬间跳过去。
struct SlidingPill<Label: View, Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var namespace: Namespace.ID
    @ViewBuilder var label: (Value, Bool) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    withAnimation(Motion.ui) { selection = option }
                } label: {
                    label(option, isSelected)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(SauryTheme.surfaceElevated)
                                    .matchedGeometryEffect(id: "pill-\(String(describing: Value.self))", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 数值/尺寸动画

/// 让任意 CGFloat 在 0 -> 1 之间用图表曲线生长一次（首帧触发）。
struct GrowOnce: ViewModifier {
    var delay: Double = 0
    var duration: Double = 0.86
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content.environment(\.growProgress, progress)
            .onAppear {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: duration).delay(delay)) {
                    progress = 1
                }
            }
    }
}

private struct GrowProgressKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    /// 0 -> 1 的生长进度，图表读取它来做扫描 / 生长。
    var growProgress: CGFloat {
        get { self[GrowProgressKey.self] }
        set { self[GrowProgressKey.self] = newValue }
    }
}

extension View {
    /// 包住图表，让里面的环形 / 柱状按进度生长。
    func growOnce(delay: Double = 0, duration: Double = 0.86) -> some View {
        modifier(GrowOnce(delay: delay, duration: duration))
    }
}

// MARK: - 方向性切换

/// 滑动量是唯一可动画的量，透明度和缩放都从它派生 ——
/// 这样整段过渡连续插值，不会「位移到位才显形」。
private struct SlideFade: ViewModifier, Animatable {
    var x: CGFloat
    var distance: CGFloat
    var shrink: CGFloat
    var fade: CGFloat

    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }

    func body(content: Content) -> some View {
        let p = distance > 0 ? min(abs(x) / distance, 1) : 0
        content
            .offset(x: x)
            .opacity(1 - p * fade)
            .scaleEffect(1 - p * shrink)
    }
}

extension AnyTransition {
    /// 方向性对滑，给 `if` 分支用：旧页往回滑走、新页滑进来。
    /// 两个前提（都是实测出来的）：
    /// 1. 容器不能有不透明的兄弟子视图压在后面 —— 退场那页会被它盖住，
    ///    看起来就是「旧页瞬间消失」。底色要用 `.background { }` 挂上去。
    /// 2. `.id()` 换身份不会触发退场过渡，只能一个视图顶上去；
    ///    那种位置要把 fade 调到 0.15，否则起步几帧会透出页面底色。
    static func directionalSlide(_ direction: Int, distance: CGFloat = 28,
                                 shrink: CGFloat = 0, fade: CGFloat = 0.85) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: SlideFade(x: CGFloat(direction) * distance, distance: distance, shrink: shrink, fade: fade),
                identity: SlideFade(x: 0, distance: distance, shrink: 0, fade: fade)),
            removal: .modifier(
                active: SlideFade(x: CGFloat(-direction) * distance, distance: distance, shrink: shrink, fade: 0.15),
                identity: SlideFade(x: 0, distance: distance, shrink: 0, fade: 0.15))
        )
    }
}

// MARK: - 环境动（引导页的钟摆）

/// 绕顶部某点小角度来回摆，像铃铛被碰了一下还在晃。
struct AmbientSwing<Content: View>: View {
    var angle: Double = 8
    var period: Double = 2.6
    @ViewBuilder var content: Content
    @State private var swung = false

    var body: some View {
        content
            .rotationEffect(.degrees(swung ? angle : -angle), anchor: .top)
            .onAppear {
                withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
                    swung = true
                }
            }
    }
}
