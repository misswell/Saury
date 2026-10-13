import XCTest
import Combine
@testable import Saury

/// 任务书 §6.1 点名的那件事：`SubPreferences` 「虽然符合 ObservableObject，
/// 却没有真正发布属性变更」。属性全是直接落在 UserDefaults 上的算属性，
/// SwiftUI 看不见那一次写入 —— 于是要么界面不动，要么整屏重绘。
///
/// 这里测的就是「到底有没有发出去、发出去几次」：
/// 一次真实改动 = 一次通知；改成相同的值 = 一次都不发；
/// 一批连着改 = 还是只发一次；同步用的时间戳记账 = 不算改动。
///
/// §6.2 的副作用表里，「立刻反映到界面」这一半只能在真机上看；
/// 但「写这个键必须同时给那一组盖时间戳」和「旧载荷缺列时按旧意思补齐」
/// 是能在这一层钉住的，钉住了同步才不会把用户另一台设备上的选择盖掉。
@MainActor
final class PreferencesPublishingTests: XCTestCase {
    private var suiteNames: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    override func tearDownWithError() throws {
        cancellables = []
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames = []
    }

    // MARK: - 脚手架

    private func makePreferences(_ tag: String = "run",
                                 defaults: UserDefaults? = nil) -> SubPreferences {
        let store = defaults ?? {
            let name = "SauryPreferencesTests.\(tag).\(UUID().uuidString)"
            suiteNames.append(name)
            return UserDefaults(suiteName: name)!
        }()
        return SubPreferences(defaults: store)
    }

    /// 记下每一次发布。返回值是「到目前为止发出去几次」。
    private func watch(_ preferences: SubPreferences) -> () -> Int {
        let counter = Counter()
        preferences.objectWillChange
            .sink { counter.value += 1 }
            .store(in: &cancellables)
        return { counter.value }
    }

    private final class Counter { var value = 0 }

    // MARK: - §6.1 发布本身

    /// 真的改了值就必须发出去一次 —— 不发就是「改了设置界面不动，重开 App 才刷新」。
    func testEverySettingKindPublishesOnceWhenItActuallyChanges() {
        let preferences = makePreferences()
        let changes = watch(preferences)

        preferences.accentHex = SubPreferences.accentChoices[3]
        XCTAssertEqual(changes(), 1, "主题色")

        preferences.appearance = .dark
        XCTAssertEqual(changes(), 2, "外观")

        preferences.coloredCards = false
        XCTAssertEqual(changes(), 3, "彩色卡片")

        preferences.defaultCurrency = "USD"
        XCTAssertEqual(changes(), 4, "默认货币")

        preferences.hiddenPanels = [.calendar]
        XCTAssertEqual(changes(), 5, "面板隐藏")

        preferences.panelOrder = [.trend, .upcoming, .categoryBreakdown, .calendar, .totalPaid]
        XCTAssertEqual(changes(), 6, "面板顺序")

        preferences.subscriptionsViewMode = .list
        XCTAssertEqual(changes(), 7, "列表显示模式")

        preferences.subscriptionsSort = .priceDescending
        XCTAssertEqual(changes(), 8, "排序")

        preferences.trendChartStyle = .line
        XCTAssertEqual(changes(), 9, "趋势图样式")

        preferences.listFilters = SubPreferences.ListFilters(categoryIDs: ["video"])
        XCTAssertEqual(changes(), 10, "筛选")

        preferences.defaultRemindersEnabled = false
        XCTAssertEqual(changes(), 11, "默认提醒开关")

        preferences.defaultReminderDays = 0
        XCTAssertEqual(changes(), 12, "提前天数")

        preferences.reminderHour = 20
        XCTAssertEqual(changes(), 13, "提醒时刻")

        preferences.notificationsEnabled = true
        XCTAssertEqual(changes(), 14, "提醒总开关")
    }

    /// 写成一样的值不算改动：同步「收下云端那一份」经常收下的就是本机本来就有的值，
    /// 少这一道比较就是一次同步一屏重绘。
    func testWritingAnEqualValuePublishesNothing() {
        let preferences = makePreferences()
        preferences.accentHex = "#30D158"
        preferences.defaultReminderDays = 5
        let changes = watch(preferences)

        preferences.accentHex = "#30D158"
        preferences.defaultReminderDays = 5
        preferences.appearance = .system
        preferences.coloredCards = true
        preferences.reminderHour = 9
        preferences.hiddenPanels = []
        XCTAssertEqual(changes(), 0)
    }

