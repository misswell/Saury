import XCTest
@testable import Saury

/// 任务书 §8.4 要求「环形图从旧比例过渡到新比例，不先全部清零后突变」「折线图走势更新时连续变形」。
/// `Shape` 只会插值自己的 `animatableData`，而图表要动的是**一整列值**，
/// 所以这一列值得自己满足 `VectorArithmetic`。
/// 这里测的就是 SwiftUI 在两层之间实际做的那几步运算：长度不齐时怎么补、中途是哪一帧、
/// 以及「新增的那根柱子」到底是生出来的还是凭空出现的。
final class AnimatableValuesTests: XCTestCase {

    /// 逐位相加：同一列数据换了幅度，每一位都各走各的。
    func testElementWiseAdditionAndSubtraction() {
        let a = AnimatableValues([10, 20, 30])
        let b = AnimatableValues([1, 2, 3])

        XCTAssertEqual((a + b).values, [11, 22, 33])
        XCTAssertEqual((a - b).values, [9, 18, 27])
    }

    /// 月视图换到年视图，桶的数量会变。多出来的尾巴按 0 参与运算 ——
    /// 于是新柱子的起点是 0（从底部生出来），而不是带着上一个桶的数值凭空出现。
    func testTheShorterSeriesPadsWithZeroRatherThanReusingTheLastBucket() {
        let three = AnimatableValues([100, 200, 300])
        let five = AnimatableValues([10, 20, 30, 40, 50])

        XCTAssertEqual((three + five).values, [110, 220, 330, 40, 50])
        XCTAssertEqual((three - five).values, [90, 180, 270, -40, -50])
        XCTAssertEqual((three + five).values.count, 5, "合并后的列数取长的那一条")
    }

    /// 缩放到每一列：折线的高度、柱子的长度是同一次缩放，不能只动第一根。
    func testScalingMultipliesEveryColumn() {
        let v = AnimatableValues([4, 8, 12])
        XCTAssertEqual(v.scaled(by: 0.5).values, [2, 4, 6])
        XCTAssertEqual(v.scaled(by: 0).values, [0, 0, 0])
    }

    /// `zero` 必须是「长度为 0 的列」，加法单位元不能给数据塞进多余的柱子。
    func testZeroIsTheEmptySeriesAndAnAdditiveIdentity() {
        XCTAssertEqual(AnimatableValues.zero.values, [])
        let v = AnimatableValues([7, 9])
        XCTAssertEqual((AnimatableValues.zero + v).values, [7, 9])
        XCTAssertEqual((v + AnimatableValues.zero).values, [7, 9])
    }

