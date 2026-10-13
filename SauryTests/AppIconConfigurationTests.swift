import UIKit
import XCTest
@testable import Saury

/// 备用 App 图标的名字映射（任务书 §10.3）。
final class AppIconChoiceTests: XCTestCase {
    func testEachChoiceMapsToExactlyOneAlternateIconName() {
        XCTAssertNil(AppIconChoice.auto.alternateName, "「自动」= 不指定备用图标，不是随便挑一个")
        XCTAssertEqual(AppIconChoice.light.alternateName, "AppIconLight")
        XCTAssertEqual(AppIconChoice.dark.alternateName, "AppIconDark")
        XCTAssertEqual(Set(AppIconChoice.allCases.compactMap(\.alternateName)).count, 2)
    }

    func testUnknownIconNameFallsBackToAuto() {
        XCTAssertEqual(AppIconChoice.matching(nil), .auto)
        XCTAssertEqual(AppIconChoice.matching("AppIconLight"), .light)
        XCTAssertEqual(AppIconChoice.matching("AppIconDark"), .dark)
        // 老版本或别的包留下的名字：认不出来就回到主图标，而不是显示一个不存在的档。
        XCTAssertEqual(AppIconChoice.matching("AppIconNeon"), .auto)
    }

    func testPreviewAssetNamesAreDistinct() {
        let names = AppIconChoice.allCases.map(\.previewAssetName)
        XCTAssertEqual(Set(names).count, names.count)
    }
}

/// 「包里到底配了哪几个备用图标」这件事的读法。
final class AppIconConfigurationTests: XCTestCase {
    private func plist(_ names: [String: [String]]) -> [String: Any] {
        names.mapValues { entries in
            ["CFBundleAlternateIcons": Dictionary(uniqueKeysWithValues: entries.map { ($0, [String: Any]()) })]
        }
    }

    private func icons(_ names: String...) -> [String: Any] {
        plist(["CFBundleIcons": names])
    }

    func testReadsAlternateIconsFromBothPlatforms() {
        let info: [String: Any] = [
            "CFBundleIcons": ["CFBundleAlternateIcons": ["AppIconLight": [String: Any]()]],
            "CFBundleIcons~ipad": ["CFBundleAlternateIcons~ipad": ["AppIconDark": [String: Any]()]]
        ]
        XCTAssertEqual(AppIconConfiguration.alternateNames(in: info), ["AppIconLight", "AppIconDark"])
    }