    /// 一批连着改（备份恢复、云端整组下发）只发一次通知。
    func testBatchCoalescesIntoOneNotification() {
        let preferences = makePreferences()
        let changes = watch(preferences)
        preferences.batch {
            preferences.accentHex = "#FF9F0A"
            preferences.appearance = .light
            preferences.coloredCards = false
            preferences.defaultCurrency = "JPY"
            preferences.reminderHour = 8
        }
        XCTAssertEqual(changes(), 1, "五个键一次重绘，不是五轮")
    }

    /// 嵌套的批（恢复里又调了某个分组自己的批）仍然只发最外层那一次。
    func testNestedBatchStillPublishesOnce() {
        let preferences = makePreferences()
        let changes = watch(preferences)
        preferences.batch {
            preferences.accentHex = "#63E6E2"
            preferences.batch {
                preferences.defaultCurrency = "EUR"
            }
        }
        XCTAssertEqual(changes(), 1)
    }

    /// 一批里什么都没改成，就不该发通知。
    func testBatchWithNoRealChangeStaysQuiet() {
        let preferences = makePreferences()
        let changes = watch(preferences)
        preferences.batch {
            preferences.accentHex = preferences.accentHex
            preferences.defaultReminderDays = preferences.defaultReminderDays
        }
        XCTAssertEqual(changes(), 0)
    }

    /// 同步记账用的时间戳不算「设置变了」：跟着它喊会让每次真实改动变成两次通知。
    func testRecordingARevisionDoesNotPublish() {
        let preferences = makePreferences()
        let changes = watch(preferences)
        preferences.recordSettingRevision(.reminders)
        preferences.recordSettingRevision(.currency, at: Date())
        XCTAssertEqual(changes(), 0)
    }

    // MARK: - §5.1 偏好这一侧的开关与天数

    /// 新装：默认开提醒、提前 3 天。
    func testFreshInstallDefaultsToRemindingThreeDaysAhead() {
        let preferences = makePreferences()
        XCTAssertTrue(preferences.defaultRemindersEnabled)
        XCTAssertEqual(preferences.defaultReminderDays, 3)
        XCTAssertEqual(preferences.reminderHour, 9)
    }

    /// 调到 0 就是 0（= 扣费当天）。
    ///
    /// 旧 getter 写的是「取出来不大于 0 就返回 3」：步进器调到 0，存进去 0，
    /// 读回来 3 —— 设置页那句说明永远跳回「提前 3 天」，用户以为自己的选择没生效。
    func testZeroDaysStaysZeroAndMeansSameDay() {
        let preferences = makePreferences()
        preferences.defaultRemindersEnabled = true
        preferences.defaultReminderDays = 0
        XCTAssertEqual(preferences.defaultReminderDays, 0)
        XCTAssertTrue(preferences.defaultRemindersEnabled, "天数不兼职表达「不提醒」")
    }

    /// 天数只认开关；开关关掉之后天数照常留着，重新打开回到他原来的选择。
    func testSwitchAndDaysAreIndependent() {
        let preferences = makePreferences()
        preferences.defaultReminderDays = 7
        preferences.defaultRemindersEnabled = false
        XCTAssertEqual(preferences.defaultReminderDays, 7, "关掉提醒不该把他的天数抹平")
        preferences.defaultRemindersEnabled = true
        XCTAssertEqual(preferences.defaultReminderDays, 7)
    }

    /// 越界的天数收进来先夹住：设置页的步进器之外还有备份和云端两条入口。
    func testDaysAreClampedToTheSaneRange() {
        let preferences = makePreferences()
        preferences.defaultReminderDays = 999
        XCTAssertEqual(preferences.defaultReminderDays, 30)
        preferences.defaultReminderDays = -5
        XCTAssertEqual(preferences.defaultReminderDays, 0)
    }

    /// 老用户第一次装上这一版：他当年按过「新建订阅不提醒」（存进去的是 0），
    /// 就得给他「不提醒」，而不是按字面收成「扣费当天提醒」。
    func testLegacyZeroDayPreferenceBecomesSwitchOff() {
        let store = {
            let name = "SauryPreferencesTests.legacy.\(UUID().uuidString)"
            suiteNames.append(name)
            return UserDefaults(suiteName: name)!
        }()
        store.set(0, forKey: "saury.defaultReminderDays")
        let preferences = SubPreferences(defaults: store)
        XCTAssertFalse(preferences.defaultRemindersEnabled, "旧界面上那句话就是「不提醒」")
        XCTAssertEqual(preferences.defaultReminderDays, SubPreferences.fallbackDefaultReminderDays,
                       "天数还回旧版的那个默认值")
    }

