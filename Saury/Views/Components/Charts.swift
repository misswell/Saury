import SwiftUI

/// 支出分类的环形图。中心放折算总额，扇区按占比分色。
///
/// 数据变化时**从旧比例过渡到新比例**（§8.4）：每条弧的起止角是自己的可动画量，
/// 换数据就是重新赋值，SwiftUI 逐帧插值。旧写法是把扫描进度归零再满扫一遍 ——
/// 那中间整个环是空的，正是任务书点名的「先全部清零后突变」。
struct DonutChart: View {
    struct Slice: Identifiable, Equatable {
        let id: String
        let value: Double
        let color: Color
    }

    let slices: [Slice]
    var centerText: String
    var lineWidth: CGFloat = 22
    var size: CGFloat = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 只用于**首次**出现的那一圈顺时针扫描（§9.1「图表初次生长 500–850ms」）。
    /// 之后的数据变化一律走角度插值，不再碰它。
    @State private var sweep: CGFloat = 1
    @State private var appeared = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineColor, lineWidth: lineWidth)
            sliceRing
                .mask(
                    Circle()
                        .trim(from: 0, to: sweep)
                        .stroke(style: StrokeStyle(lineWidth: size * 2, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .frame(width: size, height: size)
                )
                .animation(Motion.chart, value: slices)
            Text(centerText)
                .font(SauryTheme.amountFont(size: size * 0.16))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(lineWidth)
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)
        }
        .frame(width: size, height: size)
        .onAppear(perform: grow)
        .onChange(of: reduceMotion) { _, off in
            if off { land() }
        }
    }

    private var lineColor: Color {
        Color(light: Color(white: 0.92), dark: Color(white: 0.16))
    }

    private var sliceRing: some View {
        ForEach(Array(slicesWithAngles.enumerated()), id: \.element.slice.id) { _, item in
            SliceShape(startDegrees: item.start, endDegrees: item.end)
                .stroke(item.slice.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        }
    }

    private struct SliceWithAngles {
        let slice: Slice
        let start: Double
        let end: Double
    }

    /// 占比 → 角度。分母用同一份数据算出来，所以换一批分类也是连续地重新分配。
    private var slicesWithAngles: [SliceWithAngles] {
        let total = slices.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [] }
        var start = -90.0
        return slices.map { slice in
            let sweep = slice.value / total * 360
            defer { start += sweep }
            return SliceWithAngles(slice: slice, start: start, end: start + sweep - 1.2)
        }
    }

    /// 初次扫描。减少动态效果时直接呈现 —— §9.4 要的是「用直呈代替动画」，
    /// 不是「用空白帧代替动画」，所以这里是落到位，而不是不画。
    private func grow() {
        if reduceMotion {
            land()
            return
        }
        sweep = 0
        appeared = false
        withAnimation(Motion.chart) { sweep = 1 }
        withAnimation(Motion.pop.delay(0.18)) { appeared = true }
    }

    private func land() {
        sweep = 1
        appeared = true
    }

    private struct SliceShape: Shape {
        var startDegrees: Double
        var endDegrees: Double

        var animatableData: AnimatablePair<Double, Double> {
            get { AnimatablePair(startDegrees, endDegrees) }
            set {
                startDegrees = newValue.first
                endDegrees = newValue.second
            }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                        radius: min(rect.width, rect.height) / 2,
                        startAngle: .degrees(startDegrees),
                        endAngle: .degrees(endDegrees),
                        clockwise: false)
            return path
        }
    }
}

/// 支出趋势的柱状图。数据点少的时候只有一根柱，也照常画轴。
struct BarsChart: View {
    struct Bar: Identifiable, Equatable {
        let id: String
        let label: String
        let value: Double
        var highlighted: Bool = false
    }

