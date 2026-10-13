import XCTest
@testable import Saury

/// 打赏三档的账（任务书 §10.4、§12.1「内购 | 成功、取消、失败、恢复」）。
///
/// 测的是值类型那台状态机 + 套了假 StoreKit 的控制器。真的 `Product` 在
/// XCTest 里造不出来，硬去调 StoreKit 只会测到「沙盒今天心情如何」；
/// 所以这里把「哪种结果该把哪一档改成什么」逐条问清楚，
/// 剩下那一层（`StoreKitTipSeller` 的结果翻译）留给真机验收。
final class TipBoardTests: XCTestCase {
    private var board: TipBoard {
        var b = TipBoard()
        b.load(quotes: TipTier.allCases.map { TipQuote(tier: $0, displayPrice: "US$2.99") })
        return b
    }

    // MARK: - 一档一个产品

    /// 「点某档位必须买对应产品」的前提是三档各自有 ID，且互不共用。
    func testEachTierIsItsOwnProduct() {
        XCTAssertEqual(TipTier.allCases, [.instant, .americano, .coldBrew])
        XCTAssertEqual(Set(TipTier.allCases.map(\.rawValue)).count, 3, "两个档位共用一个产品 ID，点下去买的就不是那一款")
        for tier in TipTier.allCases {
            XCTAssertTrue(tier.rawValue.hasPrefix("com.guofeng.saury.tip."), "\(tier.rawValue) 不在打赏前缀里")
            XCTAssertFalse(tier.title.isEmpty)
            XCTAssertFalse(tier.caption.isEmpty)
        }
        // 老那版把三行价签贴在一个终身买断产品上；这里不能让那个 ID 复活。
        XCTAssertFalse(TipTier.allCases.contains { $0.rawValue.contains("lifetime") })
    }

    // MARK: - 价格只从商店来

    func testPriceComesFromTheQuoteOnly() {
        var b = TipBoard()
        b.load(quotes: [TipQuote(tier: .americano, displayPrice: "US$2.99")])
        XCTAssertEqual(b.quote(of: .americano)?.displayPrice, "US$2.99")

        // 商店换了报价（币种、活动价、地区），页面跟着走，不存在写死的那个 ¥8。
        b.load(quotes: [TipQuote(tier: .americano, displayPrice: "¥18.00")])
        XCTAssertEqual(b.quote(of: .americano)?.displayPrice, "¥18.00")

        // 没取到报价的档位没有任何价格可展示。
        XCTAssertNil(b.quote(of: .instant))
    }

    func testNoProductAtAllSaysSoInsteadOfShowingDeadButtons() {
        var b = TipBoard()
        b.load(quotes: [])
        XCTAssertFalse(b.isSellable)
        XCTAssertEqual(b.tier(inState: .available), [])
    }

    func testPartialCatalogMarksMissingTiersUnavailable() {
        var b = TipBoard()
        b.load(quotes: [TipQuote(tier: .instant, displayPrice: "US$0.99")])
        XCTAssertTrue(b.isSellable)
        XCTAssertEqual(b.status(of: .instant), .available)
        XCTAssertEqual(b.tier(inState: .unavailable), [.americano, .coldBrew])
    }

    func testProductComingBackRevivesItsTier() {
        var b = board
        b.finish(.notForSale(.coldBrew))
        XCTAssertEqual(b.status(of: .coldBrew), .unavailable)
        b.load(quotes: [TipQuote(tier: .coldBrew, displayPrice: "US$4.99")])
        XCTAssertEqual(b.status(of: .coldBrew), .available)
    }

    // MARK: - 五种结果各说各的话

    func testOnlyVerifiedMarksThanks() {
        let results: [TipPurchaseResult] = [
            .cancelled(.instant),
            .pending(.instant),
            .unverified(.instant, reason: "收据签名对不上"),
            .failed(.instant, reason: "网络断了"),
            .notForSale(.instant),
        ]
        for result in results {
            var b = board
            b.begin(.instant)
            b.finish(result)
            XCTAssertNotEqual(b.status(of: .instant), .thanked, "\(result) 被记成了已收到")
        }
        var verified = board
        verified.begin(.instant)
        verified.finish(.verified(.instant))
        XCTAssertEqual(verified.status(of: .instant), .thanked)
    }

