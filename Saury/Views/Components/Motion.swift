import SwiftUI
import UIKit
import os

/// 触感：动效不止是看的，切换 / 确认 / 成功各给一下。
enum SelectionHaptics {
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    /// 写库失败专用：绝不能给失败操作配一个成功触感（方案 §9.4）。
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
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

/// 真正按帧插值的金额：数值变化时从**屏幕上此刻的那一个数**滚到新值。
/// 竞品的数字是「整串模糊一闪」，这里是可插值的滚动 + 落定时轻微放大。
///
/// 时间轴只在真的在滚的时候才跑（`paused:`），间隔交给系统 ——
/// 不写 `minimumInterval: 1/60`，否则 120Hz 的设备被这一行按回 60Hz（§9.3）。
struct AnimatedNumber: View {
    let value: Double
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var font: Font = SauryTheme.amountFont(size: 40)
    var duration: Double = 0.62
    var bounce: Double = 0
    /// 首次出现时是否从 0 数上来。
    var countsFromZeroOnAppear: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var roll: NumberRoll
    @State private var emphasised = false

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
        _roll = State(initialValue: NumberRoll(value: value, duration: duration, bounce: bounce))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !roll.isRolling)) { timeline in
            Text(format(roll.value(at: timeline.date)))
                .font(font)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .scaleEffect(emphasised ? 1.03 : 1)
                .onChange(of: timeline.date) { _, now in
                    // 落定判断走的就是这一帧已经在用的那条插值：没有第二个定时器，
                    // 也就没有「上一轮的收尾把这一轮关掉」这件事。
                    if roll.finishIfDue(at: now) {
                        #if DEBUG
                        if Motion.numberProbeEnabled {
                            Motion.probeLogger.log("数字探针 第\(self.roll.round, privacy: .public)轮落定 显示\(plain(self.roll.target), privacy: .public) 真值\(plain(self.value), privacy: .public)")
                        }
                        #endif
                        withAnimation(Motion.pop) { emphasised = false }
                    }
                }
        }
        .onAppear {
            guard !roll.isRolling else { return }
            if reduceMotion {
                roll.prime(value)
            } else if countsFromZeroOnAppear {
                roll.prime(0)
                startRoll(to: value, at: Date())
            }
        }
        .onChange(of: value) { _, next in
            startRoll(to: next, at: Date())
        }
        .onChange(of: reduceMotion) { _, off in
            roll.duration = off ? 0 : duration
            if off {
                roll.stop()
                withAnimation(.easeOut(duration: 0.12)) { emphasised = false }
            }
        }
        .onDisappear {
            // 页面走掉了就别再刷。屏幕上留最后那一个数，不假装中间发生过什么。
            roll.stop()
        }
    }

    private var durationForCurrentSettings: Double { reduceMotion ? 0 : duration }

    /// 起新一轮。减少动态效果时 `roll` 直接把值钉过去，一轮都不起，也就没有放大回落。
    private func startRoll(to next: Double, at now: Date) {
        roll.duration = durationForCurrentSettings
        let round = roll.roll(to: next, at: now)
        #if DEBUG
        if Motion.numberProbeEnabled {
            Motion.probeLogger.log("数字探针 起第\(round, privacy: .public)轮 从\(plain(self.roll.value(at: now)), privacy: .public) 到 \(plain(next), privacy: .public) 目标值就是屏幕上这一格")
        }
        #endif
        guard roll.isRolling else { return }
        withAnimation(.easeOut(duration: 0.12)) { emphasised = true }
    }

    #if DEBUG
    private func plain(_ value: Double) -> String { String(format: "%.2f", value) }
    #endif
}

#if DEBUG
extension Motion {
    /// `-saury-number` 才打开的逐轮日志：录屏对不上哪一帧数到哪儿时用它。
    static let numberProbeEnabled = ProcessInfo.processInfo.arguments.contains("-saury-number")
    static let probeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")
}

/// 录屏对齐用的打点。日志用的是墙上时钟，录屏用的是录屏器自己的秒数，
/// 两者对不上就只能量相对值 —— 「操作到首帧反馈」这种绝对量没法报。
/// 这里在关键事件那一帧把状态栏下面那条带子刷白，日志同一句写下时刻；
/// 事后拿视频里的白帧把两条时间轴钉在一起。带子和被量的区域不重叠。
@MainActor
final class ProbeMarker: ObservableObject {
    static let shared = ProbeMarker()
    @Published private(set) var flashing = false

    /// 白帧留约两帧：一帧怕录屏正好丢掉对不上，再长就要盖住被量的动画了。
    func mark(_ label: String) {
        Motion.probeLogger.log("打点 \(label, privacy: .public)")
        flashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.034) { self.flashing = false }
    }
}

struct ProbeMarkerBand: View {
    @ObservedObject private var marker = ProbeMarker.shared

    var body: some View {
        if marker.flashing {
            Rectangle()
                .fill(Color.white)
                .frame(height: 18)
                .padding(.horizontal, 120)
                .padding(.top, 52)
                .ignoresSafeArea()
        }
    }
}
#endif

// MARK: - 分级入场

private struct StagedAppearance: ViewModifier {
    let index: Int
    var delay: Double = 0
    var edge: Edge = .bottom
    var enabled: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if reduceMotion {
            // §9.4：取消位移、缩放和模糊，只留极短的淡入。
            // 「不让空白帧代替原动画」——内容当场就在，只是透明度收一下。
            content
                .opacity(shown ? 1 : 0)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.12)) { shown = true }
                }
        } else {
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

// MARK: - 方向性切换

/// 滑动量是唯一可动画的量，透明度和缩放都从它派生 ——
/// 这样整段过渡连续插值，不会「位移到位才显形」。
///
/// 减少动态效果时把位移和缩放这两个出口关掉，但透明度**仍然由同一个 x 派生**：
/// 于是过渡变成一次轻微淡入，进度到 1 的那一帧内容才完整 ——
/// 既取消了我移，也不会出现「先空一下再显形」（§9.4）。
private struct SlideFade: ViewModifier, Animatable {
    var x: CGFloat
    var distance: CGFloat
    var shrink: CGFloat
    var fade: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }

    func body(content: Content) -> some View {
        let p = distance > 0 ? min(abs(x) / distance, 1) : 0
        content
            .offset(x: reduceMotion ? 0 : x)
            .opacity(1 - p * fade)
            .scaleEffect(reduceMotion ? 1 : 1 - p * shrink)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swung = false

    var body: some View {
        content
            // §9.4「取消…倾斜和持续摆动」：不开摆的时候就是静止的那一格，
            // 不是把内容藏起来等它摆回来。
            .rotationEffect(.degrees(reduceMotion ? 0 : (swung ? angle : -angle)), anchor: .top)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
                    swung = true
                }
            }
    }
}