    let bars: [Bar]
    var highlightColor: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    var body: some View {
        GeometryReader { proxy in
            let maxValue = Swift.max(bars.map(\.value).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: proxy.size.width * 0.06) {
                ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(bar.highlighted ? highlightColor : highlightColor.opacity(0.35))
                            .frame(height: height(for: bar, in: proxy.size.height, maxValue: maxValue))
                            .animation(reduceMotion ? nil : Motion.chart.delay(reduceMotion ? 0 : stagger(index)),
                                       value: grown)
                            .animation(reduceMotion ? nil : Motion.chart, value: bars)
                        Text(bar.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .opacity(grown ? 1 : 0)
                            .animation(reduceMotion ? nil : Motion.ui.delay(stagger(index) + 0.12), value: grown)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear {
            if reduceMotion {
                grown = true
            } else {
                withAnimation(Motion.chart) { grown = true }
            }
        }
        .onChange(of: reduceMotion) { _, off in if off { grown = true } }
    }

    /// 换数据时高度是**连续变过去**的：`maxValue` 和柱子高度都来自同一份 `bars`，
    /// 所以最长的那根换人时，其余柱子是跟着一起缩放的，不是先跳到位再动。
    private func height(for bar: Bar, in total: CGFloat, maxValue: Double) -> CGFloat {
        guard grown else { return 2 }
        return Swift.max(4, total * CGFloat(bar.value / maxValue))
    }

    private func stagger(_ index: Int) -> Double { Double(index) * 0.055 }
}

/// 支出趋势的折线视图：点 + 平滑连线 + 渐变填充，同一份数据换一种看法。
struct LineChart: View {
    struct Point: Identifiable, Equatable {
        let id: String
        let label: String
        let value: Double
        var highlighted: Bool = false
    }

    let points: [Point]
    var highlightColor: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let coordinates = coordinates(in: proxy.size)
            ZStack(alignment: .bottom) {
                TrendShape(values: values, closeForFill: true)
                    .fill(
                        LinearGradient(
                            colors: [highlightColor.opacity(0.35), highlightColor.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .opacity(Double(drawn))
                    .animation(Motion.chart, value: points)
                TrendShape(values: values, closeForFill: false)
                    .trim(from: 0, to: drawn)
                    .stroke(highlightColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .animation(Motion.chart, value: points)
                ForEach(Array(coordinates.enumerated()), id: \.offset) { index, coordinate in
                    Circle()
                        .fill(points[index].highlighted ? highlightColor : SauryTheme.surface)
                        .frame(width: points[index].highlighted ? 9 : 6,
                               height: points[index].highlighted ? 9 : 6)
                        .overlay(Circle().stroke(highlightColor.opacity(points[index].highlighted ? 0.3 : 1),
                                                 lineWidth: 2))
                        .position(coordinate)
                        .opacity(drawn > CGFloat(index + 1) / CGFloat(max(coordinates.count, 1)) ? 1 : 0)
                        .scaleEffect(drawn > CGFloat(index + 1) / CGFloat(max(coordinates.count, 1)) ? 1 : 0.3)
                        .animation(Motion.chart, value: points)
                        .animation(Motion.pop, value: drawn)
                }
                HStack(spacing: 0) {
                    ForEach(points) { point in
                        Text(point.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear {
            if reduceMotion {
                drawn = 1
            } else {
                drawn = 0
                withAnimation(Motion.chart) { drawn = 1 }
            }
        }
        .onChange(of: reduceMotion) { _, off in if off { drawn = 1 } }
    }

    private var values: AnimatableValues { AnimatableValues(points.map(\.value)) }

    /// 折点位置按**当前**数据算，形状自己按插值走：两边用的是同一条 `Motion.chart`，
    /// 所以点是贴在 Online 上滑过去的，不是先脱节再追上。
    private func coordinates(in size: CGSize) -> [CGPoint] {
        let maxValue = Swift.max(points.map(\.value).max() ?? 1, 1)
        let stepX = points.count > 1 ? size.width / CGFloat(points.count - 1) : size.width
        return points.enumerated().map { index, point in
            let x = points.count > 1 ? CGFloat(index) * stepX : size.width / 2
            let heightRatio = CGFloat(point.value / maxValue)
            return CGPoint(x: x, y: size.height * (1 - heightRatio * 0.82) - 16)
        }
    }
}

/// 走势形状。可动画量是「这一列值」本身，所以换数据时整条线是**连续变形**的（§8.4）。
private struct TrendShape: Shape {
    var values: AnimatableValues
    var closeForFill: Bool

    var animatableData: AnimatableValues {
        get { values }
        set { values = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let series = values.values
        guard !series.isEmpty else { return Path() }
        let maxValue = Swift.max(series.max() ?? 1, 1)
        let stepX = series.count > 1 ? rect.width / CGFloat(series.count - 1) : rect.width
        let coordinates = series.enumerated().map { index, value -> CGPoint in
            let x = series.count > 1 ? CGFloat(index) * stepX : rect.width / 2
            let ratio = CGFloat(value / maxValue)
            return CGPoint(x: x, y: rect.height * (1 - ratio * 0.82) - 16)
        }
        return ChartPath.smooth(through: coordinates, closeForFill: closeForFill)
    }
}

/// 把折点连成平滑曲线（Catmull-Rom 转三次贝塞尔）；closeForFill 会闭合到底边供填充。
enum ChartPath {
    static func smooth(through coordinates: [CGPoint], closeForFill: Bool) -> Path {
        var path = Path()
        guard let first = coordinates.first else { return path }
        path.move(to: first)
        guard coordinates.count > 1 else { return path }
        if coordinates.count == 2 {
            path.addLine(to: coordinates[1])
        } else {
            for index in 0..<(coordinates.count - 1) {
                let current = coordinates[index]
                let next = coordinates[index + 1]
                let previous = index > 0 ? coordinates[index - 1] : current
                let afterNext = index + 2 < coordinates.count ? coordinates[index + 2] : next
                let control1 = CGPoint(x: current.x + (next.x - previous.x) / 6,
                                       y: current.y + (next.y - previous.y) / 6)
                let control2 = CGPoint(x: next.x - (afterNext.x - current.x) / 6,
                                       y: next.y - (afterNext.y - current.y) / 6)
                path.addCurve(to: next, control1: control1, control2: control2)
            }
        }
        if closeForFill {
            path.addLine(to: CGPoint(x: coordinates.last!.x, y: coordinates.last!.y))
            path.addLine(to: CGPoint(x: coordinates.first!.x, y: coordinates.first!.y))
            path.closeSubpath()
        }
        return path
    }
}