    func testCancelGoesBackToBuyableWithoutAnError() {
        var b = board
        b.begin(.instant)
        b.finish(.cancelled(.instant))
        XCTAssertEqual(b.status(of: .instant), .available, "用户自己按的取消不该留下失败的痕迹")
    }

    func testPendingStaysPendingUntilStoreKitConfirms() {
        var b = board
        b.begin(.instant)
        b.finish(.pending(.instant))
        XCTAssertEqual(b.status(of: .instant), .pending)
    }

    func testUnverifiedKeepsTheReasonAndIsNotAFailureSilence() {
        var b = board
        b.begin(.instant)
        b.finish(.unverified(.instant, reason: "签名校验失败"))
        guard case .problem(let reason) = b.status(of: .instant) else {
            return XCTFail("验证没过必须在页面上摊出来，现在状态是 \(b.status(of: .instant))")
        }
        XCTAssertTrue(reason.contains("签名校验失败"), "原因被吞了：\(reason)")
    }

    func testNotForSaleRemovesTheQuote() {
        var b = board
        b.finish(.notForSale(.americano))
        XCTAssertNil(b.quote(of: .americano))
        XCTAssertEqual(b.status(of: .americano), .unavailable)
        // 另外两档不受影响。
        XCTAssertEqual(b.status(of: .instant), .available)
    }

    // MARK: - 连点

    func testRequestInFlightRejectsSecondTap() {
        var b = board
        XCTAssertTrue(b.begin(.instant))
        XCTAssertFalse(b.begin(.instant), "第二下应该被挡掉，不然一次点击变两笔订单")
        XCTAssertEqual(b.status(of: .instant), .buying)
    }

    func testUnsellableTierCannotStartARequest() {
        var b = TipBoard()
        b.load(quotes: [])
        XCTAssertFalse(b.begin(.instant))
    }

    func testFailedAndThankedTiersCanBeTappedAgain() {
        var b = board
        b.finish(.failed(.instant, reason: "上一次没成功"))
        XCTAssertTrue(b.begin(.instant), "上一次没成功，用户当然可以再试")
        b.finish(.verified(.instant))
        XCTAssertTrue(b.begin(.instant), "打赏不是一次买断，谢谢看完还得能再买")
    }

    func testThanksReturnsToBuyable() {
        var b = board
        b.finish(.verified(.instant))
        b.resetAfterThanks(.instant)
        XCTAssertEqual(b.status(of: .instant), .available)
        // 收回「谢谢」只针对处于该状态的档位：正在路上的不能被抹成可买。
        b.begin(.americano)
        b.resetAfterThanks(.americano)
        XCTAssertEqual(b.status(of: .americano), .buying)
    }

    // MARK: - 恢复购买

    func testEntitlementsOnlyMarkTheTiersStoreKitConfirmed() {
        var b = board
        b.applyEntitlements([.coldBrew])
        XCTAssertEqual(b.status(of: .coldBrew), .thanked)
        XCTAssertEqual(b.tier(inState: .available), [.instant, .americano])
    }

    /// 空集就是空集。一次性消耗品本来没有可恢复的内容，
    /// 「没查到」不许写成「都恢复了」。
    func testEmptyEntitlementsChangeNothing() {
        var b = board
        b.applyEntitlements([])
        XCTAssertEqual(b.tier(inState: .available), TipTier.allCases)
        XCTAssertEqual(b.tier(inState: .thanked), [])
    }

    func testEntitlementForAnUnsellableTierIsIgnored() {
        var b = TipBoard()
        b.load(quotes: [TipQuote(tier: .instant, displayPrice: "US$0.99")])
        b.applyEntitlements([.instant, .americano])
        XCTAssertEqual(b.status(of: .instant), .thanked)
        XCTAssertEqual(b.status(of: .americano), .unavailable)
    }

    func testResultCarriesItsOwnTier() {
        for tier in TipTier.allCases {
            XCTAssertEqual(TipPurchaseResult.verified(tier).tier, tier)
            XCTAssertEqual(TipPurchaseResult.failed(tier, reason: "x").tier, tier)
        }
    }
}

