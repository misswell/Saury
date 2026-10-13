import XCTest
import UIKit
import SwiftData
@testable import Saury

/// 保留规则本身（任务书 §10.6「清理时间以删除时间为准」）。
///
/// 只管一件事：给定「删除时间」和「现在」，一条订阅算不算满了 30 天。
/// 判错的代价不对称 —— 多留几天只是晚点清理，早删一天就是不可恢复地丢数据，
/// 所以每一支都有用例压着。
final class TrashPolicyTests: XCTestCase {
    /// 固定时区的公历：这一组的结论不能跟着设备时区或夏令时变。
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// 这一组全部显式传 `utc`：那些「9 月 1 日 23 点」的构造要的就是日历天的形状，
    /// 跟着设备时区走会把小时挪位、结论跟着变。
    func testRetentionIsThirtyDays() {
        XCTAssertEqual(TrashPolicy.retentionDays, 30)
    }

    /// 没有删除时间 = 根本不在回收站。在用、归档、停用的都走这一支，
    /// 这一支判错一次就是在删用户正在用的订阅。
    func testRowsWithoutDeletionDateAreNeverCandidates() {
        XCTAssertEqual(TrashPolicy.verdict(deletedAt: nil, now: day(2026, 10, 1), calendar: utc), .notTrashed)
        XCTAssertFalse(TrashPolicy.isDue(deletedAt: nil, now: day(2026, 10, 1), calendar: utc))
        XCTAssertEqual(TrashPolicy.verdict(deletedAt: nil, now: Date.distantFuture, calendar: utc), .notTrashed,
                       "过了多少年都不许变成清理候选：判据只有「有没有删除时间」这一个")
    }

    func testDayTwentyNineIsStillKept() {
        let deleted = day(2026, 9, 2)
        let now = day(2026, 10, 1)
        XCTAssertEqual(TrashPolicy.verdict(deletedAt: deleted, now: now, calendar: utc), .kept(daysLeft: 1))
        XCTAssertFalse(TrashPolicy.isDue(deletedAt: deleted, now: now, calendar: utc))
    }

    func testDayThirtyIsDue() {
        let deleted = day(2026, 9, 1)
        let now = day(2026, 10, 1)
        XCTAssertEqual(TrashPolicy.verdict(deletedAt: deleted, now: now, calendar: utc), .due)
        XCTAssertTrue(TrashPolicy.isDue(deletedAt: deleted, now: now, calendar: utc))
    }

    /// 按日历天，不按 30×86400 秒：删掉那天深夜、现在凌晨，秒数还不够整 30 天，
    /// 但日历天已经是 30 天。按秒算的话，跨夏令时那一次的判定会跟着小时数漂。
    func testWholeCalendarDaysNotSeconds() {
        let deleted = day(2026, 9, 1, hour: 23)
        let now = day(2026, 10, 1, hour: 0)
        XCTAssertLessThan(now.timeIntervalSince(deleted), TimeInterval(TrashPolicy.retentionDays * 86_400),
                          "这条构造的要点就是「秒数还不够 30 天」")
        XCTAssertTrue(TrashPolicy.isDue(deletedAt: deleted, now: now, calendar: utc),
                      "日历天满 30 就算到期，不看小时")
    }

    /// 设备时钟被往回拨过（删除时间落在「未来」）：绝不因为数字算得出负数就删数据。
    func testDeletionDateInTheFutureIsNeverDue() {
        let now = day(2026, 10, 1)
        let deleted = day(2026, 10, 20)
        XCTAssertEqual(TrashPolicy.verdict(deletedAt: deleted, now: now, calendar: utc), .kept(daysLeft: 30),
                       "按满额显示，不给用户读出「还剩 19 天」那种倒着数的话")
        XCTAssertFalse(TrashPolicy.isDue(deletedAt: deleted, now: now, calendar: utc))
    }

