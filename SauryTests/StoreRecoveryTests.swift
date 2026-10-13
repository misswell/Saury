import XCTest
import SwiftData
import SQLite3
@testable import Saury

/// 打不开库的四种情况各归各的处理（PR2d）。
/// 判据读的是真实文件，所以这里也拿真实文件来考它。
final class StoreFailureClassificationTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("saury-classify-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 只读目录得先改回可写，否则临时目录清不掉。
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for dir in ["locked"] {
            try? fm.setAttributes([.posixPermissions: 0o700],
                                  ofItemAtPath: root.appendingPathComponent(dir).path)
        }
        try? fm.removeItem(at: root)
        root = nil
    }

    /// SwiftData 实测会只丢这么一句，什么线索都不给 —— 判据不能靠它。
    private var opaqueError: NSError {
        NSError(domain: "SwiftData.SwiftDataError", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unresolved error loading container"])
    }

    private func writeJunk(_ url: URL) throws {
        try Data("this is definitely not a sqlite database file".utf8).write(to: url)
    }

    /// 建一个真的、写得进数据的库。
    private func makeHealthyStore(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let container = try PersistenceController.makeContainer(url: url)
        let context = ModelContext(container)
        context.insert(Subscription(name: "Netflix", priceMinorUnits: 4500,
                                    currencyCode: "CNY", cycle: .monthly))
        try context.save()
        return url
    }

    func testTextFileIsCorruptionNotAnUnknownReason() throws {
        let url = root.appendingPathComponent("junk.store")
        try writeJunk(url)
        XCTAssertEqual(StoreFailure(opaqueError, storeURLs: [url]).kind, .unreadableStore,
                       "SQLite 都喊「file is not a database」了，不能归成认不出来")
    }

    func testTruncatedStoreIsCorruption() throws {
        let url = try makeHealthyStore(named: "trunc.store")
        let data = try Data(contentsOf: url)
        try Data(Array(data.prefix(1200))).write(to: url)
        if case .corrupted = StoreFileProbe.verdict(forStoreAt: url) { return }
        XCTFail("只剩开头的库应该被认成坏了，实际：\(StoreFileProbe.verdict(forStoreAt: url))")
    }

    func testIntactStoreIsBlamedOnTheSchemaNotOnTheUser() throws {
        let url = try makeHealthyStore(named: "good.store")
        XCTAssertEqual(StoreFileProbe.verdict(forStoreAt: url), .intact)
        // 文件是好的 → 读不懂它的是我们的版本 → 不许把人家改名挪走。
        let failure = StoreFailure(opaqueError, storeURLs: [url])
        XCTAssertEqual(failure.kind, .migration)
        XCTAssertFalse(failure.canRebuildStore)
    }

    /// 别的连接正拿着这个库（后台还开着一个实例、或者上一个进程没退干净）时，
    /// 体检会被挡在锁外面。那种情况一个字节都没坏 —— 判成坏了就会把活库改名挪走。
    func testStoreLockedByAnotherConnectionIsNotCalledCorrupt() throws {
        let url = try makeHealthyStore(named: "locked-by-other.store")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil),
                       SQLITE_OK)
        let connection = try XCTUnwrap(handle)
        defer {
            sqlite3_exec(connection, "ROLLBACK;", nil, nil, nil)
            sqlite3_close_v2(connection)
        }
        // 上一条连接（SwiftData 那一趟）是**异步**释放的：整机正连着跑别的用例时，
        // `makeHealthyStore` 已经返回了，它的连接却可能还没关。那种状态下 EXCLUSIVE 拿不到，
        // 而这个用例要考的场景 —— 「库正被别人占着」—— 压根还没成立，往下判等于什么都没测。
        // 所以让 SQLite 自己等到真占住为止；等不到就当场失败，不许拿着没占住的库继续。
        sqlite3_busy_timeout(connection, 5_000)
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        if case .corrupted(let cause) = StoreFileProbe.verdict(forStoreAt: url) {
            XCTFail("只是被别人占着，不是坏了：\(cause)")
        }
        let failure = StoreFailure(opaqueError, storeURLs: [url])
        XCTAssertFalse(failure.canRebuildStore, "占用中就把库改名，等于把正在用的账本抢走")
        XCTAssertTrue(fm.fileExists(atPath: url.path))
    }

    func testUnwritableLocationIsNeverALicenseToMoveFiles() throws {
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let url = locked.appendingPathComponent("k.store")
        try writeJunk(url)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)

        let failure = StoreFailure(opaqueError, storeURLs: [url])
        XCTAssertEqual(failure.kind, .unwritable, "写不进去时先按权限算，别急着说文件坏了")
        XCTAssertFalse(failure.canRebuildStore)
        XCTAssertTrue(fm.fileExists(atPath: url.path), "判成不可写之后，一个文件都不许动")
    }

    func testMissingFileFallsBackToTheErrorText() throws {
        let absent = root.appendingPathComponent("never-existed.store")
        XCTAssertEqual(StoreFailure.judge(text: "The file couldn’t be opened because it isn’t in the correct format.",
                                          storeURLs: [absent]),
                       .unreadableStore)
        XCTAssertEqual(StoreFailure.judge(text: "failed updating preflight statement: no such column",
                                          storeURLs: [absent]), .migration)
        XCTAssertEqual(StoreFailure.judge(text: opaqueError.localizedDescription, storeURLs: [absent]), .other)
    }

    /// 权限的措辞最常和「打不开文件」混在一句话里，先判权限才不会误挪库。
    func testPermissionWordingWinsOverOpeningWording() {
        XCTAssertEqual(StoreFailure.classify("The file “default.store” couldn’t be opened. Permission denied."),
                       .unwritable)
    }

    func testOnlyCorruptionPermitsRebuilding() {
        XCTAssertTrue(StoreFailure.unreadableStore("x").canRebuildStore)
        XCTAssertFalse(StoreFailure.migration("x").canRebuildStore)
        XCTAssertFalse(StoreFailure.unwritable("x").canRebuildStore)
        XCTAssertFalse(StoreFailure.other("x").canRebuildStore)
    }

    func testEveryFailureKindHasAUserFacingSentence() {
        for failure in [StoreFailure.migration("d"), .unreadableStore("d"), .unwritable("d"), .other("d")] {
            XCTAssertFalse(failure.userText.isEmpty)
            XCTAssertFalse(failure.advice.isEmpty)
            XCTAssertTrue(failure.userText.contains("库") || failure.userText.contains("文件"),
                          "话要说清楚是对什么东西出的事：\(failure.userText)")
        }
    }
}