    /// 当年存的是非 0（提前 N 天）：什么都没变，不该被「修」成不提醒。
    func testLegacyNonZeroDaysKeepReminding() {
        let store = {
            let name = "SauryPreferencesTests.legacy5.\(UUID().uuidString)"
            suiteNames.append(name)
            return UserDefaults(suiteName: name)!
        }()
        store.set(5, forKey: "saury.defaultReminderDays")
        let preferences = SubPreferences(defaults: store)
        XCTAssertTrue(preferences.defaultRemindersEnabled)
        XCTAssertEqual(preferences.defaultReminderDays, 5)
    }

    /// 补齐只做一次。没做凭据的话，新装用户日后真把天数调成 0（那是「当天提醒」），
    /// 下次启动会被当成旧值「修」成不提醒 —— 修掉用户刚做的选择。
    func testLegacyMigrationRunsExactlyOnce() {
        let store = {
            let name = "SauryPreferencesTests.once.\(UUID().uuidString)"
            suiteNames.append(name)
            return UserDefaults(suiteName: name)!
        }()
        store.set(0, forKey: "saury.defaultReminderDays")
        _ = SubPreferences(defaults: store)
        XCTAssertNotNil(store.object(forKey: SubPreferences.reminderSemanticsMigratedKey),
                        "补齐过一次就要立凭据")

        // 升级之后用户自己选的「当天提醒」（开关开着 + 天数 0）不能被第二次启动改回去。
        let upgraded = SubPreferences(defaults: store)
        upgraded.defaultRemindersEnabled = true
        upgraded.defaultReminderDays = 0
        let relaunched = SubPreferences(defaults: store)
        XCTAssertTrue(relaunched.defaultRemindersEnabled, "哨兵已经立过，不该再动用户的选择")
        XCTAssertEqual(relaunched.defaultReminderDays, 0)
    }

    /// 两个入口对同一个旧值必须给同一个说法。
    /// 备份恢复和云端下发要是各解释一遍，用户会看到「同一份备份在 A 机器上让他别提醒、
    /// 在 B 机器上让他天天提醒」。
    func testLegacyInterpretationIsSharedByEveryEntry() {
        let zero = SubPreferences.legacyReminderDefault(days: 0)
        XCTAssertFalse(zero.enabled, "旧界面上的那句话就是「不提醒」")
        XCTAssertEqual(zero.days, SubPreferences.fallbackDefaultReminderDays)

        let five = SubPreferences.legacyReminderDefault(days: 5)
        XCTAssertTrue(five.enabled)
        XCTAssertEqual(five.days, 5, "提前 N 天照字面接住")

        let one = SubPreferences.legacyReminderDefault(days: 1)
        XCTAssertTrue(one.enabled)
        XCTAssertEqual(one.days, 1)
    }

    // MARK: - §6.2 写这些键要顺带做的事

    /// 同步按组比时间戳。写了键没盖戳，同步只能拿内容猜谁新，
    /// 猜错一次就把用户另一台设备上的设置盖掉了。
    func testReminderAndCurrencyKeysStampTheirGroup() {
        let preferences = makePreferences()
        XCTAssertNil(preferences.settingRevision(.reminders))
        preferences.defaultRemindersEnabled = false
        XCTAssertNotNil(preferences.settingRevision(.reminders))
        preferences.defaultReminderDays = 1
        preferences.reminderHour = 21

        preferences.defaultCurrency = "USD"
        XCTAssertNotNil(preferences.settingRevision(.currency))
        preferences.categories = DefaultCategories.items.filter { $0.id != "other" }
        XCTAssertNotNil(preferences.settingRevision(.categories))
        preferences.paymentMethods = ["支付宝"]
        XCTAssertNotNil(preferences.settingRevision(.paymentMethods))
    }

    /// 提醒这一组的新列要能上云：不带它，另一台设备收下这份之后只能猜。
    func testReminderGroupCarriesTheSwitch() {
        let preferences = makePreferences()
        preferences.defaultRemindersEnabled = false
        preferences.defaultReminderDays = 0
        preferences.reminderHour = 7
        let payload = SyncedSettings.current(for: .reminders, from: preferences)
        XCTAssertEqual(payload.defaultRemindersEnabled, false)
        XCTAssertEqual(payload.defaultReminderDays, 0)
        XCTAssertEqual(payload.reminderHour, 7)

        // 收了再读回来，本机内容必须和云端那份一模一样 —— 不然下一轮又把自己当成本机新改动推上去。
        let other = makePreferences("carry")
        payload.apply(to: other)
        XCTAssertEqual(SyncedSettings.current(for: .reminders, from: other), payload)
    }

