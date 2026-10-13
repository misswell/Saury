import CoreGraphics
import Foundation
import SwiftUI

/// 一组可以连续插值的数。折线、柱子和环形图的形状都靠它把「上一份数据」搬到「下一份数据」。
///
/// 为什么要专门写一个：`Shape` 只会动画自己的 `animatableData`，而图表要动的是**一整列值**。
/// 数组本身不是 `VectorArithmetic`，所以以前只能「先归零、再重扫一遍」来假装在动 ——
/// 那正是任务书 §8.4 点名的「环形图先全部清零后突变」。有了它，走势是逐帧变形的。
struct AnimatableValues: VectorArithmetic, Equatable {
    var values: [Double]

    init() {
        values = []
    }

    init(_ values: [Double]) {
        self.values = values
    }

    static var zero: AnimatableValues { AnimatableValues() }

    /// 逐位相加，长度不齐时短的那条尾巴补 0 ——
    /// 于是「月视图换到年视图」多出来的那几根柱子是从底部生出来的，而不是凭空出现。
    static func + (lhs: AnimatableValues, rhs: AnimatableValues) -> AnimatableValues {
        AnimatableValues(combined(lhs.values, rhs.values) { $0 + $1 })
    }

    static func - (lhs: AnimatableValues, rhs: AnimatableValues) -> AnimatableValues {
        AnimatableValues(combined(lhs.values, rhs.values) { $0 - $1 })
    }

    static func += (lhs: inout AnimatableValues, rhs: AnimatableValues) { lhs = lhs + rhs }
    static func -= (lhs: inout AnimatableValues, rhs: AnimatableValues) { lhs = lhs - rhs }

    /// 协议要的是原地缩放；插值每一帧都在调它，所以这里只有一次数组遍历。
    mutating func scale(by rhs: Double) {
        for index in values.indices { values[index] *= rhs }
    }

    /// 非 mutating 的那一份走协议默认实现，但默认实现就是「拷贝 + scale」，
    /// 自己写一遍只保证不了两者一致 —— 这里显式转发，测试里用哪个都是同一条码。
    func scaled(by rhs: Double) -> AnimatableValues {
        var copy = self
        copy.scale(by: rhs)
        return copy
    }

    /// 平方长度，不是欧氏长度：协议要这一个，是因为每帧开方不值当。
    /// 「差值为 0 就不用动」这个判断也挂在这里，所以它必须随真实幅度变，不能是列数。
    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    private static func combined(_ lhs: [Double], _ rhs: [Double],
                                 _ merge: (Double, Double) -> Double) -> [Double] {
        let count = Swift.max(lhs.count, rhs.count)
        return (0..<count).map { merge($0 < lhs.count ? lhs[$0] : 0, $0 < rhs.count ? rhs[$0] : 0) }
    }
}
