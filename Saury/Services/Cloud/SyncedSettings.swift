import Foundation

/// 参与同步的偏好分组。一组一条云端记录：
/// 「A 设备改了分类」不该把 B 设备刚挑好的默认币种盖掉，
/// 整份设置当一个同步单元的话，这种互相覆盖每天都会发生。
enum SyncedSettingGroup: String, CaseIterable, Identifiable {
    case categories
    case paymentMethods
    case currency
    case reminders

    var id: String { rawValue }
    /// 云端记录的稳定名就是这个键。
    var recordName: String { rawValue }

    var title: String {
        switch self {
        case .categories: return "自定义分类"
        case .paymentMethods: return "支付方式"
        case .currency: return "基础货币"
        case .reminders: return "默认提醒"
        }
    }
}

/// 一组偏好的内容。没填的键表示「这一组不含它」，同步写回时不动本机那一项 ——
/// 和备份里 `BackupPreferences` 的规矩一致：缺字段绝不拿默认值去盖用户挑过的设置。
struct SyncedSettings: Codable, Equatable {
    var categories: [SubscriptionCategory]?
    var paymentMethods: [String]?
    var defaultCurrency: String?
    var commonCurrencies: [String]?
    var onlyCommonCurrencies: Bool?
    var showOriginalCurrency: Bool?
    var defaultReminderDays: Int?
    var defaultRemindersEnabled: Bool?
    var reminderHour: Int?

    enum CodingKeys: String, CodingKey {
        case categories, paymentMethods, defaultCurrency, commonCurrencies
        case onlyCommonCurrencies, showOriginalCurrency, defaultRemindersEnabled
        case defaultReminderDays, reminderHour
    }

    /// 逐组只填自己那几项，其余留 `nil`（= 这一组不含它，写回本机时不动那一项）。
    /// 得手写：下面那个 `init?(data:)` 一声明，Swift 就不再给成员初始化器了。
    init(categories: [SubscriptionCategory]? = nil,
         paymentMethods: [String]? = nil,
         defaultCurrency: String? = nil,
         commonCurrencies: [String]? = nil,
         onlyCommonCurrencies: Bool? = nil,
         showOriginalCurrency: Bool? = nil,
         defaultRemindersEnabled: Bool? = nil,
         defaultReminderDays: Int? = nil,
         reminderHour: Int? = nil) {
        self.categories = categories
        self.paymentMethods = paymentMethods
        self.defaultCurrency = defaultCurrency
        self.commonCurrencies = commonCurrencies
        self.onlyCommonCurrencies = onlyCommonCurrencies
        self.showOriginalCurrency = showOriginalCurrency
        self.defaultRemindersEnabled = defaultRemindersEnabled
        self.defaultReminderDays = defaultReminderDays
        self.reminderHour = reminderHour
    }

    @MainActor
    static func current(for group: SyncedSettingGroup, from preferences: SubPreferences) -> SyncedSettings {
        switch group {
        case .categories:
            return SyncedSettings(categories: preferences.categories)
        case .paymentMethods:
            return SyncedSettings(paymentMethods: preferences.paymentMethods)
        case .currency:
            return SyncedSettings(defaultCurrency: preferences.defaultCurrency,
                                  commonCurrencies: preferences.commonCurrencies,
                                  onlyCommonCurrencies: preferences.onlyCommonCurrencies,
                                  showOriginalCurrency: preferences.showOriginalCurrency)
        case .reminders:
            return SyncedSettings(defaultRemindersEnabled: preferences.defaultRemindersEnabled,
                                  defaultReminderDays: preferences.defaultReminderDays,
                                  reminderHour: preferences.reminderHour)
        }
    }

    /// 这一组的内容指纹。用来判「本机到底动没动过」，比逐字段比较省事也不会漏。
    @MainActor
    static func fingerprint(_ group: SyncedSettingGroup, from preferences: SubPreferences) -> String {
        BackupContainer.sha256(Data(current(for: group, from: preferences).encoded))
    }

    var encoded: Data { (try? JSONEncoder.backup.encode(self)) ?? Data() }

    init?(data: Data) {
        guard let decoded = try? JSONDecoder.backup.decode(SyncedSettings.self, from: data),
              decoded.hasAnyValue else { return nil }
        self = decoded
    }

    private var hasAnyValue: Bool {
        categories != nil || paymentMethods != nil || defaultCurrency != nil
            || commonCurrencies != nil || onlyCommonCurrencies != nil || showOriginalCurrency != nil
            || defaultRemindersEnabled != nil || defaultReminderDays != nil || reminderHour != nil
    }

    /// 写回本机：payload 里有的键就照写，没有的键保持本机现在的值。
    /// 这里故意不再加「空数组就跳过」这类二次判断 —— 一组的 payload 永远由
    /// `current(for:)` 把这一组的键填满，那次跳过会把用户「把自定义分类删空」
    /// 这个真实状态咽掉，下一轮两边时间相同、内容不同，就被判成冲突反复报出来。
    ///
    /// 唯一的例外是提醒那一组的旧载荷：这一版之前云端没有「要不要提醒」这一列，
    /// 而那时 `defaultReminderDays == 0` 在设置页上写的是「新建订阅不提醒」。
    /// 照字面收下来就成了「扣费当天提醒」—— 用户当年选的那句「不提醒」被改成了
    /// 天天吵（§5.1 不许静默改变提醒规则）。所以缺这一列就按旧意思补齐。
    /// 补齐之后本机这份和云端那份内容不同，协调器会给这组重盖时间戳、把这一版推上去一次，
    /// 两边就此对齐；不然每次同步都会报一次「同一时刻两边各有一份」。
    @MainActor
    func apply(to preferences: SubPreferences) {
        preferences.batch {
            if let categories { preferences.categories = categories }
            if let paymentMethods { preferences.paymentMethods = paymentMethods }
            if let defaultCurrency { preferences.defaultCurrency = defaultCurrency }
            if let commonCurrencies { preferences.commonCurrencies = commonCurrencies }
            if let onlyCommonCurrencies { preferences.onlyCommonCurrencies = onlyCommonCurrencies }
            if let showOriginalCurrency { preferences.showOriginalCurrency = showOriginalCurrency }
            if let defaultRemindersEnabled { preferences.defaultRemindersEnabled = defaultRemindersEnabled }
            if let defaultReminderDays {
                if self.defaultRemindersEnabled == nil {
                    let intent = SubPreferences.legacyReminderDefault(days: defaultReminderDays)
                    preferences.defaultRemindersEnabled = intent.enabled
                    preferences.defaultReminderDays = intent.days
                } else {
                    preferences.defaultReminderDays = defaultReminderDays
                }
            }
            if let reminderHour { preferences.reminderHour = reminderHour }
        }
    }
}