    func testNothingConfiguredIsEmptySet() {
        XCTAssertEqual(AppIconConfiguration.alternateNames(in: [:]), [])
        XCTAssertEqual(AppIconConfiguration.alternateNames(
            in: ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon"]]]]), [])
    }

    /// 设备不支持时三个格子都不能算「可选」—— 包括不需要备用图标的「自动」。
    func testUnsupportedDeviceMakesEveryChoiceUnavailable() {
        let config = AppIconConfiguration(info: icons("AppIconLight"), supportsAlternateIcons: false)
        for choice in AppIconChoice.allCases {
            XCTAssertFalse(config.isAvailable(choice), "\(choice.title) 在不支持换图标的设备上被标成了可选")
        }
    }

    /// 配了浅色没配深色：只有深色那一格被按住。摆一个点了必然失败的按钮就是假功能。
    func testMissingAlternateIconDisablesOnlyThatChoice() {
        let config = AppIconConfiguration(info: icons("AppIconLight"), supportsAlternateIcons: true)
        XCTAssertTrue(config.isAvailable(.auto))
        XCTAssertTrue(config.isAvailable(.light))
        XCTAssertFalse(config.isAvailable(.dark))
    }

    // MARK: - 这个包真的把备用图标带进去了吗

    /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` 配了没有、
    /// `.appiconset` 进包了没有，最终都体现在宿主 App 的 Info.plist 上。
    func testBuiltBundleConfiguresBothAlternateIcons() {
        let names = AppIconConfiguration.alternateNames(in: Bundle.main.infoDictionary ?? [:])
        XCTAssertTrue(names.contains("AppIconLight"), "包里没配 AppIconLight，现有：\(names)")
        XCTAssertTrue(names.contains("AppIconDark"), "包里没配 AppIconDark，现有：\(names)")
    }

    /// 系统这一侧认不认这个包的换图标能力。false 的话页面上就该显示「不可更换」，
    /// 而不是摆三个按钮让用户点了没反应。
    func testSystemReportsAlternateIconsSupported() {
        XCTAssertTrue(UIApplication.shared.supportsAlternateIcons)
    }

    /// 设置页那三块预览格子：资源没进包的话这里会拿到 nil，
    /// 页面上就是一个问号 —— 不能是看不出来的空白。
    func testPreviewImagesShipInBundle() {
        for choice in AppIconChoice.allCases {
            XCTAssertNotNil(UIImage(named: choice.previewAssetName),
                            "\(choice.previewAssetName) 没进包，设置页那一格会是空白")
        }
    }

    // MARK: - 真走到系统那一层

    /// 真调一次 `setAlternateIconName`。两种环境下都必须成立的不变量只有一条：
    /// **系统说没换成，图标名就一定没变**（§10.3「系统返回错误时 UI 不显示假成功状态」）。
    ///
    /// 模拟器里这一步会直接报错（`NSPOSIXErrorDomain Code=5`，
    /// 测试宿主进程加载不到 CoreServicesUIAgent 的 upcall），走的是失败那一支；
    /// 真机上会真的换过来。所以这里两种结果都接受，但把实际走了哪一支留在日志里 ——
    /// 「成功那一支只能在真机验」这件事记在 `Docs/EON_QA.md` 的外部前置条件里。
    @MainActor
    func testSystemEitherSwitchesOrLeavesTheNameUntouched() async {
        let original = UIApplication.shared.alternateIconName
        // 挑一个和当前不一样的目标：不然「换成功了」可能只是原地没动。
        let target = original == "AppIconLight" ? "AppIconDark" : "AppIconLight"
        let applier = SystemAppIconApplier()
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<SwitchOutcome, Never>) in
            applier.apply(target) { error in
                DispatchQueue.main.async {
                    continuation.resume(returning: SwitchOutcome(error: error, nameAfter: applier.currentAlternateIconName))
                }
            }
        }

        if let error = outcome.error {
            XCTAssertEqual(outcome.nameAfter, original,
                           "系统报了错（\(error.localizedDescription)）却把图标名改了")
            NSLog("[appicon] 这台设备没能换图标，走失败分支：\(error.localizedDescription)")
        } else {
            XCTAssertEqual(outcome.nameAfter, target, "系统说成功了，图标名却没变")
            NSLog("[appicon] 换图标成功：\(original ?? "主图标") → \(target)")
        }

        // 收尾要等：换成功却没等回话就退进程，会在设备上留下用户没点过的图标。
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            applier.apply(original) { _ in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        XCTAssertEqual(UIApplication.shared.alternateIconName, original)
    }

    private struct SwitchOutcome {
        let error: Error?
        let nameAfter: String?
    }
}

/// 那三格的状态机：谁在路上、系统回话之后该显示什么。
///
/// 这里测的是 §10.3 最硬的一条 —— 失败不许显示成功。真机上的成功分支由
/// `AppIconConfigurationTests.testSystemEitherSwitchesOrLeavesTheNameUntouched` 兜。
@MainActor
final class AppIconSelectionTests: XCTestCase {
    private let full = AppIconConfiguration(info: ["CFBundleIcons": ["CFBundleAlternateIcons": [
        "AppIconLight": [String: Any](), "AppIconDark": [String: Any]()
    ]]], supportsAlternateIcons: true)

    private var unavailable: AppIconConfiguration {
        AppIconConfiguration(info: ["CFBundleIcons": ["CFBundleAlternateIcons": [
            "AppIconLight": [String: Any]()
        ]]], supportsAlternateIcons: true)
    }

    private func makeSelection(_ config: AppIconConfiguration, current: AppIconChoice = .auto) -> AppIconSelection {
        AppIconSelection(configuration: config, current: current)
    }

    func testTapHandsTheRightNameToTheSystem() {
        var selection = makeSelection(full)
        XCTAssertEqual(selection.tap(.dark), .apply("AppIconDark"))
        XCTAssertEqual(selection.pending, .dark)

        var backToPrimary = makeSelection(full, current: .dark)
        XCTAssertEqual(backToPrimary.tap(.auto), .apply(nil), "「自动」必须真的把 nil 交给系统，也就是回到主图标")
    }

    func testTappingTheCurrentChoiceRequestsNothing() {
        var selection = makeSelection(full, current: .light)
        XCTAssertEqual(selection.tap(.light), .ignore)
        XCTAssertNil(selection.pending)
    }

    func testSecondTapWhilePendingRequestsNothing() {
        var selection = makeSelection(full)
        _ = selection.tap(.light)
        XCTAssertEqual(selection.tap(.dark), .ignore, "上一笔还没回话就再发一次，等于让系统连换两次")
        XCTAssertEqual(selection.pending, .light)
    }

    /// 这一条是 §10.3 点名的：系统返回错误时，页面不许停在用户刚点的那一格。
    func testFailureKeepsTheOldSelectionAndSpeaks() {
        var selection = makeSelection(full, current: .auto)
        _ = selection.tap(.dark)
        selection.completed(systemName: nil, error: NSError(domain: "LSApplicationWorkspace", code: 5,
                                                            userInfo: [NSLocalizedDescriptionKey: "换不了"]))

        XCTAssertEqual(selection.current, .auto, "系统说没换成，选中态却跟着用户点了")
        XCTAssertNil(selection.pending)
        XCTAssertTrue(selection.failure?.contains("换不了") == true,
                      "错误原因得写在页面上，不能只让格子闪一下：\(selection.failure ?? "nil")")
    }

    func testSuccessMovesTheSelectionAndClearsTheError() {
        var selection = makeSelection(full, current: .auto)
        _ = selection.tap(.dark)
        selection.completed(systemName: "AppIconDark", error: nil)
        XCTAssertEqual(selection.current, .dark)
        XCTAssertNil(selection.failure)
    }

    /// 模拟器实测会走到这一支：系统回了一个错，图标名却已经改过去了。
    /// 这时候说「没接受」是假话，得说清楚换成了。
    func testErrorThatStillChangedTheIconSaysItChanged() {
        var selection = makeSelection(full, current: .auto)
        _ = selection.tap(.dark)
        selection.completed(systemName: "AppIconDark",
                            error: NSError(domain: "LS", code: 5, userInfo: [NSLocalizedDescriptionKey: "upcall 没起来"]))
        XCTAssertEqual(selection.current, .dark, "系统那边已经换了，页面不该还亮着旧的一格")
        XCTAssertTrue(selection.failure?.contains("但图标已经换成") == true,
                      "报错了还是要说，但不能说成没换成：\(selection.failure ?? "nil")")
    }

    /// 反过来：系统嘴上说成功了，名字却没动 —— 那一格也不能亮。
    func testClaimedSuccessWithoutANameChangeDoesNotFakeIt() {
        var selection = makeSelection(full, current: .auto)
        _ = selection.tap(.dark)
        selection.completed(systemName: nil, error: nil)
        XCTAssertEqual(selection.current, .auto, "系统记的还是主图标，页面却显示选了深色")
    }

    /// 上一笔失败留下的话，不该在用户又成功换了一次之后还挂在页面上。
    func testLaterSuccessClearsThePreviousFailure() {
        var selection = makeSelection(full)
        _ = selection.tap(.dark)
        selection.completed(systemName: nil, error: NSError(domain: "x", code: 1))
        XCTAssertNotNil(selection.failure)
        _ = selection.tap(.light)
        selection.completed(systemName: "AppIconLight", error: nil)
        XCTAssertNil(selection.failure)
        XCTAssertEqual(selection.current, .light)
    }

    func testUnconfiguredChoiceIsRefusedWithAReason() {
        var selection = makeSelection(unavailable)
        let intent = selection.tap(.dark)
        guard case .refused(let reason) = intent else {
            return XCTFail("包里没这个图标，却还是发了请求：\(intent)")
        }
        XCTAssertTrue(reason.contains("AppIconDark"))
        XCTAssertNil(selection.pending)
        XCTAssertEqual(selection.current, .auto)
    }

    func testUnsupportedDeviceRefusesEveryChoice() {
        var selection = makeSelection(AppIconConfiguration(info: [:], supportsAlternateIcons: false))
        for choice in AppIconChoice.allCases {
            guard case .refused = selection.tap(choice) else {
                return XCTFail("\(choice.title) 在不支持的设备上发出了真实请求")
            }
        }
    }

    func testSystemReReadWinsOverStaleSelection() {
        var selection = makeSelection(full, current: .light)
        selection.readFromSystem("AppIconDark")
        XCTAssertEqual(selection.current, .dark)
        // 请求还在路上的时候，回读不许把选中态抢走。
        _ = selection.tap(.auto)
        selection.readFromSystem("AppIconLight")
        XCTAssertEqual(selection.current, .dark)
    }
}