/// 真的开一次库：坏了的怎么处理、开不起来时 App 怎么活下来。
final class StoreRecoveryTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("saury-recovery-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // 留底记录是跨启动的，测试之间不能互相看见。
        UserDefaults.standard.removeObject(forKey: PersistenceController.recoveryDefaultsKey)
        PersistenceController.acknowledgeRecovery()
    }

    override func tearDownWithError() throws {
        PersistenceController.acknowledgeRecovery()
        try? fm.removeItem(at: root)
        root = nil
    }

    /// 坏库的处置：改名留底 → 建新库 → 把这件事说出来。一个字节都不能丢。
    func testCorruptStoreIsKeptAsideThenRebuilt() throws {
        let store = root.appendingPathComponent("default.store")
        let junk = Data("this is definitely not a sqlite database file".utf8)
        try junk.write(to: store)

        let container = try PersistenceController.makeContainerWithRecovery(url: store)
        let context = ModelContext(container)
        context.insert(Subscription(name: "新记录", priceMinorUnits: 100,
                                    currencyCode: "CNY", cycle: .monthly))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Subscription>()), 1, "新库要真能用")

        let keptAside = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("quarantined") }
        XCTAssertEqual(keptAside.count, 1, "旧库要还在原目录，只是换了名字：\(keptAside)")
        XCTAssertEqual(try Data(contentsOf: keptAside[0]), junk, "留底的内容必须一个字节都没变")

        let recovery = try XCTUnwrap(PersistenceController.lastRecovery)
        XCTAssertEqual(recovery.reason.kind, .unreadableStore)
        XCTAssertEqual(recovery.keptAside.count, 1)
        let notice = try XCTUnwrap(PersistenceController.launchNotice)
        XCTAssertTrue(notice.contains("旧库已经改名留在原目录"), notice)
        XCTAssertTrue(notice.contains("从备份"), notice)
    }

    /// 什么都没出过时，不许留下任何「恢复过」的说法。
    func testHealthyOpenReportsNoRecovery() throws {
        let store = root.appendingPathComponent("clean.store")
        _ = try PersistenceController.makeContainerWithRecovery(url: store)
        XCTAssertNil(PersistenceController.lastRecovery)

        // 第二次打开同一个库：SwiftData 自己留着句柄，这里只要别再报恢复。
        _ = try PersistenceController.makeContainerWithRecovery(url: store)
        XCTAssertNil(PersistenceController.lastRecovery)
    }

    /// 重建过一次之后，下一次启动照样要认这件事：留底的文件还在磁盘上，
    /// 眼下用的也确实是另建的新库 —— 一次成功的打开不会把这些变成假话。
    func testRecoveryNoteOutlivesTheLaunchThatMadeIt() throws {
        let store = root.appendingPathComponent("carry.store")
        try Data("this is definitely not a sqlite database file".utf8).write(to: store)
        let first = try PersistenceController.makeContainerWithRecovery(url: store)
        let note = try XCTUnwrap(PersistenceController.lastRecovery)

        // 模拟「杀掉 App 再打开」：新容器开得干干净净。
        _ = first
        _ = try PersistenceController.makeContainerWithRecovery(url: store)
        let again = try XCTUnwrap(PersistenceController.lastRecovery, "第二次打开成功，不等于上次的事没说清")
        XCTAssertEqual(again.keptAside, note.keptAside)
        XCTAssertEqual(again.reason.kind, .unreadableStore)
        XCTAssertTrue(fm.fileExists(atPath: note.keptAside[0].path), "说好的留底必须还在")

        let stored = try XCTUnwrap(PersistenceController.storedRecovery(), "记录必须落在磁盘上，不能只在内存里")
        XCTAssertEqual(stored, note, "跨启动靠的就是这份记录，走形了等于没说")
        let raw = try XCTUnwrap(UserDefaults.standard.data(forKey: PersistenceController.recoveryDefaultsKey))
        XCTAssertEqual(try JSONDecoder().decode(StoreRecovery.self, from: raw), note)
    }

    /// 「我看过了」只撤提示，不动磁盘上的任何东西。
    func testAcknowledgingSilencesTheNoteWithoutTouchingFiles() throws {
        let store = root.appendingPathComponent("ack.store")
        try Data("this is definitely not a sqlite database file".utf8).write(to: store)
        _ = try PersistenceController.makeContainerWithRecovery(url: store)
        let keptAside = try XCTUnwrap(PersistenceController.lastRecovery).keptAside

        PersistenceController.acknowledgeRecovery()

        XCTAssertNil(PersistenceController.lastRecovery)
        XCTAssertNil(UserDefaults.standard.data(forKey: PersistenceController.recoveryDefaultsKey))
        XCTAssertNil(PersistenceController.launchNotice)
        XCTAssertTrue(keptAside.allSatisfy { fm.fileExists(atPath: $0.path) },
                      "撤掉提示不是撤掉数据")
    }

    /// 连库都建不起来时，App 必须照常开起来（内存库），并且一直挂着说明。
    func testLaunchFallsBackToATemporaryStoreAndSaysSo() throws {
        // 父路径是一个普通文件：这个位置根本建不出库，也没有任何用户数据可动。
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let impossible = blocker.appendingPathComponent("default.store")

        let container = PersistenceController.makeContainerForLaunch(url: impossible)
        let context = ModelContext(container)
        context.insert(Subscription(name: "临时库里的一条", priceMinorUnits: 200,
                                    currencyCode: "CNY", cycle: .monthly))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Subscription>()), 1)

        let failure = try XCTUnwrap(PersistenceController.lastOpenFailure)
        XCTAssertFalse(failure.canRebuildStore)
        XCTAssertFalse(failure.detail.isEmpty, "内部日志要留着原始错误")
        XCTAssertTrue(failure.userText.contains("没能认出来"),
                      "认不出来就要承认，不能编一句「文件坏了」：\(failure.userText)")
        let notice = try XCTUnwrap(PersistenceController.launchNotice)
        XCTAssertTrue(notice.contains("跑在临时库上"), notice)
        XCTAssertTrue(notice.contains("下次打开就没了"), notice)
        XCTAssertTrue(fm.fileExists(atPath: blocker.path), "兜底不许碰现场")
    }

    func testQuarantineRenamesAllThreeSQLiteFiles() throws {
        let store = root.appendingPathComponent("three.store")
        try Data("junk".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: store.path + "-shm"))

        let moved = PersistenceController.quarantineStore(at: store)
        XCTAssertEqual(moved.count, 3)
        XCTAssertFalse(fm.fileExists(atPath: store.path))
        XCTAssertTrue(moved.allSatisfy { fm.fileExists(atPath: $0.path) }, "只是改名，不是删除")
        XCTAssertTrue(moved.allSatisfy { $0.lastPathComponent.contains("quarantined") })
    }

    /// 现场什么都没有时，quarantine 返回空 —— 上层靠这一条拒绝重建。
    func testQuarantineOfAbsentStoreMovesNothing() {
        let moved = PersistenceController.quarantineStore(at: root.appendingPathComponent("ghost.store"))
        XCTAssertTrue(moved.isEmpty)
    }
}