@MainActor
final class PurchaseStoreTests: XCTestCase {
    /// 一档的请求必须原样带着这一档进店 —— 「点冰美式买的是速溶」就是这里会坏的事。
    func testBuySendsExactlyThatTierToStoreKit() async {
        let seller = FakeTipSeller()
        seller.setQuotes(TipTier.allCases.map { TipQuote(tier: $0, displayPrice: "US$2.99") })
        seller.setResult(.verified(.americano), for: .americano)
        let store = PurchaseStore(seller: seller)
        await store.load()
        await store.buy(.americano)

        XCTAssertEqual(seller.requests, [.americano])
        XCTAssertEqual(store.status(of: .americano), .thanked)
        XCTAssertEqual(store.status(of: .instant), .available)
    }

    /// 连点两下只发一笔请求：门还开着的时候第二下就该被挡。
    func testDoubleTapIssuesOneRequest() async {
        let seller = FakeTipSeller()
        seller.setQuotes([TipQuote(tier: .instant, displayPrice: "US$0.99")])
        seller.holdNextCall()
        seller.setResult(.verified(.instant), for: .instant)
        let store = PurchaseStore(seller: seller)
        await store.load()

        let first = Task { await store.buy(.instant) }
        await seller.calls(1).wait()
        await store.buy(.instant)          // 第一笔还在路上
        XCTAssertEqual(store.status(of: .instant), .buying)

        seller.release()
        await first.value
        await store.buy(.instant)          // 落账之后可以再来一笔

        XCTAssertEqual(seller.requests.count, 2, "在路上时多发了请求，或落账后连正常的一下也没发出去")
        XCTAssertEqual(store.status(of: .instant), .thanked)
    }

    func testBuyOnUnsellableTierIssuesNoRequest() async {
        let seller = FakeTipSeller()
        let store = PurchaseStore(seller: seller)
        await store.load()
        await store.buy(.instant)

        XCTAssertTrue(seller.requests.isEmpty)
        XCTAssertFalse(store.isSellable)
        XCTAssertEqual(store.status(of: .instant), .unavailable)
    }

    func testCancelledPurchaseLeavesNoProblemState() async {
        let seller = FakeTipSeller()
        seller.setQuotes([TipQuote(tier: .coldBrew, displayPrice: "US$4.99")])
        seller.setResult(.cancelled(.coldBrew), for: .coldBrew)
        let store = PurchaseStore(seller: seller)
        await store.load()
        await store.buy(.coldBrew)

        XCTAssertEqual(store.status(of: .coldBrew), .available)
    }

    func testFailureKeepsItsReasonOnTheStore() async {
        let seller = FakeTipSeller()
        seller.setQuotes([TipQuote(tier: .instant, displayPrice: "US$0.99")])
        seller.setResult(.failed(.instant, reason: "StoreKit 报错"), for: .instant)
        let store = PurchaseStore(seller: seller)
        await store.load()
        await store.buy(.instant)

        guard case .problem(let reason) = store.status(of: .instant) else {
            return XCTFail("失败必须摊出来")
        }
        XCTAssertEqual(reason, "StoreKit 报错")
    }

    /// 打赏是消耗品，恢复通常什么都查不到 —— 这句话必须如实说。
    func testRestoreWithNoEntitlementsSaysThereIsNothingToRestore() async {
        let seller = FakeTipSeller()
        seller.setQuotes(TipTier.allCases.map { TipQuote(tier: $0, displayPrice: "US$2.99") })
        let store = PurchaseStore(seller: seller)
        await store.load()
        await store.restore()

        XCTAssertEqual(store.board.tier(inState: .available), TipTier.allCases)
        let notice = store.restoreNotice ?? ""
        XCTAssertTrue(notice.contains("没有查到"), notice)
        XCTAssertTrue(notice.contains("一次性"), notice)
    }

    func testRestoreMarksWhatStoreKitConfirms() async {
        let seller = FakeTipSeller()
        seller.setQuotes(TipTier.allCases.map { TipQuote(tier: $0, displayPrice: "US$2.99") })
        seller.entitlements = [.coldBrew]
        let store = PurchaseStore(seller: seller)
        await store.load()
        await store.restore()

        XCTAssertEqual(store.status(of: .coldBrew), .thanked)
        XCTAssertTrue((store.restoreNotice ?? "").contains("1 档"))
    }

