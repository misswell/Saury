import CoreGraphics
import Foundation

/// 卡片堆叠轮播的位置算术。纯值类型，不含 SwiftUI，所以任务书 §8.1 那八条
/// 能在测试里逐帧问出来，而不是靠录屏事后猜。
///
/// **符号约定**：所有位移都用「往前翻了几页」表示，往前是正。卡片堆里 `depth < 0`
/// 的那些摆在左边（见 `cardLayer`），所以手指往左拖必须让 `position` 变大；
/// 像素 → 页的转换由视图负责，轨道自己不认识屏幕坐标。
///
/// 为什么不用 `withAnimation`：它改的是「目标值」，模型里的 `position` 在赋值那一帧
/// 就跳到终点了，屏幕上却还在半路。手指在定位动画进行到一半时搭上卡片，读到的就是
/// 终点值 —— 卡片会先从可见位置瞬移过去再跟手。§9.2 要的「动画进行到 50% 时再次触发」
/// 在这套写法下是天然成立的：`position` 永远等于屏幕上那一个值。
struct CarouselTrack {
    /// 一屏卡宽对应多少页位移。慢拖时 1 屏宽 = 1.35 页，比 1:1 更跟得住手指。
    /// 只有 `pages(fromPixels:)` 用它：轨道本身一律按「页」计算，不认识屏幕坐标。
    static let sensitivity = 1.35

    /// 拖出边界之后的可视余量（页）。阻尼式橡皮筋：越拖越沉，但永远不会真的把卡片拖走。
    static let overscrollHeap = 0.42
    /// Fairbairn 阻尼系数，越小越硬。
    static let overscrollConstant = 0.55

    /// 弹簧：ζ=0.82、ω=16.5 大约在 0.4 秒内收敛，只留一次很轻的过冲 ——
    /// 对应 §9.1 表里「卡片定位 250–500ms，可中断弹簧」。
    static let responseFrequency = 16.5
    static let dampingRatio = 0.82

    private(set) var pageCount: Int
    /// 屏幕上那一格的位置，可能是半格。
    private(set) var position: Double
    /// 手势开始时定下的基准（§8.1 第一句）。拖拽全程不回读四舍五入的页码，
    /// 因为 `focused` 一变、基准就跟着跳，卡片在指下瞬间平移。
    private(set) var anchor: Double
    /// 页/秒。拖拽期间由手指算出来，松手时当成积分器的初速度，甩动才连得上。
    private(set) var velocity = 0.0
    /// 手指离开后要落去的那一格。nil 表示正被手指带着走。
    private(set) var target: Double?

    private var lastSampleTime: Date?
    private var lastSamplePosition = 0.0
    /// 减少动态效果时松手直接落格，不再弹（§9.4「取消大范围位移」）。
    var animatesSettle = true

    init(pageCount: Int, position: Double = 0) {
        self.pageCount = max(pageCount, 0)
        let bounds = Self.bounds(for: self.pageCount)
        self.position = min(max(position, bounds.lowerBound), bounds.upperBound)
        self.anchor = self.position
    }

    var bounds: ClosedRange<Double> { Self.bounds(for: pageCount) }

    /// 当前落在哪一格。只在需要报页码、给触感、点亮指示点时用；绝不用它当拖拽基准。
    var focusedPage: Int {
        min(max(Int(position.rounded()), 0), max(pageCount - 1, 0))
    }

    /// 时间轴还要不要继续跑。落定之后停，省掉每帧重绘（§9.5「不为屏幕外的东西持续启动时间轴」）。
    var isSettling: Bool { target != nil }

    // MARK: - 手势

    mutating func beginDrag(now: Date) {
        anchor = position
        target = nil
        velocity = 0
        lastSampleTime = now
        lastSamplePosition = position
    }

    /// 拖拽中每一帧。位移已经换算成「往前几页」，**只加在 anchor 上**，中途反向天然成立。
    /// 返回值得给一次触感的新页码：只在真的跨过一格时报（§9.4「不按每帧触发」）。
    @discardableResult
    mutating func drag(translationInPages: Double, now: Date) -> Int? {
        let previous = focusedPage
        position = Self.rubberBand(anchor + translationInPages, in: bounds)
        sampleVelocity(now: now)
        return focusedPage != previous ? focusedPage : nil
    }

    /// 屏幕坐标 → 页。符号在这里定：卡片堆把翻走的那几张摆在左边，所以手指往左拖是往前翻。
    /// 这一行同时管着旧实现的两处错 —— 它既把基准挂在会跳的 `focused` 上，
    /// 又把往左的负位移直接加在页码上，于是卡片是**逆着手指**走的。
    static func pages(fromPixelsX translation: CGFloat, width: CGFloat) -> Double {
        -Double(translation) / Double(max(width, 1)) * sensitivity
    }

    /// 松手。目标页由「预测终点」和「实际位移」共同定出来，且一定落在整格上 ——
    /// 停在半张卡片是 §8.1 明确不要的东西。越界的那部分由 clamp 收回来。
    @discardableResult
    mutating func release(predictedExtraPages: Double) -> Double {
        land(on: (position + predictedExtraPages).rounded().clamped(to: bounds))
    }

    /// 手势被系统抢走（来电、通知中心、手指滑出边界）：按当前位置自然回弹。
    mutating func cancel() {
        land(on: position.rounded().clamped(to: bounds))
    }

