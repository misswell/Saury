import Foundation

/// 一段滚动数字的全部算术：从「此刻屏幕上那一个数」出发，走向新目标。
///
/// 抽出来的原因是任务书 §9.3 那几条互相咬着：「每次开始新动画时取消上一轮结束任务」
/// 「动画从当前显示数值开始」「结束回调只允许结束它所属的动画」。旧实现把收尾挂在
/// `asyncAfter(deadline: .now() + duration)` 上 —— 第二次改动来了，第一轮的定时器还在路上，
/// 到点就把第二轮刚起的动画关掉：屏幕上是一段被掐断、又自己跳到位的数字。
/// 这里根本不放定时器，落定判断走同一条插值，所以「谁的结束回调」这个问题一开始就不存在。
struct NumberRoll {
    /// 一轮滚动的时长。减少动态效果时是 0：直接落位，不滚。
    var duration: Double
    var bounce: Double

    /// 这一轮的起点值 —— 永远是上一轮被打断时**正在显示**的那一个数。
    private(set) var start: Double
    private(set) var target: Double
    /// nil 表示没有在滚，屏幕上就是 target。
    private(set) var startedAt: Date?
    /// 轮次编号。视图用它把「上一轮的收尾」认出来并作废。
    private(set) var round = 0

    init(value: Double, duration: Double = 0.62, bounce: Double = 0) {
        self.duration = duration
        self.bounce = bounce
        start = value
        target = value
    }

    var isRolling: Bool { startedAt != nil }

    /// 屏幕上此刻的数。
    func value(at date: Date) -> Double {
        guard let began = startedAt, duration > 0 else { return target }
        let progress = date.timeIntervalSince(began) / duration
        guard progress < 1 else { return target }
        return start + (target - start) * Motion.spring(progress, bounce: bounce)
    }

    /// 换目标。`date` 那一刻的显示值成为新一轮的起点，所以中途改动绝不让数字跳一下。
    /// 返回值是这一轮的编号，视图把它和「落定」这件事绑在一起。
    @discardableResult
    mutating func roll(to next: Double, at date: Date) -> Int {
        guard next != target else { return round }
        if duration <= 0 {
            // 减少动态效果：直接落位。仍然要换编号，让任何在路上的旧收尾作废。
            start = next
            target = next
            startedAt = nil
            round += 1
            return round
        }
        start = value(at: date)
        target = next
        startedAt = date
        round += 1
        return round
    }

    /// 第一次调用时把当前值钉成起点，供「出现时从 0 数上来」这类首帧用。
    mutating func prime(_ value: Double) {
        start = value
        target = value
        startedAt = nil
    }

    /// 到点了没有。到了就把内部状态钉在 target 上并结束这一轮。
    /// 只有**当前这一轮**到点才返回 true —— 半途被接管的那一轮不会再冒出一个「结束」来关掉别人的动画。
    mutating func finishIfDue(at date: Date) -> Bool {
        guard let began = startedAt else { return false }
        guard date.timeIntervalSince(began) >= duration else { return false }
        startedAt = nil
        start = target
        return true
    }

    /// 页面销毁：停止刷新。屏幕上留最后那一个数，不假装中间发生过什么。
    mutating func stop() {
        guard isRolling else { return }
        startedAt = nil
        start = target
    }
}
