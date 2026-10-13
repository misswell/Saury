import XCTest
@testable import Saury

/// 任务书 §6.3：「弹窗关闭动画未结束时可以连续操作下一个入口」。
///
/// 这一层的毛病以前是肉眼可见的：同一层挂着两张 sheet，第二张要么压根弹不出来，
/// 要么正好撞上第一张的退场动画 —— 用户点了、屏幕上什么都没发生、也不报错。
/// SwiftUI 的 `.sheet` 退场是异步的，`route` 变 nil 那一帧动画还在播，
/// 期间任何一次呈现请求都会被系统整段丢掉。`SheetRouter` 唯一的职责就是
/// 把这段时间等出来，所以它的测试也只需要对着「状态怎么变」来问。
@MainActor
final class SheetRouterTests: XCTestCase {
    private let id = UUID()
    private var detail: SheetRoute { .detail(id) }
    private var edit: SheetRoute { .edit(id) }

    /// 空的这一层：present 应该立刻上屏，不排队。
    func testPresentOnAnEmptyLayerShowsItRightAway() {
        let router = SheetRouter()
        XCTAssertNil(router.route)

        router.present(detail)

        XCTAssertEqual(router.route, detail)
        XCTAssertFalse(router.hasQueuedRoute)
    }

    /// 已开着另一张：先把这一层退干净，再上那一张。
    /// 关键是不能直接改写 `route`（同帧换内容 = 详情还没收起就变编辑，两套动画打架），
    /// 也不能把它丢了。
    func testPresentWhileOneIsOpenRetiresTheCurrentLayerFirst() {
        let router = SheetRouter()
        router.present(detail)

        router.present(edit)

        XCTAssertNil(router.route, "要先让详情页退场")
        XCTAssertTrue(router.hasQueuedRoute, "但下一个入口不能就这么没了")
    }

    /// 退场结束后补上排着的那一层。
    func testQueuedLayerAppearsAsSoonAsTheDismissalFinishes() {
        let router = SheetRouter()
        router.present(detail)
        router.present(edit)

        router.noteClosed()

        XCTAssertEqual(router.route, edit)
        XCTAssertFalse(router.hasQueuedRoute)
    }

    /// 退场动画还在播的那一段时间里点下一个入口：这一脚必须排队。
    /// 这就是「点了没反应」的成因，也是这段逻辑存在的全部理由。
    func testPresentDuringTheClosingAnimationWaitsInsteadOfBeingSwallowed() {
        let router = SheetRouter()
        router.present(detail)
        router.close()          // 用户下拉关掉：route 已是 nil，动画还没跑完
        XCTAssertNil(router.route)

        router.present(edit)

        XCTAssertNil(router.route, "还在退场，这时候硬塞进去系统会整段丢掉")
        XCTAssertTrue(router.hasQueuedRoute)

        router.noteClosed()
        XCTAssertEqual(router.route, edit)
    }

    /// 退场期间连点三行：落在最后那一次上。
    /// 用户的手是连续的，中间那一两下只是改主意，不是三个愿望。
    func testTheLastTapWinsWhileALayerIsQueued() {
        let router = SheetRouter()
        router.present(.detail(UUID()))
        let second = SheetRoute.detail(id)
        let third = SheetRoute.add(prefill: AddPrefill(name: "净云"))

        router.present(second)
        router.present(third)
        router.noteClosed()

        XCTAssertEqual(router.route, third)
        XCTAssertFalse(router.hasQueuedRoute)
    }

    /// 正弹着这一张时又点同一个入口：不该把它推倒重来。
    /// 双跳的表现就是页面闪一下又回到原样，白掉一次动画还可能丢滚动位置。
    func testTappingTheRouteThatIsAlreadyOpenChangesNothing() {
        let router = SheetRouter()
        router.present(detail)

        router.present(detail)

        XCTAssertEqual(router.route, detail)
        XCTAssertFalse(router.hasQueuedRoute)
    }

    /// 但「关掉了、又想再看同一条」必须还能弹：这时候这一层是空的。
    func testTheSameRoutePresentsAgainAfterItWasClosed() {
        let router = SheetRouter()
        router.present(detail)
        router.close()
        router.noteClosed()

        router.present(detail)

        XCTAssertEqual(router.route, detail)
    }

