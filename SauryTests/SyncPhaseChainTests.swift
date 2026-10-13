import XCTest
import Combine
import SwiftData
@testable import Saury

/// §4.2 点名要的那条链，单独一个文件：观察 `@Published` 要用 Combine，
/// 而 Combine 自己也有一个 `Subscription`，和本项目的 SwiftData 模型撞名。
/// 这个文件里凡是模型的类型名都写全（`Saury.Subscription`）。
@MainActor
final class SyncPhaseChainTests: XCTestCase {
    private var devices: [TestDevice] = []

    override func tearDownWithError() throws {
        devices.forEach { $0.cleanUp() }
        devices = []
    }

    private func makeDevice(store: FakeCloudStore) throws -> TestDevice {
        let device = try TestDevice(store: store)
        devices.append(device)
        return device
    }

    /// `idle → checkingAccount → fetching → merging → uploading → verifying → success`，
    /// 一格不落、顺序不换。页面上「当前阶段」那一行显示的就是这里流过去的每一个值。
    func testThePhaseChainRunsThroughEveryStageInOrder() async throws {
        let store = FakeCloudStore()
        store.seed([SyncFixtures.subscription(id: UUID(), name: "Netflix", updatedAt: SyncFixtures.t2)])
        let device = try makeDevice(store: store)
        let local = Saury.Subscription(name: "本机自己的一条")
        device.context.insert(local)
        try device.context.save()

        var seen: [SyncPhase] = []
        // @Published 在订阅的那一刻就把当前值发一遍，所以第一个必然是 idle。
        let token = device.coordinator.$phase.sink { seen.append($0) }
        await device.coordinator.requestSync(reason: .manual)
        token.cancel()

        XCTAssertEqual(seen.stages(), [.idle, .checkingAccount, .fetching, .merging,
                                       .uploading, .verifying, .success],
                       "阶段链必须一格不落、顺序不换：\(seen.map(\.title))")
    }

    /// 半途失败的那一条：失败发生在读账户之后，所以后面的 `uploading` 一格都不该出现。
    /// 「跳到最后报成功」是这一版要从结构上堵死的事。
    func testAFailureStopsTheChainWhereItActuallyStopped() async throws {
        let store = FakeCloudStore()
        store.account = .noAccount
        let device = try makeDevice(store: store)

        var seen: [SyncPhase] = []
        let token = device.coordinator.$phase.sink { seen.append($0) }
        await device.coordinator.requestSync(reason: .manual)
        token.cancel()

        XCTAssertEqual(seen.stages(), [.idle, .checkingAccount, .failed],
                       "账户这一步就没过，后面每一格都不许出现：\(seen.map(\.title))")
        XCTAssertEqual(store.indexReads, 0, "账户不可用连清单都不该读")
    }
}

/// 把八个阶段收成「走到第几格」。附带数据（报告里的计数、失败原因那句人话）每一趟都不一样，
/// 拿它们比顺序是在比运气；比格子的名字就够回答「有没有跳步」了。
enum SyncStage: Equatable {
    case idle, checkingAccount, fetching, merging, uploading, verifying, success, failed
}

extension Sequence where Element == SyncPhase {
    /// 相邻重复要压掉：同一格被连写两次不是跳步，算进去才会误报。
    func stages() -> [SyncStage] {
        var kept: [SyncStage] = []
        for phase in self {
            let stage: SyncStage
            switch phase {
            case .idle: stage = .idle
            case .checkingAccount: stage = .checkingAccount
            case .fetching: stage = .fetching
            case .merging: stage = .merging
            case .uploading: stage = .uploading
            case .verifying: stage = .verifying
            case .success: stage = .success
            case .failed: stage = .failed
            }
            if kept.last != stage { kept.append(stage) }
        }
        return kept
    }
}