    func testClearThanksMakesTheTierBuyableAgain() async {
        let seller = FakeTipSeller()
        seller.setQuotes([TipQuote(tier: .americano, displayPrice: "US$2.99")])
        seller.setResult(.verified(.americano), for: .americano)
        let store = PurchaseStore(seller: seller)
        await store.load()
        await store.buy(.americano)
        XCTAssertEqual(store.status(of: .americano), .thanked)

        store.clearThanks(.americano)
        XCTAssertEqual(store.status(of: .americano), .available)
    }

    func testPriceDisplayedIsTheOneTheStoreGave() async {
        let seller = FakeTipSeller()
        seller.setQuotes([TipQuote(tier: .instant, displayPrice: "CA$1.49")])
        let store = PurchaseStore(seller: seller)
        await store.load()

        XCTAssertEqual(store.quote(of: .instant)?.displayPrice, "CA$1.49")
        XCTAssertNil(store.quote(of: .americano))
    }
}

// MARK: - 假件与素材

/// 只到「报价、下单一笔、查已购」为止的假商店。
/// 命中记账 + 可卡门，让「第二下有没有多发出去」这类顺序问题在测试里演得出来。
private final class FakeTipSeller: TipSelling, @unchecked Sendable {
    private let lock = NSLock()
    private var _quotes: [TipQuote] = []
    private var _results: [TipTier: TipPurchaseResult] = [:]
    private var _requests: [TipTier] = []
    private var _hold: Gate?
    private let _counter = CallCounter()
    private var _entitlements: Set<TipTier> = []

    var requests: [TipTier] { lock.lock(); defer { lock.unlock() }; return _requests }

    var entitlements: Set<TipTier> {
        get { lock.lock(); defer { lock.unlock() }; return _entitlements }
        set { lock.lock(); _entitlements = newValue; lock.unlock() }
    }

    func setQuotes(_ quotes: [TipQuote]) {
        lock.lock(); _quotes = quotes; lock.unlock()
    }

    func setResult(_ result: TipPurchaseResult, for tier: TipTier) {
        lock.lock(); _results[tier] = result; lock.unlock()
    }

    /// 下一笔请求卡在店里，等 `release()`。
    func holdNextCall() {
        lock.lock(); _hold = Gate(); lock.unlock()
    }

    func release() {
        lock.lock(); let gate = _hold; lock.unlock()
        gate?.open()
    }

    /// 第 n 笔请求进店这件事本身可以被 await —— 不用固定 sleep 猜时间。
    func calls(_ n: Int) -> CallWaiter { CallWaiter(counter: _counter, need: n) }

    func quotes() async -> [TipQuote] {
        lock.lock(); defer { lock.unlock() }; return _quotes
    }

    func buy(_ tier: TipTier) async -> TipPurchaseResult {
        let plan = take(tier)
        _counter.bump()
        if let gate = plan.gate { await gate.wait() }
        return plan.result ?? .failed(tier, reason: "假件没配这一档的结果")
    }

    func purchasedTiers() async -> Set<TipTier> { entitlements }

    private struct Plan { let result: TipPurchaseResult?; let gate: Gate? }

    private func take(_ tier: TipTier) -> Plan {
        lock.lock(); defer { lock.unlock() }
        _requests.append(tier)
        // 门是开一次的：open 之后所有 wait 立刻通过，后面的正常请求不会被拦死。
        let gate = _hold
        return Plan(result: _results[tier], gate: gate)
    }
}

/// 一次性的门。用锁而不是 actor：actor 的方法里没法把 continuation 存进自己的属性。
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        lock.lock()
        if opened { lock.unlock(); return }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }

    func open() {
        lock.lock()
        guard !opened else { lock.unlock(); return }
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var waiters: [(need: Int, cont: CheckedContinuation<Void, Never>)] = []

    func bump() {
        lock.lock()
        value += 1
        let current = value
        let ready = waiters.filter { current >= $0.need }
        waiters.removeAll { current >= $0.need }
        lock.unlock()
        ready.forEach { $0.cont.resume() }
    }

    func reached(_ need: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return value >= need
    }

    func enqueue(_ need: Int, _ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        if value >= need { lock.unlock(); cont.resume() }
        else { waiters.append((need, cont)); lock.unlock() }
    }
}

private struct CallWaiter {
    let counter: CallCounter
    let need: Int

    func wait() async {
        if counter.reached(need) { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in counter.enqueue(need, c) }
    }
}
