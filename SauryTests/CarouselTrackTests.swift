import XCTest
@testable import Saury

/// 任务书 §8.1 对「即将扣费」卡片轮播提了八条，§9.2 又要求动画进行到一半能被手指接管。
/// 这些都不是看一眼截图能判的东西：位置是不是从固定的基准算出来的、松手会不会停在半格、
/// 甩狠了会不会越界、换数据之后选中的还是不是原来那张 —— 只能把算术抽出来逐帧问。
///
/// 测试里的位移一律用「往前翻了几页」表示（往前为正），和轨道的约定一致。
final class CarouselTrackTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let frame = 1.0 / 120.0

    // MARK: - 基准（§8.1 前两句）

    /// 旧写法是 `position = Double(focused) + travel`：位置一过 .5，focused 就跳一格，
    /// 基准跟着跳，卡片在指下瞬间平移。这条用例钉的就是那一次跳变。
    func testTheDragIsMeasuredFromWhereTheFingerStarted() {
        var track = CarouselTrack(pageCount: 5, position: 1)
        _ = track.drag(translationInPages: 0.55, now: epoch.addingTimeInterval(frame))

        XCTAssertEqual(track.position, 1.55, accuracy: 0.0001)
        XCTAssertEqual(track.focusedPage, 2, "1.55 已经过半格，看着的是第 2 张")

        _ = track.drag(translationInPages: 0.6, now: epoch.addingTimeInterval(frame * 2))

        XCTAssertEqual(track.position, 1.6, accuracy: 0.0001,
                       "基准还该是起手的第 1 页，不能改成刚跨上去的第 2 页重算")
    }

    /// 同一段位移，中途有没有跨过格都不该改变结果。
    func testTheSameTranslationLandsInTheSamePlaceAcrossPageBoundaries() {
        var oneShot = CarouselTrack(pageCount: 5, position: 0)
        var stepped = CarouselTrack(pageCount: 5, position: 0)

        _ = oneShot.drag(translationInPages: 1.7, now: epoch.addingTimeInterval(frame))
        _ = stepped.drag(translationInPages: 0.9, now: epoch.addingTimeInterval(frame))
        _ = stepped.drag(translationInPages: 1.7, now: epoch.addingTimeInterval(frame * 2))

        XCTAssertEqual(oneShot.position, stepped.position, accuracy: 0.0001)
    }

    /// §8.1「支持中途反向」：往回拖就照着手回去，既不跳也不弹。
    func testReversingMidGestureFollowsTheFingerBack() {
        var track = CarouselTrack(pageCount: 5, position: 2)

        _ = track.drag(translationInPages: 1.2, now: epoch.addingTimeInterval(frame))
        XCTAssertEqual(track.position, 3.2, accuracy: 0.0001)

        _ = track.drag(translationInPages: 0.3, now: epoch.addingTimeInterval(frame * 2))
        XCTAssertEqual(track.position, 2.3, accuracy: 0.0001, "手指回到哪儿就该停在哪儿")
    }

    // MARK: - 边界（§8.1 橡皮筋、不越界）

    /// 界内必须 1:1 跟手，橡皮筋只管界外。
    func testInsideTheBoundsTheRailFollowsTheFingerExactly() {
        var track = CarouselTrack(pageCount: 5, position: 2)

        _ = track.drag(translationInPages: 0.7, now: epoch.addingTimeInterval(frame))

        XCTAssertEqual(track.position, 2.7, accuracy: 0.0001)
    }

    /// §8.1「两端有轻微橡皮筋」：露出的缝隙有上限，而且越拖越沉、不是顶死。
    func testOverscrollOutsideTheBoundsIsDampedAndBounded() {
        let bounds = CarouselTrack(pageCount: 5, position: 0).bounds
        let aBit = CarouselTrack.rubberBand(-0.3, in: bounds)
        let aLot = CarouselTrack.rubberBand(-3, in: bounds)
        let forever = CarouselTrack.rubberBand(-300, in: bounds)

        XCTAssertLessThan(abs(aBit), 0.3, "越界之后不该还 1:1 跟着手指走")
        XCTAssertGreaterThan(abs(aLot), abs(aBit), "多拖还是要再多露一点")
        XCTAssertLessThanOrEqual(abs(forever), CarouselTrack.overscrollHeap + 0.001,
                                 "橡皮筋的可见余量必须有上限")
        XCTAssertEqual(CarouselTrack.rubberBand(1.4, in: bounds), 1.4, "界内一个像素都不许少吃")
    }

    /// §8.1「快速甩动不能越界」：狠甩的预测行程再远，落点也只能是最外面那一张。
    func testAFlingCannotJumpPastEitherEnd() {
        var tail = CarouselTrack(pageCount: 4, position: 0)
        _ = tail.drag(translationInPages: 2.6, now: epoch.addingTimeInterval(frame))
        XCTAssertEqual(tail.release(predictedExtraPages: 40), 3, "往前狠甩只能到最后一张")

        var head = CarouselTrack(pageCount: 4, position: 3)
        _ = head.drag(translationInPages: -2.6, now: epoch.addingTimeInterval(frame))
        XCTAssertEqual(head.release(predictedExtraPages: -40), 0, "往回狠甩只能到第一张")
    }

    // MARK: - 落格（§8.1 不停在半张卡片）

    /// 定位跑完一定落在整格上，并且把时间轴关掉。
    func testSettlingAlwaysEndsOnAWholePage() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        _ = track.drag(translationInPages: 1.31, now: epoch.addingTimeInterval(frame))
        let goal = track.release(predictedExtraPages: 0.1)

        XCTAssertEqual(goal, 1)
        let frames = settleFrames(&track)
        XCTAssertEqual(frames.last ?? -1, 1, accuracy: 0.00001, "最后一帧必须贴在整格上")
        XCTAssertFalse(track.isSettling, "落定之后不该继续占着每一帧重绘（§9.5）")
        XCTAssertFalse(frames.isEmpty)
    }

    /// 慢拖到不足半格就停住、松手：回到原来那张，不多翻一页。
    func testASlowDragShortOfHalfAPageGoesBack() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        _ = track.drag(translationInPages: 0.3, now: epoch.addingTimeInterval(frame))

        XCTAssertEqual(track.release(predictedExtraPages: 0), 0)
    }

    /// 拖过半格、手指已经停住：按实际位移翻页，不再依赖甩动预测。
    func testADragPastHalfAPageFlipsEvenWithoutAFlingShot() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        var clock = epoch
        for step in [0.4, 0.9, 0.92, 0.92] {
            clock = clock.addingTimeInterval(frame)
            _ = track.drag(translationInPages: step, now: clock)
        }

        XCTAssertEqual(track.release(predictedExtraPages: 0), 1,
                       "已经拖到 0.92 页，松手就该落在第 1 张")
    }

    /// §8.1「取消手势后按当前位置自然回弹」：被系统抢走时从当前可见位置往回落。
    func testCancelReturnsToTheNearestPageFromWhereItIs() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        _ = track.drag(translationInPages: 0.8, now: epoch.addingTimeInterval(frame))

        track.cancel()

        XCTAssertEqual(track.target, 1)
    }

    // MARK: - 可中断（§9.2）

    /// 定位跑到一半手指再搭上去，必须从**屏幕上那一个位置**接管。
    /// `withAnimation` 做不到这件事：模型里的值早就到终点了。
    func testASettleInterruptedAtHalfwayIsTakenOverFromTheVisiblePosition() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        _ = track.drag(translationInPages: 0.55, now: epoch)
        XCTAssertEqual(track.release(predictedExtraPages: 0), 1, "过半格，松手该往前落")

        let mid = run(&track, seconds: 0.05)
        XCTAssertGreaterThan(mid, 0.55, "这时候应该已经离开拖拽终点往前走了")
        XCTAssertLessThan(mid, 1, "但还没到位")

        track.beginDrag(now: epoch.addingTimeInterval(1))
        XCTAssertEqual(track.anchor, mid, accuracy: 0.00001,
                       "新手势的基准必须等于被打断时的那一个可见位置")
    }

    /// 打断之后往回拖，能一路回到出发的那一张 —— 半路的定位动画不是单行道。
    func testPullingBackAfterAnInterruptedSettleReturnsToTheOrigin() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        _ = track.drag(translationInPages: 0.55, now: epoch)
        track.release(predictedExtraPages: 0)
        let mid = run(&track, seconds: 0.05)

        track.beginDrag(now: epoch.addingTimeInterval(1))
        _ = track.drag(translationInPages: -mid, now: epoch.addingTimeInterval(1 + frame))
        let goal = track.release(predictedExtraPages: 0)

        XCTAssertEqual(track.position, 0, accuracy: 0.0001, "手指拖回第 0 张就该在那儿")
        XCTAssertEqual(goal, 0)
    }

    /// 连续反复左右狠甩：每一轮都必须整格落定，不许越界、不许停在半格、不许发散。
    func testRepeatedFastReversalsStayOnTheirPages() {
        var track = CarouselTrack(pageCount: 4, position: 0)
        var clock = epoch
        var landings = [Double]()

        for _ in 0..<12 {
            _ = track.drag(translationInPages: 3, now: clock)
            track.release(predictedExtraPages: 3)
            clock = runUntilSettled(&track, from: clock)
            landings.append(track.position)

            _ = track.drag(translationInPages: -3, now: clock)
            track.release(predictedExtraPages: -3)
            clock = runUntilSettled(&track, from: clock)
            landings.append(track.position)
        }

        XCTAssertTrue(landings.allSatisfy { $0 >= 0 && $0 <= 3 }, "一轮都没甩出轨道")
        XCTAssertTrue(landings.allSatisfy { abs($0 - $0.rounded()) < 0.00001 }, "每一轮都落在整格")
        XCTAssertEqual(landings.last ?? -1, 0, accuracy: 0.00001)
    }

    /// 两端落定时不许从轨道外面荡回来 —— 那是「越界」最难看的一种。
    func testSettlingOntoAnEndDoesNotComeBackFromOffTheRail() {
        var track = CarouselTrack(pageCount: 3, position: 0)
        _ = track.drag(translationInPages: -1.5, now: epoch)
        XCTAssertLessThan(track.position, 0, "先把它拖到第 0 张外面")

        track.release(predictedExtraPages: -1.5)
        let frames = settleFrames(&track)

        XCTAssertEqual(frames.filter { $0 > 0.0001 }.count, 0, "落向第 0 张的过程里不该越过它")
        XCTAssertEqual(track.position, 0, accuracy: 0.00001)
    }

    /// §9.2「应用长期未打开后重新进入」：一坨巨大的 dt 不能把积分器炸开。
    func testOneHugeFrameGapDoesNotBlowUpTheSpring() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        _ = track.drag(translationInPages: 1, now: epoch)
        track.release(predictedExtraPages: 0)

        track.advance(dt: 40)

        XCTAssertTrue(track.position.isFinite)
        XCTAssertEqual(track.position, 1, accuracy: 0.001)
    }

    // MARK: - 速度与触感（§9.4）

    /// 拖到一半停住再松手：瞬时速度要跟着掉下去，否则「慢慢拖着看」也会被当成在甩。
    func testVelocityDecaysWhenTheFingerStopsMoving() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        var clock = epoch
        for step in stride(from: 0.1, through: 0.6, by: 0.1) {
            clock = clock.addingTimeInterval(frame)
            _ = track.drag(translationInPages: step, now: clock)
        }
        for _ in 0..<6 {
            clock = clock.addingTimeInterval(frame)
            _ = track.drag(translationInPages: 0.6, now: clock)
        }

        XCTAssertLessThan(abs(track.velocity), 0.2, "手指停住时速度要跟着停")

        track.release(predictedExtraPages: 0)
        let frames = settleFrames(&track)
        XCTAssertLessThanOrEqual(frames.max() ?? 0, 1.02, "落向第 1 张时不许荡到 1.02 页之外")
    }

    /// §9.4「拖拽卡片：只在跨越有效分页阈值时触发，不按每帧触发」。
    func testTheHapticIsOfferedOnlyWhenAPageIsCrossed() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        var clock = epoch
        var crossings = 0

        for step in stride(from: 0.05, through: 1.0, by: 0.05) {
            clock = clock.addingTimeInterval(frame)
            if track.drag(translationInPages: step, now: clock) != nil { crossings += 1 }
        }

        XCTAssertEqual(crossings, 1, "从第 0 张拖到第 1 张只该报一次")
    }

    /// §9.4 减少动态效果：位移取消、直接落格，但落点判断一条都不能少。
    func testReduceMotionLandsImmediatelyWithoutGivingUpTheDecision() {
        var track = CarouselTrack(pageCount: 5, position: 0)
        track.animatesSettle = false
        _ = track.drag(translationInPages: 0.8, now: epoch)

        XCTAssertEqual(track.release(predictedExtraPages: 0), 1)
        XCTAssertEqual(track.position, 1, accuracy: 0.00001)
        XCTAssertFalse(track.isSettling, "不许留一段看不见、却一直在跑的时间轴")
    }

    // MARK: - 数据变化（§8.1 最后一句）

    /// 「选中由身份决定，不是由下标决定」：删掉前面那张，看的还是原来那张。
    func testRemovingAnEarlierCardKeepsTheSameCardFocused() {
        let result = CarouselTrack.reindex(focused: "b", after: ["b", "c"], position: 1)

        XCTAssertEqual(result.position, 0, "「b」还在，只是它现在排第 0")
        XCTAssertEqual(result.focused, "b")
    }

    /// 当前那张真没了：落在同一位置还能落的那一张，且必须报出一个真实存在的 ID。
    func testWhenTheFocusedCardIsGoneTheRailSettlesOnARealCard() {
        let result = CarouselTrack.reindex(focused: "b", after: ["a", "c"], position: 1)

        XCTAssertEqual(result.focused, "c")
        XCTAssertEqual(result.position, 1)
    }

    /// 首帧还没有身份记录：认屏幕上那一张，而不是硬编第 0 张。
    func testTheFirstAlignmentAdoptsTheCardAlreadyOnScreen() {
        let result = CarouselTrack.reindex(focused: nil, after: ["a", "b", "c"], position: 1)

        XCTAssertEqual(result.focused, "b")
        XCTAssertEqual(result.position, 1)
    }

    /// 手指还压在卡片上时不换位置：否则拖到一半数据一变，卡片就从指下被抽走。
    func testReanchorYieldsToTheFingerWhileItIsStillDown() {
        var track = CarouselTrack(pageCount: 3, position: 0)
        _ = track.drag(translationInPages: 0.8, now: epoch)

        track.reanchor(to: 2, animated: true, whileDragging: true)

        XCTAssertEqual(track.position, 0.8, accuracy: 0.0001)
        XCTAssertNil(track.target, "这一段位移得等手指离开")
    }

    /// 数据变短：旧页码不能把轨道留在界外。
    func testResizingToFewerCardsPullsThePositionBackInside() {
        var track = CarouselTrack(pageCount: 6, position: 5)

        track.resize(pageCount: 2)

        XCTAssertEqual(track.position, 1)
        XCTAssertEqual(track.bounds, 0...1)
    }

    /// 一条都不剩：轨道回到起点、没有选中，指示点那一层自己就该消失。
    func testEmptyingTheCarouselPutsTheRailBackAtTheStart() {
        let result = CarouselTrack.reindex(focused: "a", after: [], position: 0)
        var track = CarouselTrack(pageCount: 1, position: 0)
        track.resize(pageCount: 0)

        XCTAssertNil(result.focused)
        XCTAssertEqual(result.position, 0)
        XCTAssertEqual(track.focusedPage, 0, "空列表时页码也不能报出 -1")
    }

    /// 正在定位的时候数据变了：目标页也得跟着收进新边界，不然会往一个不存在的位置弹。
    func testResizingWhileSettlingRetargetsInsideTheNewBounds() {
        var track = CarouselTrack(pageCount: 6, position: 0)
        _ = track.drag(translationInPages: 5, now: epoch)
        track.release(predictedExtraPages: 0)
        XCTAssertEqual(track.target, 5)

        track.resize(pageCount: 2)

        XCTAssertEqual(track.target, 1)
    }

    // MARK: - 辅助

    /// 跑满一秒，返回每一帧的位置。
    private func settleFrames(_ track: inout CarouselTrack) -> [Double] {
        var frames = [Double]()
        for _ in 0..<120 {
            track.advance(dt: frame)
            frames.append(track.position)
        }
        return frames
    }

    private func run(_ track: inout CarouselTrack, seconds: Double) -> Double {
        var clock = 0.0
        while clock < seconds {
            track.advance(dt: frame)
            clock += frame
        }
        return track.position
    }

    /// 定位到落定为止，返回走了多少秒之后的时钟。
    private func runUntilSettled(_ track: inout CarouselTrack, from clock: Date) -> Date {
        var frames = 0
        while track.isSettling, frames < 240 {
            track.advance(dt: frame)
            frames += 1
        }
        return clock.addingTimeInterval(Double(frames) * frame)
    }
}