    /// 旧云端记录里没有「要不要提醒」这一列：按旧意思补齐，不照字面收成「当天提醒」。
    func testLegacyRemotePayloadIsCompletedWithTheOldMeaning() {
        let legacy = SyncedSettings(defaultReminderDays: 0, reminderHour: 9)
        XCTAssertNil(legacy.defaultRemindersEnabled)
        let preferences = makePreferences("legacy-remote")
        preferences.defaultRemindersEnabled = true
        preferences.defaultReminderDays = 3
        legacy.apply(to: preferences)
        XCTAssertFalse(preferences.defaultRemindersEnabled, "§5.1：不许静默改变提醒规则")
        XCTAssertEqual(preferences.defaultReminderDays, SubPreferences.fallbackDefaultReminderDays)
    }

    /// 补齐出来的那份和云端那一份内容不同，指纹也就不等 ——
    /// 协调器靠这一点决定「重盖时间戳、把本机这份推上去一次」，而不是每次同步都报冲突。
    func testLegacyCompletionMakesTheLocalFingerprintDifferOnce() {
        let legacy = SyncedSettings(defaultReminderDays: 0, reminderHour: 9)
        let preferences = makePreferences("fingerprint")
        legacy.apply(to: preferences)
        let local = SyncedSettings.fingerprint(.reminders, from: preferences)
        XCTAssertNotEqual(local, BackupContainer.sha256(legacy.encoded),
                          "补齐过了就该被发现：这一组要重盖时间戳推一次")

        // 对齐之后再收一次同样的载荷，就该完全相等了（否则冲突会一直报）。
        let aligned = SyncedSettings.current(for: .reminders, from: preferences)
        aligned.apply(to: preferences)
        XCTAssertEqual(SyncedSettings.fingerprint(.reminders, from: preferences),
                       BackupContainer.sha256(aligned.encoded))
    }

    /// 备份恢复：整包收下来只发一次通知，且旧备份的 0 走同一套解释。
    func testBackupRestoreAppliesLegacyReminderIntentInOnePublish() {
        let preferences = makePreferences("restore")
        let changes = watch(preferences)
        var backup = BackupPreferences.current(from: preferences)
        backup.defaultRemindersEnabled = nil
        backup.defaultReminderDays = 0
        backup.accentHex = "#FF375F"
        backup.reminderHour = 20
        backup.apply(to: preferences)
        XCTAssertEqual(changes(), 1, "十几个键的恢复不该变成十几轮重绘")
        XCTAssertFalse(preferences.defaultRemindersEnabled)
        XCTAssertEqual(preferences.reminderHour, 20)
    }

    /// 备份里没带的键保持本机现状：恢复不该顺手把主题色重置成默认。
    func testBackupMissingKeysLeaveTheDeviceAlone() {
        let preferences = makePreferences("missing")
        preferences.accentHex = "#30D158"
        preferences.defaultRemindersEnabled = false
        preferences.defaultReminderDays = 9
        BackupPreferences().apply(to: preferences)
        XCTAssertEqual(preferences.accentHex, "#30D158")
        XCTAssertFalse(preferences.defaultRemindersEnabled)
        XCTAssertEqual(preferences.defaultReminderDays, 9)
    }

    /// 导出文件（V1 形状）里没有「要不要提醒」这一列时按当年的说法解释：
    /// 0 天 = 不提醒。这一条和老库那趟补算（`ReminderIntentBackfill`）、备份恢复必须同口径，
    /// 否则同一份数据从三条路进来会给出两种结论。
    func testExportedSwitchFallsBackToTheOldDayMeaning() {
        func legacy(reminderDays: Int, remindersEnabled: Bool? = nil)
            -> SubscriptionImportExport.ExportedSubscription {
            SubscriptionImportExport.ExportedSubscription(
                name: "Netflix", plan: "", colorHexes: [], priceMinorUnits: 4500,
                currencyCode: "CNY", cycle: "monthly", customMonths: 1, category: "video",
                state: "autoRenew", startDate: Date(timeIntervalSince1970: 1_700_000_000),
                reminderDays: reminderDays, remindersEnabled: remindersEnabled,
                shareEnabled: false, shareHeadcount: 1,
                shareMode: "even", shareMyMinorUnits: 0, paymentMethod: "", notes: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        XCTAssertFalse(legacy(reminderDays: 0).resolvedRemindersEnabled, "旧文件里的 0 是「不提醒」")
        XCTAssertTrue(legacy(reminderDays: 3).resolvedRemindersEnabled)
        XCTAssertFalse(legacy(reminderDays: 3, remindersEnabled: false).resolvedRemindersEnabled,
                       "有这一列就听这一列的，天数只回答「提前几天」")
        XCTAssertTrue(legacy(reminderDays: 0, remindersEnabled: true).resolvedRemindersEnabled,
                      "新口径下 0 天 + 开关开着 = 扣费当天提醒")
    }
}
