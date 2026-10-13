import XCTest
@testable import Saury

/// 任务书 §9.3 给「滚动数字」开了六条单子，头三条彼此是有顺序依赖的：
/// 「每次开始新动画时取消上一轮结束任务」「动画从当前显示数值开始」「结束回调只允许结束它所属的动画」。
/// 旧实现用 `asyncAfter(deadline: .now() + duration)` 收尾，第二条改动一到，第一轮的定时器还在路上，
/// 到点就把正在跑的新一轮关掉 —— 表现出来是一段被掐断、又自己跳到位的数字。
/// `NumberRoll` 不放任何定时器，落定判断走的就是屏幕上那一帧同一条插值。
final class NumberRollTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    /// §9.3「动画从当前显示数值开始，而不是从上一轮目标值开始」。
    /// 换目标那一瞬间屏幕上的数不许动 —— 动的只能是接下来的走向。
    func testANewRollPicksUpFromTheNumberOnScreen() {
        var roll = NumberRoll(value: 0, duration: 1)
        roll.roll(to: 100, at: epoch)
        let onTheWay = roll.value(at: at(0.5))
        XCTAssertGreaterThan(onTheWay, 1)
        XCTAssertLessThan(onTheWay, 100)

        let before = onTheWay
        roll.roll(to: 20, at: at(0.5))

        XCTAssertEqual(roll.value(at: at(0.5)), before, accuracy: 0.0000001,
                       "同一瞬间换了目标，显示值却跳了一下")
        XCTAssertEqual(roll.start, before, accuracy: 0.0000001)
    }

    /// 新一轮的起点是「正在显示的那一个数」，不是上一轮的目标。
    func testARetargetReplacesTheGoalInsteadOfTheJourney() {
        var roll = NumberRoll(value: 0, duration: 1)
        roll.roll(to: 100, at: epoch)

        roll.roll(to: 20, at: at(0.25))

        XCTAssertNotEqual(roll.start, 100, "起点不能是上一轮还没到的目标")
        XCTAssertEqual(roll.target, 20)
    }

    /// §9.3「结束回调只允许结束它所属的动画」：被顶掉的那一轮到点时不该有任何发言权。
    func testAReplacedRoundCannotEndTheRoundThatReplacedIt() {
        var roll = NumberRoll(value: 0, duration: 1)
        roll.roll(to: 100, at: epoch)
        roll.roll(to: 20, at: at(0.5))

        XCTAssertFalse(roll.finishIfDue(at: at(1.0)), "旧目标到点，但那是上一轮的时刻表")
        XCTAssertTrue(roll.isRolling, "第二轮还在路上")
        XCTAssertTrue(roll.finishIfDue(at: at(1.5)), "这一轮自己的终点才轮到它落定")
        XCTAssertFalse(roll.isRolling)
    }

    /// 落定必须落在精确的目标上，不许停在「差一点点」。
    func testTheRollEndsExactlyOnTheTarget() {
        var roll = NumberRoll(value: 0, duration: 1)
        roll.roll(to: 252.01, at: epoch)

        XCTAssertTrue(roll.finishIfDue(at: at(1.2)))

        XCTAssertEqual(roll.value(at: at(9)), 252.01, accuracy: 0)
        XCTAssertFalse(roll.isRolling, "落定之后时间轴就该停，别一直刷（§9.5）")
    }

    /// 连点三下：只有最后那一个数留下，中途每一枪都不许留下半截动画。
    func testThreeQuickChangesStillLandOnTheLastNumber() {
        var roll = NumberRoll(value: 0, duration: 1)
        roll.roll(to: 100, at: epoch)
        roll.roll(to: 60, at: at(0.2))
        roll.roll(to: 75, at: at(0.35))

        XCTAssertFalse(roll.finishIfDue(at: at(0.9)), "第三轮的 1 秒还没到，不许提前落定")
        XCTAssertTrue(roll.isRolling)
        XCTAssertTrue(roll.finishIfDue(at: at(1.35)))
        XCTAssertEqual(roll.value(at: at(2)), 75, accuracy: 0)
    }

    /// §9.3「开启减少动态效果时直接或短暂淡入更新」：duration=0 就一轮都不起。
    func testReduceMotionPutsTheNumberThereWithoutStartingARoll() {
        var roll = NumberRoll(value: 0, duration: 0)

        let round = roll.roll(to: 134.14, at: epoch)

        XCTAssertEqual(roll.value(at: epoch), 134.14, accuracy: 0)
        XCTAssertFalse(roll.isRolling)
        XCTAssertEqual(round, 1, "编号照样要走，在路上的旧收尾才认得出自己该作废")
    }

    /// 值没变就不该起新一轮 —— 否则每次父视图重算都会闪一下放大。
    func testTheSameNumberStartsNothing() {
        var roll = NumberRoll(value: 20, duration: 1)

        let round = roll.roll(to: 20, at: epoch)

        XCTAssertEqual(round, 0)
        XCTAssertFalse(roll.isRolling)
    }

    /// 页面销毁：留在半截的数没有意义，直接认当前目标，刷新也就此停（§9.3 第四条）。
    func testStoppingFreezesOnTheCurrentGoalAndStopsRefreshing() {
        var roll = NumberRoll(value: 0, duration: 1)
        roll.roll(to: 100, at: epoch)

        roll.stop()

        XCTAssertFalse(roll.isRolling)
        XCTAssertEqual(roll.value(at: at(0.1)), 100, accuracy: 0)
        XCTAssertFalse(roll.finishIfDue(at: at(2)), "已经停了就不该再冒出一个「结束」")
    }

    /// §9.1「数字更新 350–650ms，无竞争、可读」：不加弹跳时全程单调，不许倒退着数。
    func testAnIncreaseNeverCountsBackwards() {
        var roll = NumberRoll(value: 12, duration: 0.62)
        roll.roll(to: 252, at: epoch)

        var previous = roll.value(at: epoch)
        for step in stride(from: 0.02, through: 0.62, by: 0.02) {
            let now = roll.value(at: at(step))
            XCTAssertGreaterThanOrEqual(now, previous, "涨钱的过程中出现了倒退的一帧")
            previous = now
        }
        XCTAssertEqual(previous, 252, accuracy: 0.001)
    }

    /// 带弹跳的那几档（图标落定、金额强调）可以过冲，但最终必须钉回目标。
    func testABouncyRollOvershootsOnlyToComeBackOnTheTarget() {
        var roll = NumberRoll(value: 0, duration: 0.5, bounce: 0.3)
        roll.roll(to: 100, at: epoch)

        var peak = 0.0
        for step in stride(from: 0.02, through: 0.5, by: 0.02) { peak = max(peak, roll.value(at: at(step))) }
        _ = roll.finishIfDue(at: at(0.6))

        XCTAssertGreaterThan(peak, 100, "弹跳档要真的荡过目标，否则这一档没在测东西")
        XCTAssertEqual(roll.value(at: at(1)), 100, accuracy: 0)
    }

    /// 首屏「从 0 数上来」：起点是 0，不是上一次留下的那个数。
    func testTheFirstAppearanceCanCountUpFromZero() {
        var roll = NumberRoll(value: 134.14, duration: 0.62)
        roll.prime(0)

        roll.roll(to: 134.14, at: epoch)

        XCTAssertEqual(roll.value(at: epoch), 0, accuracy: 0.0001)
        XCTAssertEqual(roll.value(at: at(0.62)), 134.14, accuracy: 0.01)
    }
}