    func testElapsedDaysCountedFromMidnight() {
        let deleted = day(2026, 9, 1, hour: 8)
        XCTAssertEqual(TrashPolicy.daysElapsed(since: deleted, now: day(2026, 9, 1, hour: 20), calendar: utc), 0,
                       "同一天算 0 天")
        XCTAssertEqual(TrashPolicy.daysElapsed(since: deleted, now: day(2026, 9, 3, hour: 1), calendar: utc), 2)
    }

    /// 页面上那行小字和到期判定读同一份规则，两处不能各写各的。
    func testNoticeWordsFollowTheVerdict() {
        let now = day(2026, 10, 1)
        XCTAssertEqual(TrashPolicy.notice(for: day(2026, 9, 12), now: now, calendar: utc), "还剩 11 天")
        XCTAssertEqual(TrashPolicy.notice(for: day(2026, 9, 1), now: now, calendar: utc), "保留期已满")
        XCTAssertEqual(TrashPolicy.notice(for: nil, now: now, calendar: utc), "")
    }

    /// §10.6「与 iCloud tombstone 保留策略协调」的算术前提：
    /// 本机硬删的那一刻才写下删除凭据，凭据的寿命必须明显长过回收站的保留期，
    /// 否则离线很久的设备一上线，那条已删的订阅就没了凭据管着、又能作为活记录推回云端。
    func testPurgeHorizonStaysShorterThanTombstoneRetention() {
        let horizon = TimeInterval(TrashPolicy.retentionDays * 86_400)
        XCTAssertLessThan(horizon, SyncTombstoneLog.retention)
        XCTAssertGreaterThan(SyncTombstoneLog.retention - horizon, 120 * 86_400,
                             "硬删之后留给离线设备的收敛窗口，至少还要剩四个多月")
    }
}

