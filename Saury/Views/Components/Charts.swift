import SwiftUI

/// 支出分类的环形图。中心放折算总额，扇区按占比分色。
struct DonutChart: View {
    struct Slice: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let slices: [Slice]
    var centerText: String
    var lineWidth: CGFloat = 22
    var size: CGFloat = 120

    /// 0 -> 1 的扫描进度：环形按顺时针画出来，而不是瞬间铺满。
    @State private var sweep: CGFloat = 0
    @State private var appeared = false

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
            Text(centerText)
                .font(SauryTheme.amountFont(size: size * 0.16))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(lineWidth)
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(Motion.chart) { sweep = 1 }
            withAnimation(Motion.pop.delay(0.18)) { appeared = true }
        }
        .onChange(of: slices.map { $0.value }) { _, _ in
            withAnimation(Motion.chart) { sweep = 0 }
            withAnimation(Motion.chart.delay(0.02)) { sweep = 1 }
        }
    }

    private var lineColor: Color {
        Color(light: Color(white: 0.92), dark: Color(white: 0.16))
    }

    private var sliceRing: some View {
        ForEach(Array(slicesWithAngles.enumerated()), id: \.element.slice.id) { _, item in
            SliceShape(startAngle: item.start, endAngle: item.end)
                .stroke(item.slice.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        }
    }

    private struct SliceWithAngles {
        let slice: Slice
        let start: Angle
        let end: Angle
    }

    private var slicesWithAngles: [SliceWithAngles] {
        let total = slices.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [] }
        var start = Angle.degrees(-90)
        var results: [SliceWithAngles] = []
        for slice in slices {
            let sweep = Angle.degrees(slice.value / total * 360)
            results.append(SliceWithAngles(slice: slice, start: start, end: start + sweep - Angle.degrees(1.2)))
            start += sweep
        }
        return results
    }

    private struct SliceShape: Shape {
        let startAngle: Angle
        let endAngle: Angle

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                        radius: min(rect.width, rect.height) / 2,
                        startAngle: startAngle,
                        endAngle: endAngle,
                        clockwise: false)
            return path
        }
    }
}

/// 支出趋势的柱状图。数据点少的时候只有一根柱，也照常画轴。
struct BarsChart: View {
    struct Bar: Identifiable {
        let id: String
        let label: String
        let value: Double
        var highlighted: Bool = false
    }

    let bars: [Bar]
    var highlightColor: Color = .accentColor

    @State private var grown = false

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(bars.map(\.value).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: proxy.size.width * 0.06) {
                ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(bar.highlighted ? highlightColor : highlightColor.opacity(0.35))
                            .frame(height: grown
                                ? max(4, proxy.size.height * CGFloat(bar.value / maxValue))
                                : 2)
                            .animation(Motion.chart.delay(Double(index) * 0.055), value: grown)
                            .animation(Motion.chart, value: bars.map(\.value))
                        Text(bar.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .opacity(grown ? 1 : 0)
                            .animation(Motion.ui.delay(Double(index) * 0.055 + 0.12), value: grown)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear { grown = true }
    }
}

/// 支出趋势的折线视图：点 + 平滑连线 + 渐变填充，同一份数据换一种看法。
struct LineChart: View {
    struct Point: Identifiable {
        let id: String
        let label: String
        let value: Double
        var highlighted: Bool = false
    }

    let points: [Point]
    var highlightColor: Color = .accentColor

    @State private var drawn: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(points.map(\.value).max() ?? 1, 1)
            let stepX = points.count > 1 ? proxy.size.width / CGFloat(points.count - 1) : proxy.size.width
            let coordinates = points.enumerated().map { index, point -> CGPoint in
                let x = points.count > 1 ? CGFloat(index) * stepX : proxy.size.width / 2
                let heightRatio = CGFloat(point.value / maxValue)
                return CGPoint(x: x, y: proxy.size.height * (1 - heightRatio * 0.82) - 16)
            }
            let linePath = Self.smoothPath(through: coordinates, closeForFill: false)
            let fillPath = Self.smoothPath(through: coordinates, closeForFill: true)
            ZStack(alignment: .bottom) {
                fillPath
                    .fill(
                        LinearGradient(
                            colors: [highlightColor.opacity(0.35), highlightColor.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .opacity(Double(drawn))
                linePath
                    .trim(from: 0, to: drawn)
                    .stroke(highlightColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                ForEach(Array(coordinates.enumerated()), id: \.offset) { index, coordinate in
                    Circle()
                        .fill(points[index].highlighted ? highlightColor : SauryTheme.surface)
                        .frame(width: points[index].highlighted ? 9 : 6, height: points[index].highlighted ? 9 : 6)
                        .overlay(Circle().stroke(highlightColor.opacity(points[index].highlighted ? 0.3 : 1), lineWidth: 2))
                        .position(coordinate)
                        .opacity(drawn > CGFloat(index + 1) / CGFloat(max(coordinates.count, 1)) ? 1 : 0)
                        .scaleEffect(drawn > CGFloat(index + 1) / CGFloat(max(coordinates.count, 1)) ? 1 : 0.3)
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
            withAnimation(Motion.chart) { drawn = 1 }
        }
        .onChange(of: points.map(\.value)) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) { drawn = 0.15 }
            withAnimation(Motion.chart.delay(0.16)) { drawn = 1 }
        }
    }

    /// 把折点连成平滑曲线（Catmull-Rom 转三次贝塞尔）；closeForFill 会闭合到底边供填充。
    static func smoothPath(through coordinates: [CGPoint], closeForFill: Bool) -> Path {
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
                let control1 = CGPoint(x: current.x + (next.x - previous.x) / 6, y: current.y + (next.y - previous.y) / 6)
                let control2 = CGPoint(x: next.x - (afterNext.x - current.x) / 6, y: next.y - (afterNext.y - current.y) / 6)
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