    /// 排着的时候用户又点了当前那张：排队的那一份要被取消吗？
    /// 不会 —— 当前那张已经准备退场了，这里保持排队的还是它，退完再上回来。
    func testReTappingTheOriginalRouteWhileClosingBringsItBack() {
        let router = SheetRouter()
        router.present(detail)
        router.present(edit)
        router.present(detail)   // 又想回到详情：详情页退干净之后重新弹它

        router.noteClosed()

        XCTAssertEqual(router.route, detail)
    }

    /// `noteClosed` 是 `.sheet` 的 `onDismiss`：没有排队时它只做一件事 ——
    /// 把「正在退场」这个状态解掉，让下一次 present 走立刻上屏那条路。
    func testNoteClosedWithoutAQueueLeavesTheLayerEmptyButReady() {
        let router = SheetRouter()
        router.present(detail)
        router.close()

        router.noteClosed()

        XCTAssertNil(router.route)
        XCTAssertFalse(router.hasQueuedRoute)

        router.present(edit)
        XCTAssertEqual(router.route, edit, "解不开的话，之后每一次点击都只会排队、永远不会弹出来")
    }

    // MARK: - 路由自己那三件事

    /// 底部那颗「+」只有在表单挂着时才转成 ×：详情和筛选挂着的时候它还得是「新增」。
    func testOnlyTheFormRoutesTurnThePlusIntoAClose() {
        XCTAssertTrue(SheetRoute.add(prefill: AddPrefill(name: "Netflix")).isFormSheet)
        XCTAssertTrue(SheetRoute.edit(id).isFormSheet)
        XCTAssertFalse(SheetRoute.detail(id).isFormSheet)
        XCTAssertFalse(SheetRoute.filter.isFormSheet)
        XCTAssertFalse(SheetRoute.reminderPrompt.isFormSheet)
    }

    /// `.sheet(item:)` 靠 `id` 判断是不是同一张：
    /// 同一个对象「详情」和「编辑」必须是两个不同的 id，否则换内容不生效；
    /// 同一个入口反复点必须是同一个 id，否则每次都被当成新的一层。
    func testIdentifiersTellApartKindsAndTargets() {
        XCTAssertNotEqual(SheetRoute.detail(id).id, SheetRoute.edit(id).id)
        XCTAssertNotEqual(SheetRoute.add(prefill: AddPrefill(name: "Netflix")).id,
                          SheetRoute.add(prefill: AddPrefill(name: "Spotify")).id)
        XCTAssertNotEqual(SheetRoute.detail(UUID()).id, SheetRoute.detail(UUID()).id)
        XCTAssertEqual(SheetRoute.detail(id).id, SheetRoute.detail(id).id)
        XCTAssertEqual(SheetRoute.filter.id, SheetRoute.filter.id)
    }

    /// 内容相等的两条路由就是同一条：去重靠这个。
    func testEqualRoutesCompareEqual() {
        let same = AddPrefill(name: " 净 ")
        XCTAssertEqual(SheetRoute.add(prefill: same), SheetRoute.add(prefill: same))
        XCTAssertNotEqual(SheetRoute.add(prefill: .empty), SheetRoute.filter)
    }

    /// 同一个入口反复点拿到的是同一个身份（`AddPrefill.empty` 是共享常量），
    /// 所以连点两下「+」不会被路由当成两张不同的 sheet。
    func testTheSharedPrefillKeepsOneIdentityAcrossTaps() {
        XCTAssertEqual(SheetRoute.add(prefill: .empty).id, SheetRoute.add(prefill: .empty).id)

        let router = SheetRouter()
        router.present(.add(prefill: .empty))
        router.present(.add(prefill: .empty))
        XCTAssertFalse(router.hasQueuedRoute, "第二下该被当成「已经开着这一张」")
    }

    /// 两条内容一模一样的外部草稿必须各弹一次：`token` 就是干这个的。
    /// 去掉 token 的话，用户连着分享两张同名图片，第二张会直接消失（§10.5「不丢失」）。
    func testTwoIdenticalDraftsStillGetTheirOwnSheet() {
        let first = SheetRoute.add(prefill: AddPrefill(name: "同一条"))
        let second = SheetRoute.add(prefill: AddPrefill(name: "同一条"))

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first, second)

        let router = SheetRouter()
        router.present(first)
        router.close()
        router.noteClosed()
        router.present(second)
        XCTAssertEqual(router.route, second)
    }
}