/// 到期清理这一脚（任务书 §10.6「30 天期限有真实的数据清理任务」）。
///
/// 测的是三件事凑齐才成立的那条承诺：只删到期的、删干净（事件和图标一起）、
/// 并且说出来。以前这三件事只有一件 —— 页面上写着「保留 30 天」。
///
/// # 这里测不到的一件事
///
/// 「落盘失败」这一支测不了：内存库里的 `save()` 在单元测试环境造不出失败
/// （和 `SubscriptionRepositoryTests` 同一个已知边界）。所以下面只断言失败时那句话的
/// 内容和样式，不声称「真的失败过一次」。
@MainActor
final class TrashPurgeTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var tombstones: SyncTombstoneLog!
    private var suiteName: String!
    private var iconRoot: URL!
    private var icons: IconImageStore!

    /// 所有用例共用这一个「现在」，「几天前」才有唯一解释。
    private lazy var now = BillingMath.calendar
        .date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(for: Schema(versionedSchema: SaurySchemaV4.self),
                                       configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        suiteName = "saury.trash.\(UUID().uuidString)"
        tombstones = SyncTombstoneLog(defaults: UserDefaults(suiteName: suiteName!)!)
        iconRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SauryTrashTests.\(UUID().uuidString)", isDirectory: true)
        icons = IconImageStore(root: iconRoot)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName!)?.removePersistentDomain(forName: suiteName!)
        try? FileManager.default.removeItem(at: iconRoot)
        container = nil
        context = nil
        try super.tearDownWithError()
    }

    // MARK: - 脚手架

    private func makeRepository() -> SubscriptionRepository {
        SubscriptionRepository(context: context, tombstones: tombstones, icons: icons)
    }

    private func janitor(_ repository: SubscriptionRepository) -> TrashJanitor {
        TrashJanitor(repository: repository, now: now)
    }

    /// 整天数地挪动，日历说了算 —— 用例里的「30 天前」就是这个意思。
    private func offset(_ days: Int) -> Date {
        BillingMath.calendar.date(byAdding: .day, value: days, to: now)!
    }

    /// 造一条「已经在回收站里躺了 `days` 天」的订阅。
    ///
    /// 先走真实的 `moveToTrash`（删除时间由它写），再把那一个字段挪到过去 ——
    /// 判据本来就只认 `deletedAt`，挪这个字段就是在挪唯一的那把尺子。
    @discardableResult
    private func trashed(_ repository: SubscriptionRepository, name: String, days: Int,
                         iconFile: String? = nil) throws -> Subscription {
        var made = SubscriptionDraft(name: name, priceMinorUnits: 4500, currencyCode: "CNY")
        made.iconImageFile = iconFile
        let row = try repository.apply(made)
        try repository.moveToTrash([row])
        row.deletedAt = offset(-days)
        try repository.commit("测试：把「\(name)」的删除时间挪到 \(days) 天前")
        return row
    }

    /// 一张真图存进图标库，返回落盘用的文件名。存不上就直接判红：
    /// 后面的「文件没了吧」那种断言，前提必须是文件真的在过。
    private func stageIcon(_ fileName: String) -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { renderer in
            UIColor.systemTeal.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        XCTAssertEqual(icons.store(image, named: fileName), fileName, "图标 \(fileName) 没能落盘")
        XCTAssertTrue(icons.exists(fileName), "图标 \(fileName) 落盘后读不回来")
        return fileName
    }

    /// 名字集合而不是数组：中文字符串按码点排序的结果和读起来的顺序不一样，
    /// 断言里比数组会把「谁先谁后」这种跟本用例无关的事也算进去。
    private func storedNames() -> Set<String> {
        Set(((try? context.fetch(FetchDescriptor<Subscription>())) ?? []).map(\.name))
    }

    private func charge(_ repository: SubscriptionRepository, _ row: Subscription) throws {
        try repository.record(SubscriptionEventDraft(id: UUID(), subscriptionID: row.id,
                                                     type: .charged, amountMinorUnits: 4500,
                                                     currencyCode: "CNY", happenedAt: offset(-40)))
    }

    // MARK: - 只删到期的那几条

    /// 29 天不动、30 天动手，顺序按删除时间从先到期排 —— 那句话要说得出删了谁。
    func testPurgesOnlyRowsPastTheRetention() throws {
        let repository = makeRepository()
        try trashed(repository, name: "还差一天", days: 29)
        try trashed(repository, name: "刚好到期", days: 30)
        try trashed(repository, name: "早就到期", days: 45)
        _ = try repository.apply(SubscriptionDraft(name: "还在用"))

        let report = janitor(repository).run()

        XCTAssertEqual(report.purged, ["早就到期", "刚好到期"], "按删除时间从先到期排，报告才稳定")
        XCTAssertEqual(storedNames(), ["还差一天", "还在用"])
        XCTAssertFalse(report.isQuiet, "删了东西就不许沉默")
    }

    /// 一条都没到期：不落盘、不广播、不说话。
    /// 这一条同时守着「第二趟不会追着自己再删一次」。
    func testNothingDueMeansNothingHappens() throws {
        let repository = makeRepository()
        try trashed(repository, name: "新删的", days: 3)

        var broadcasts = 0
        let token = NotificationCenter.default.addObserver(forName: .sauryDataChanged, object: nil, queue: nil) { _ in
            broadcasts += 1
        }
        let report = janitor(repository).run()
        NotificationCenter.default.removeObserver(token)

        XCTAssertTrue(report.isQuiet)
        XCTAssertNil(report.feedback, "空跑一趟不该弹任何条")
        XCTAssertEqual(broadcasts, 0, "什么都没改就别惊动提醒队列和小组件")
        XCTAssertEqual(storedNames(), ["新删的"])
    }

    /// 到期项清完之后再来一趟：库里已经没有候选，第二趟必须彻底安静。
    func testSecondRunAfterAPurgeIsQuiet() throws {
        let repository = makeRepository()
        try trashed(repository, name: "到期了", days: 31)
        XCTAssertFalse(janitor(repository).run().isQuiet)
        XCTAssertTrue(janitor(repository).run().isQuiet)
        XCTAssertEqual(storedNames(), [])
    }

    /// 在用 / 归档 / 停用三条，删除时间全是空的 —— 它们永远不是候选。
    /// 这是整套清理最不能出错的地方：判错一次就是删掉用户正在记的账。
    func testLiveArchivedAndInactiveAreNeverCandidates() throws {
        let repository = makeRepository()
        let live = try repository.apply(SubscriptionDraft(name: "在用"))
        let archived = try repository.apply(SubscriptionDraft(name: "归档"))
        let stopped = try repository.apply(SubscriptionDraft(name: "停用", state: .inactive))
        try repository.archive([archived])
        XCTAssertNil(live.deletedAt)
        XCTAssertNil(archived.deletedAt)
        XCTAssertNil(stopped.deletedAt)

        XCTAssertTrue(repository.expiredTrashRows(now: now).isEmpty)
        XCTAssertTrue(janitor(repository).run().isQuiet)
        XCTAssertEqual(storedNames(), ["在用", "停用", "归档"])
    }

    // MARK: - 删干净：事件、图标、凭据

    /// 到期清理和手动「彻底删除」必须走同一条路：连同历史扣费记录一起走。
    func testPurgeTakesTheEventsWithTheRow() throws {
        let repository = makeRepository()
        let row = try trashed(repository, name: "Netflix", days: 30)
        try charge(repository, row)
        XCTAssertEqual(repository.events(subscriptionID: row.id).count, 1)

        _ = janitor(repository).run()

        XCTAssertTrue(repository.events(subscriptionID: row.id).isEmpty,
                      "订阅没了、记录还留着，账本会把它们当孤儿丢掉，累计支付凭空少一块")
    }

    /// 回收站里那条没到期的，它的事件一个字都不动。
    func testKeptRowKeepsItsEvents() throws {
        let repository = makeRepository()
        let row = try trashed(repository, name: "Spotify", days: 10)
        try charge(repository, row)
        _ = janitor(repository).run()
        XCTAssertEqual(repository.events(subscriptionID: row.id).count, 1)
    }

    /// 独占的图标跟着一起没；别的订阅还在用的那张必须留下。
    /// App Store 搜来的图标按 trackId 存盘，几条订阅共用一张是常规情况，
    /// 「删这条就删这个文件」会把另一条的图变成空白。
    func testIconFileIsReleasedOnlyByTheLastReference() throws {
        let shared = stageIcon("363837318.png")
        let mine = stageIcon("1819668427.png")
        let repository = makeRepository()
        let staying = try repository.apply(SubscriptionDraft(name: "还在用这张图", iconImageFile: shared))
        try trashed(repository, name: "到期了", days: 30, iconFile: mine)
        XCTAssertNotNil(staying.iconImageFile)

        _ = janitor(repository).run()

        XCTAssertFalse(icons.exists(mine), "只属于这一条的图标，到期清理要负责收掉")
        XCTAssertTrue(icons.exists(shared), "还活着的那条在用这张，不能删")
    }

    /// 回收站里躺着的那条也算「还在用」：它随时能被恢复，图不能先被清掉。
    func testPurgedRowSharesItsIconWithOneStillInTrash() throws {
        let file = stageIcon("409824869.png")
        let repository = makeRepository()
        try trashed(repository, name: "到期", days: 35, iconFile: file)
        try trashed(repository, name: "还没到期", days: 4, iconFile: file)

        _ = janitor(repository).run()

        XCTAssertEqual(storedNames(), ["还没到期"])
        XCTAssertTrue(icons.exists(file), "回收站里还剩一条在用这张图")

        // 那一条也到期之后，文件才真的没人引用了。
        let last = try XCTUnwrap(storedRows().first)
        last.deletedAt = offset(-31)
        try repository.commit("测试：把最后一条推到到期")
        _ = janitor(repository).run()
        XCTAssertFalse(icons.exists(file), "两条都没了，这张就是真正的孤儿文件")
        XCTAssertEqual(storedNames(), [])
    }

    /// 没有图标的订阅被清，不该顺手把整个图标目录当成孤儿扫一遍。
    func testPurgeLeavesUnrelatedIconFilesAlone() throws {
        let file = stageIcon("1234567890.png")
        let repository = makeRepository()
        let keeper = try repository.apply(SubscriptionDraft(name: "在用", iconImageFile: nil))
        XCTAssertNil(keeper.iconImageFile)
        try trashed(repository, name: "到期且没有图标", days: 32)

        _ = janitor(repository).run()
        XCTAssertTrue(icons.exists(file), "这一趟没碰到的文件，清理由来不着")
    }

    /// 手动「彻底删除」走的是同一条路，图标规矩一样。
    func testManualPermanentDeleteReleasesTheIconTheSameWay() throws {
        let file = stageIcon("555555555.png")
        let repository = makeRepository()
        let row = try trashed(repository, name: "Netflix", days: 2, iconFile: file)

        try repository.deletePermanently([row])

        XCTAssertFalse(icons.exists(file))
    }

    /// 「清空数据」之后没有任何行还引用图标，目录里的都该跟着释放。
    func testWipeAllReleasesEveryIconFile() throws {
        let first = stageIcon("111111111.png")
        let second = stageIcon("222222222.png")
        let repository = makeRepository()
        try trashed(repository, name: "回收站里的", days: 4, iconFile: first)
        _ = try repository.apply(SubscriptionDraft(name: "在用的", iconImageFile: second))
        XCTAssertTrue(icons.exists(first) && icons.exists(second))

        try repository.wipeAll()

        XCTAssertFalse(icons.exists(first))
        XCTAssertFalse(icons.exists(second))
    }

    /// 凭据写的是硬删那一刻，不是进回收站那一刻 ——
    /// 差的那 30 天就是离线设备的收敛窗口。凭据在落盘成功之后才记。
    func testTombstoneDatesFromThePurgeNotTheOriginalTrash() throws {
        let repository = makeRepository()
        let row = try trashed(repository, name: "Netflix", days: 30)
        try charge(repository, row)
        let trashedAt = offset(-30)

        let before = Date()
        _ = janitor(repository).run()

        let marker = try XCTUnwrap(tombstones.date(for: .subscription, name: row.id.uuidString))
        XCTAssertGreaterThanOrEqual(marker, before, "凭据记的是清理这一刻，不是 30 天前那个删除时间")
        XCTAssertGreaterThan(marker.timeIntervalSince(trashedAt),
                             TimeInterval(TrashPolicy.retentionDays * 86_400),
                             "凭据比进回收站那一刻晚了整整一个保留期")
        XCTAssertEqual(tombstones.entries(for: .event).count, 1,
                       "事件也跟着留凭据，否则离线设备会把那条记录重新推上去")
    }

    /// 上一条件成立之后，这一条才有意义：硬删之后凭据还要再活满自己的保留期，
    /// 期间离线设备回来只能把本机那条按进回收站，不能当活记录上传。
    func testTombstonesOutliveThePurgeByTheirWholeRetention() throws {
        let repository = makeRepository()
        let row = try trashed(repository, name: "Netflix", days: 30)
        _ = janitor(repository).run()
        let marker = try XCTUnwrap(tombstones.date(for: .subscription, name: row.id.uuidString))

        // `forgetExpired(before:)` 收的是门限时刻（调用方给的是「现在 - 凭据寿命」），
        // 所以这里要按同步引擎那个口径喂时刻。
        func sweep(at moment: Date) -> [SyncTombstoneLog.Marker] {
            tombstones.forgetExpired(before: moment.addingTimeInterval(-SyncTombstoneLog.retention))
        }
        let expiry = marker.addingTimeInterval(SyncTombstoneLog.retention)

        XCTAssertTrue(sweep(at: expiry.addingTimeInterval(-60)).isEmpty,
                      "差一分钟才到期也不许清 —— 清了就等于放那条订阅复活")
        XCTAssertNotNil(tombstones.date(for: .subscription, name: row.id.uuidString))

        XCTAssertEqual(sweep(at: expiry.addingTimeInterval(60)).count, 1,
                      "活满 180 天之后就该由到期清理收走，不然凭据只会越积越多")
    }

    // MARK: - 恢复：时间清零、凭据作废、清理靠边

    /// §10.6「恢复后删除时间清零」。清零之后它连候选都不是：
    /// 已经躺了 40 天的那条，用户点一下恢复就永远轮不到清理。
    func testRestoringClearsTheDeletionDateAndSurvivesThePurge() throws {
        let repository = makeRepository()
        let row = try trashed(repository, name: "Netflix", days: 40)
        XCTAssertFalse(row.isTracked)

        try repository.restoreFromTrash([row])

        XCTAssertNil(row.deletedAt, "恢复必须把删除时间清掉，不然下一次还被当成回收站里的")
        XCTAssertTrue(row.isTracked, "恢复之后重新按在用的算")
        XCTAssertTrue(repository.expiredTrashRows(now: now).isEmpty)
        XCTAssertTrue(janitor(repository).run().isQuiet)
        XCTAssertEqual(storedNames(), ["Netflix"])
    }

    /// 恢复同时撤掉这一条的死刑凭据（本机这条是用户亲手捞回来的）。
    func testRestoringPardonsTheTombstone() throws {
        let repository = makeRepository()
        let row = try trashed(repository, name: "Netflix", days: 40)
        tombstones.record(kind: .subscription, name: row.id.uuidString, at: offset(-1))

        try repository.restoreFromTrash([row])

        XCTAssertNil(tombstones.date(for: .subscription, name: row.id.uuidString))
    }

    // MARK: - 说出来

    /// 清理不沉默：删了几条、删了什么，句子里要读得出来，样式是「留在屏上」那一种。
    func testPurgeAnnouncesWhatItDeleted() throws {
        let repository = makeRepository()
        try trashed(repository, name: "Netflix", days: 30)
        let one = try XCTUnwrap(janitor(repository).run().feedback)
        XCTAssertEqual(one.style, .info, "自动清理不是撤销入口，图标不能画成回转箭头")
        XCTAssertNil(one.actionTitle, "不可恢复的事不该带一个「撤销」")
        XCTAssertTrue(one.text.contains("Netflix"))
        XCTAssertTrue(one.text.contains("\(TrashPolicy.retentionDays) 天"))
        XCTAssertTrue(one.text.contains("历史扣费记录"))

        try trashed(repository, name: "Spotify", days: 33)
        try trashed(repository, name: "iCloud", days: 60)
        let batch = try XCTUnwrap(janitor(repository).run().feedback)
        XCTAssertTrue(batch.text.contains("2 条"), "两条以上报数量：\(batch.text)")
    }

    /// 落盘失败那一支的话：数据还在回收站里、下一趟再试。
    /// 只断言措辞 —— 内存库造不出真的 `save()` 失败。
    func testFailureWordingPromisesAnotherTry() {
        let report = TrashJanitor.Report(purged: [], failure: "磁盘写入被拒绝")
        XCTAssertFalse(report.isQuiet)
        let message = report.feedback
        XCTAssertEqual(message?.style, .failure)
        XCTAssertTrue(message?.text.contains("磁盘写入被拒绝") ?? false)
        XCTAssertTrue(message?.text.contains("还留在回收站") ?? false)
        XCTAssertTrue(message?.text.contains("下次打开会再试") ?? false)
    }

    /// 名字一样的两条不能因为「都叫 Netflix」就被并成一句话：数量要如实。
    func testSameNameTwiceStillCountsTwice() throws {
        let repository = makeRepository()
        try trashed(repository, name: "Netflix", days: 31)
        try trashed(repository, name: "Netflix", days: 41)
        let report = janitor(repository).run()
        XCTAssertEqual(report.purged.count, 2)
        XCTAssertTrue(report.feedback?.text.contains("2 条") ?? false)
    }

    private func storedRows() -> [Subscription] {
        (try? context.fetch(FetchDescriptor<Subscription>())) ?? []
    }
}