    /// 点指示点或代码切页。
    mutating func select(page: Int) {
        land(on: bounds.clamped(Double(page)))
    }

    /// 把位置交给目标格。减少动态效果时直接钉在那儿，弹簧一步都不跑（§9.4）。
    @discardableResult
    private mutating func land(on goal: Double) -> Double {
        target = goal
        lastSampleTime = nil
        if !animatesSettle {
            position = goal
            velocity = 0
            target = nil
        }
        return goal
    }

    // MARK: - 推进

    /// 把位置往目标推进一步。`dt` 会被切片，所以后台回来那一坨时间不会把弹簧炸开。
    mutating func advance(dt: Double) {
        guard animatesSettle, let goal = target else { return }
        var remaining = min(max(dt, 0), 1.0 / 30.0)
        let omega = Self.responseFrequency
        let zeta = Self.dampingRatio
        while remaining > 0 {
            let step = min(1.0 / 120.0, remaining)
            let acceleration = -omega * omega * (position - goal) - 2 * zeta * omega * velocity
            velocity += acceleration * step
            position += velocity * step
            // 落在两端时不许回弹过头：那一下表现为卡片从屏幕外侧再挤回来（§8.1「不能越界」）。
            if (goal == bounds.lowerBound || goal == bounds.upperBound),
               !bounds.contains(position) {
                position = bounds.clamped(position)
                velocity = 0
            }
            remaining -= step
        }
        if abs(position - goal) < 0.0015, abs(velocity) < 0.02 {
            position = goal
            velocity = 0
            target = nil
        }
    }

    /// 数据换了一批之后重算位置（§8.1 最后一句：选中由身份决定，不是由下标决定）。
    /// 原来那张卡还在就回到它那一格；不在了就落在同一位置还能落的那一格。
    /// 首帧没有身份记录 —— 认屏幕上那一张，而不是硬编第 0 张。
    static func reindex<ID: Hashable>(focused: ID?, after ids: [ID],
                                      position: Double) -> (position: Double, focused: ID?) {
        guard !ids.isEmpty else { return (0, nil) }
        if let focused, let index = ids.firstIndex(of: focused) {
            return (Double(index), focused)
        }
        let page = Int(min(max(position.rounded(), 0), Double(ids.count - 1)))
        return (Double(page), ids[page])
    }

    /// 换数据时把新条数交给轨道，位置不能被旧页码留在界外。
    mutating func resize(pageCount newPageCount: Int) {
        pageCount = max(newPageCount, 0)
        position = bounds.clamped(position)
        anchor = bounds.clamped(anchor)
        if let goal = target, !bounds.contains(goal) {
            target = bounds.clamped(goal)
        }
    }

    /// 把轨道挪到「原来那张卡现在排第几」。给动画就是滑过去，不给就是钉在那儿。
    /// 手指还压在卡片上时不接 —— 那段时间位置由手指说了算。
    mutating func reanchor(to newPosition: Double, animated: Bool, whileDragging: Bool) {
        guard !whileDragging else { return }
        let goal = bounds.clamped(newPosition)
        guard animated, animatesSettle, goal != position else {
            position = goal
            anchor = goal
            velocity = 0
            return
        }
        target = goal
    }

    // MARK: - 算术

    /// 橡皮筋：界内 1:1 跟手，界外按阻尼压缩，最多只露出 `overscrollHeap` 那么多。
    static func rubberBand(_ raw: Double, in bounds: ClosedRange<Double>) -> Double {
        if bounds.contains(raw) { return raw }
        let outside = raw < bounds.lowerBound ? bounds.lowerBound - raw : raw - bounds.upperBound
        let damped = outside * overscrollConstant / (outside * overscrollConstant / overscrollHeap + 1)
        return raw < bounds.lowerBound ? bounds.lowerBound - damped : bounds.upperBound + damped
    }

    private mutating func sampleVelocity(now: Date) {
        defer {
            lastSampleTime = now
            lastSamplePosition = position
        }
        guard let previous = lastSampleTime else { return }
        let dt = now.timeIntervalSince(previous)
        guard dt > 0.004, dt < 0.25 else { return }
        // 取这一帧的瞬时速度，不是「整段拖拽的平均速度」：慢拖到最后停住再松手，
        // 平均速度会假装手指还在飞，卡片因此多翻一页。
        let instant = (position - lastSamplePosition) / dt
        // 平滑一下：单帧抖动不该把速度打成尖峰。速度为 0 只可能是这轮手势刚起头，
        // 那时要照收第一个采样，不能先乘以 0.65 打个折。
        velocity = velocity == 0 ? instant : velocity * 0.35 + instant * 0.65
    }

    private static func bounds(for pageCount: Int) -> ClosedRange<Double> {
        0...Double(max(pageCount - 1, 0))
    }
}

private extension ClosedRange<Double> {
    /// `Swift.min/max` 点名：ClosedRange 自己带一个条件一致的 `clamp`，
    /// 光写 `min` 会被解析成它，编译器已经在警告这一层将来会变。
    func clamped(_ value: Double) -> Double { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

private extension Double {
    func clamped(to bounds: ClosedRange<Double>) -> Double {
        min(max(self, bounds.lowerBound), bounds.upperBound)
    }
}