    /// 自己减自己是空的：这一条决定「数据没变」时不会留下 infinitesimal 的抖动。
    func testASeriesMinusItselfIsEmptyAndZeroMagnitued() {
        let v = AnimatableValues([7, 9])
        let difference = v - v
        XCTAssertTrue(difference.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(difference.magnitudeSquared, 0, accuracy: 0.0000001)
    }

    /// 中途那一帧是谁：SwiftUI 的插值公式是 `from + (to - from).scaled(by: t)`。
    /// 这一条是整个连续变形的地基 —— 公式在这里对上了，屏幕上那一帧就是它对的结果。
    func testTheMidFrameIsThePerColumnAverage() {
        let from = AnimatableValues([100, 0, 50])
        let to = AnimatableValues([0, 200, 50])
        let halfWay = from + (to - from).scaled(by: 0.5)

        XCTAssertEqual(halfWay.values[0], 50, accuracy: 0.0000001)
        XCTAssertEqual(halfWay.values[1], 100, accuracy: 0.0000001)
        XCTAssertEqual(halfWay.values[2], 50, accuracy: 0.0000001, "没换的那一列一动不动")
    }

    /// 走完全程必须正好落在新数据上，不留「动画结束但位置还差一点」的修正跳动（§12.2 第 8 条）。
    func testRunningTheWholeInterpolationLandsExactlyOnTheNewSeries() {
        let from = AnimatableValues([3, 7])
        let to = AnimatableValues([11, 2])

        for progress in [0.0, 0.25, 0.6, 1.0] {
            let frame = from + (to - from).scaled(by: progress)
            if progress == 1 { XCTAssertEqual(frame.values, to.values) }
            if progress == 0 { XCTAssertEqual(frame.values, from.values) }
        }

        let toLonger = AnimatableValues([3, 7, 5])
        let landed = from + (toLonger - from).scaled(by: 1)
        XCTAssertEqual(landed.values, [3, 7, 5], "终点的新柱子也必须到位")
    }

    /// `VectorArithmetic` 要的是**平方**长度（每帧开方不值当），而「要不要继续动」的判断就挂在这上面。
    /// 它必须随真实幅度变：列数固定的实现会把「只动了 0.0001」和「动了 4 根柱子」判成同一件事。
    func testMagnitudeSquaredTracksTheRealChangeNotTheColumnCount() {
        XCTAssertEqual(AnimatableValues([3, 4]).magnitudeSquared, 25, accuracy: 0.0000001)
        XCTAssertEqual(AnimatableValues([3, 4, 0]).magnitudeSquared, 25, accuracy: 0.0000001)
        XCTAssertEqual(AnimatableValues([0, 0]).magnitudeSquared, 0, accuracy: 0.0000001)
        XCTAssertGreaterThan(AnimatableValues([0.001, 0]).magnitudeSquared, 0)
    }

    /// 原地缩放和转发出去的那一份必须是同一个结果 —— 插值走的是 mutating 这条路，
    /// 而测试和调用点写的是非 mutating 那一条；两者一旦分家，测的就不是屏幕上那个。
    func testScalingInPlaceAndTheNonMutatingCopyAgree() {
        for factor in [0.0, 0.25, 1.0, 3.0, -1.5] {
            var inPlace = AnimatableValues([4, 8, 12])
            inPlace.scale(by: factor)
            XCTAssertEqual(inPlace.values, AnimatableValues([4, 8, 12]).scaled(by: factor).values,
                           "scale(by:) 和 scaled(by:) 在 \(factor) 上结果不同")
        }
    }

    /// `.animation(_:value:)` 靠 Equatable 决定要不要动。
    /// 数据换了却判等，图形就会停在旧比例上 —— 那是比清零更假的「达标」。
    func testDifferentSeriesAreUnequalSoTheChartKnowsToAnimate() {
        XCTAssertEqual(AnimatableValues([1, 2]), AnimatableValues([1, 2]))
        XCTAssertNotEqual(AnimatableValues([1, 2]), AnimatableValues([1, 2, 0]))
        XCTAssertNotEqual(AnimatableValues([1, 2]), AnimatableValues([1, 3]))
    }

    /// 运算符版本也得保持同一套补零规则，否则调用点一旦改用它，行为就悄悄变了。
    func testInPlaceOperatorsFollowTheSamePaddingRule() {
        var v = AnimatableValues([1, 2, 3])
        v += AnimatableValues([10, 20])
        XCTAssertEqual(v.values, [11, 22, 3])

        v -= AnimatableValues([1, 1, 1, 1])
        XCTAssertEqual(v.values, [10, 21, 2, -1])
    }

    /// 空列不能崩：数据一条都还没有时（全新安装、筛完为空）折线得画出一张空图而不是崩掉。
    func testEmptySeriesRoundTrip() {
        let empty = AnimatableValues([])
        XCTAssertEqual(empty.values, [])
        XCTAssertEqual(empty.magnitudeSquared, 0, accuracy: 0.0000001)
        XCTAssertEqual((empty + AnimatableValues([2, 4])).values, [2, 4])
        XCTAssertEqual((AnimatableValues([2, 4]) + empty).values, [2, 4])
    }
}
