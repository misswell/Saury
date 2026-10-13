import Foundation

/// 表单里能被键盘走到、也能被指错的格子。
///
/// 声明顺序就是屏上从上到下的顺序，`下一项` 照着它走。
enum FormField: String, CaseIterable, Hashable {
    case name
    case price
    case plan
    case share
    case notes

    var title: String {
        switch self {
        case .name: return "名称"
        case .price: return "金额"
        case .plan: return "套餐"
        case .share: return "我的份额"
        case .notes: return "备注"
        }
    }

    /// 数字键盘没有回车键：这两格只能靠键盘上方的工具条换格或收起。
    var needsToolbarToLeave: Bool { self == .price || self == .share }
}

/// 键盘「上一项 / 下一项」走的格子序列。
///
/// 「我的份额」只有展开分摊并选成自定义份额才存在，藏起来的时候必须从链子上摘掉 ——
/// 否则按下下一项会跳到一个屏上根本没有的格子，焦点丢了，看起来就是点了没反应。
struct FormFieldChain: Equatable {
    let fields: [FormField]

    init(showingShare: Bool) {
        fields = FormField.allCases.filter { $0 != .share || showingShare }
    }

    func index(of field: FormField) -> Int? { fields.firstIndex(of: field) }

    func next(of field: FormField) -> FormField? {
        guard let index = index(of: field), index + 1 < fields.count else { return nil }
        return fields[index + 1]
    }

    func previous(of field: FormField) -> FormField? {
        guard let index = index(of: field), index > 0 else { return nil }
        return fields[index - 1]
    }

    /// 状态条上那句「金额 2/5」：让用户知道自己在链子的哪一段、还能不能走。
    func position(of field: FormField) -> String? {
        guard let index = index(of: field) else { return nil }
        return "\(field.title) \(index + 1)/\(fields.count)"
    }
}

/// 表单此刻的原始输入。
///
/// 这里存的是**文本**而不是金额：草稿会把读不通的金额压成 0，
/// 「我出的」静默存进 0 就是这么来的（任务书 §7.1 第 9 条）。
/// 校验必须先看见用户到底打了什么。
struct AddFormInput {
    var name = ""
    var priceText = ""
    var currencyCode = "CNY"
    var shareEnabled = false
    var shareMode: ShareMode = .even
    var shareText = ""
    var startDate = Date()
    var endDateEnabled = false
    var endDate = Date().addingTimeInterval(365 * 86400)
}

/// 一份表单的检查结果。分三类，显示时机不一样。
struct AddFormReport: Equatable {
    /// 填的内容本身不对 —— 当场就说，不用等按下保存。
    var issues: [FormField: String] = [:]
    /// 必填但还空着 —— 只在按下保存那一次拿出来问，平时不碎碎念。
    var missing: [FormField: String] = [:]
    /// 开始/结束日期打架。它不是键盘格子，所以单独放，显示在结束日期那行下面。
    var dateIssue: String?
    var parsedPrice: Money?
    var parsedShare: Money?

    var canSave: Bool { issues.isEmpty && missing.isEmpty && dateIssue == nil }

    /// 按下保存后要引导的格子：内容错的优先，其次才是空着的必填。
    /// 一次只指一个地方，用户修完再按就会看到下一个。
    var fieldsToFix: [FormField] {
        let problem = FormField.allCases.filter { issues[$0] != nil }
        let blank = FormField.allCases.filter { missing[$0] != nil }
        return problem + blank
    }

    func message(for field: FormField, afterSubmit: Bool) -> String? {
        issues[field] ?? (afterSubmit ? missing[field] : nil)
    }
}

/// 「有没有没保存的改动」的唯一判断处。
///
/// 打开表单时定锚，之后每一份草稿都跟这个锚比：
/// * 改完又改回去 —— 不算脏，用户确实没留下新东西；
/// * 保存成功 —— 重新定锚，这时候取消不该再问一遍（§7.1 第 10 条）。
struct UnsavedChangesTracker {
    private(set) var baseline: SubscriptionDraft?

    /// 锚是否已经落下。`onAppear` 靠它决定「这是不是一次全新的加载」。
    var hasAnchor: Bool { baseline != nil }

    mutating func anchor(_ draft: SubscriptionDraft) { baseline = draft }

    /// 锚还没落下（第一帧、`onAppear` 还没跑）时一律说「没有改动」，
    /// 免得页面一打开就把手势禁用掉。
    func isDirty(_ draft: SubscriptionDraft) -> Bool { baseline != nil && baseline != draft }
}

enum AddFormValidator {
    static func validate(_ input: AddFormInput,
                         calendar: Calendar = BillingMath.calendar,
                         separators: MoneyParsing.Separators = .current) -> AddFormReport {
        var report = AddFormReport()

        if input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report.missing[.name] = "给订阅起个名字"
        }

        // 币种决定小数位上限：换币种不动用户填的数字，只是当场说清这一位对不对（§7.1 第 6 条）。
        switch MoneyParsing.parse(input.priceText, currencyCode: input.currencyCode, separators: separators) {
        case .success(let money):
            report.parsedPrice = money
        case .failure(.empty):
            report.missing[.price] = MoneyParsing.Failure.empty.message
        case .failure(let failure):
            report.issues[.price] = failure.message
        }

        if input.shareEnabled, input.shareMode == .custom {
            switch MoneyParsing.parse(input.shareText, currencyCode: input.currencyCode, separators: separators) {
            case .success(let money):
                report.parsedShare = money
                if let total = report.parsedPrice, money.minorUnits > total.minorUnits {
                    report.issues[.share] = "不能超过总额 \(total.formatted)"
                }
            case .failure(.empty):
                report.missing[.share] = "填一下你每期付多少"
            case .failure(let failure):
                report.issues[.share] = failure.message
            }
        }

        if input.endDateEnabled {
            let start = calendar.startOfDay(for: input.startDate)
            let end = calendar.startOfDay(for: input.endDate)
            // 结束日期当天订阅还算数（§5.3），所以同一天不是错。
            if end < start { report.dateIssue = "结束日期比开始日期还早" }
        }

        return report
    }
}
