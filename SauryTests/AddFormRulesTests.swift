import XCTest
@testable import Saury

/// 新增/编辑表单的判断层：键盘怎么走、哪一格该说什么、什么时候才准保存。
///
/// View 只负责把这里的结果显示出来，规则本身被直接问一遍（任务书 §7.1）。
final class AddFormRulesTests: XCTestCase {

    private let english = MoneyParsing.Separators.english
    private var calendar: Calendar { BillingMath.calendar }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func validate(_ input: AddFormInput) -> AddFormReport {
        AddFormValidator.validate(input, calendar: calendar, separators: english)
    }

    // MARK: - 键盘走位

    func testTheChainWalksTheFormTopToBottom() {
        let chain = FormFieldChain(showingShare: false)
        XCTAssertEqual(chain.fields, [.name, .price, .plan, .notes])
        XCTAssertEqual(chain.next(of: .name), .price)
        XCTAssertEqual(chain.previous(of: .price), .name)
        // 「我的份额」没展开时，从套餐往下直接就是备注。
        XCTAssertEqual(chain.next(of: .plan), .notes)
    }

    func testTheShareFieldJoinsTheChainOnlyWhenItIsOnScreen() {
        let chain = FormFieldChain(showingShare: true)
        XCTAssertEqual(chain.fields, [.name, .price, .plan, .share, .notes])
        XCTAssertEqual(chain.next(of: .plan), .share)
        XCTAssertEqual(chain.next(of: .share), .notes)
    }

    func testTheEndsOfTheChainDoNotWrapAround() {
        let chain = FormFieldChain(showingShare: true)
        XCTAssertNil(chain.previous(of: .name))
        XCTAssertNil(chain.next(of: .notes))
    }

    func testThePositionReadoutCountsOnlyFieldsOnScreen() {
        XCTAssertEqual(FormFieldChain(showingShare: false).position(of: .plan), "套餐 3/4")
        XCTAssertEqual(FormFieldChain(showingShare: true).position(of: .plan), "套餐 3/5")
        // 不在链子上的格子不该报出位置。
        XCTAssertNil(FormFieldChain(showingShare: false).position(of: .share))
    }

    func testTheDecimalFieldsAreTheOnesThatNeedTheToolbar() {
        // 数字键盘没有回车键：这两格只能靠键盘上方的工具条离开。
        XCTAssertTrue(FormField.price.needsToolbarToLeave)
        XCTAssertTrue(FormField.share.needsToolbarToLeave)
        XCTAssertFalse(FormField.name.needsToolbarToLeave)
    }

    // MARK: - 必填与字段级提示

    func testAFreshFormIsNotSavableButStaysQuietUntilAsked() {
        let report = validate(AddFormInput())
        XCTAssertFalse(report.canSave)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertNil(report.message(for: .price, afterSubmit: false))
        XCTAssertEqual(report.message(for: .price, afterSubmit: true), "填个金额")
    }

    func testANameOfJustSpacesIsNoName() {
        let report = validate(AddFormInput(name: "   \n "))
        XCTAssertEqual(report.message(for: .name, afterSubmit: true), "给订阅起个名字")
        XCTAssertFalse(report.canSave)
    }

    func testAMalformedAmountIsNamedRightAway() {
        let report = validate(AddFormInput(name: "iCloud", priceText: "12a"))
        XCTAssertEqual(report.issues[.price], MoneyParsing.Failure.notANumber.message)
        XCTAssertNil(report.parsedPrice)
        XCTAssertFalse(report.canSave)
        // 当场就说，不用等按下那一次。
        XCTAssertEqual(report.message(for: .price, afterSubmit: false),
                       MoneyParsing.Failure.notANumber.message)
    }

    func testANegativeAmountIsRefusedByName() {
        let report = validate(AddFormInput(name: "iCloud", priceText: "-5"))
        XCTAssertEqual(report.issues[.price], MoneyParsing.Failure.negative.message)
    }

    /// 换币种不许偷偷改用户填的数字（§7.1 第 6 条）：
    /// 说不通的位数要指着金额说，而不是四舍五入成一个「看起来一样」的数。
    func testSwitchingToADecimalFreeCurrencyPointsAtTheAmountInsteadOfRoundingIt() {
        let inCNY = validate(AddFormInput(name: "iCloud", priceText: "12.34", currencyCode: "CNY"))
        XCTAssertEqual(inCNY.parsedPrice?.minorUnits, 1234)
        XCTAssertTrue(inCNY.canSave)

        let inJPY = validate(AddFormInput(name: "iCloud", priceText: "12.34", currencyCode: "JPY"))
        XCTAssertNil(inJPY.parsedPrice)
        XCTAssertEqual(inJPY.issues[.price], MoneyParsing.Failure.tooManyFractionDigits(allowed: 0).message)

        // 整数金额换币种照常能存，数字本身一位没动。
        let wholeYen = validate(AddFormInput(name: "iCloud", priceText: "1200", currencyCode: "JPY"))
        XCTAssertEqual(wholeYen.parsedPrice?.minorUnits, 120000)
        XCTAssertTrue(wholeYen.canSave)
    }

    // MARK: - 分摊：静默存 0 那一坑

    func testABlankCustomShareIsAskedOnSubmit() {
        let report = validate(AddFormInput(name: "Netflix", priceText: "25",
                                           shareEnabled: true, shareMode: .custom, shareText: ""))
        XCTAssertFalse(report.canSave)
        XCTAssertNil(report.message(for: .share, afterSubmit: false))
        XCTAssertEqual(report.message(for: .share, afterSubmit: true), "填一下你每期付多少")
    }

    /// 「我出的」读不通以前会当 0 存进库：现在必须拦下来并指名这一格。
    func testAnUnreadableShareNeverBecomesASilentZero() {
        let report = validate(AddFormInput(name: "Netflix", priceText: "25",
                                           shareEnabled: true, shareMode: .custom, shareText: "abc"))
        XCTAssertNil(report.parsedShare)
        XCTAssertEqual(report.issues[.share], MoneyParsing.Failure.notANumber.message)
        XCTAssertFalse(report.canSave)
    }

    func testAShareBiggerThanTheBillIsRefused() {
        let report = validate(AddFormInput(name: "Netflix", priceText: "25",
                                           shareEnabled: true, shareMode: .custom, shareText: "30"))
        let total = Money(minorUnits: 2500, currencyCode: "CNY").formatted
        XCTAssertEqual(report.issues[.share], "不能超过总额 \(total)")
        XCTAssertFalse(report.canSave)
    }

    func testAShareEqualToTheBillIsFine() {
        let report = validate(AddFormInput(name: "Netflix", priceText: "25",
                                           shareEnabled: true, shareMode: .custom, shareText: "25"))
        XCTAssertNil(report.issues[.share])
        XCTAssertTrue(report.canSave)
    }

    func testZeroShareIsALegitimateAnswer() {
        // 这期由别人垫付也是真实情况：0 是填了，不是没填。
        let report = validate(AddFormInput(name: "Netflix", priceText: "25",
                                           shareEnabled: true, shareMode: .custom, shareText: "0"))
        XCTAssertEqual(report.parsedShare?.minorUnits, 0)
        XCTAssertTrue(report.canSave)
    }

    /// 分摊收起来之后这一格不存在，就不能再拿它拦保存。
    func testAHiddenShareFieldStopsBlockingTheSave() {
        let open = validate(AddFormInput(name: "Netflix", priceText: "25",
                                         shareEnabled: true, shareMode: .custom, shareText: "abc"))
        XCTAssertFalse(open.canSave)

        let closed = validate(AddFormInput(name: "Netflix", priceText: "25",
                                           shareEnabled: false, shareMode: .custom, shareText: "abc"))
        XCTAssertNil(closed.issues[.share])
        XCTAssertTrue(closed.canSave)
        XCTAssertNil(closed.parsedShare)
    }

    // MARK: - 起止日期

    func testAnEndDateBeforeTheStartDateIsRefused() {
        let report = validate(AddFormInput(name: "iCloud", priceText: "68",
                                           startDate: day(2026, 3, 10),
                                           endDateEnabled: true,
                                           endDate: day(2026, 3, 9)))
        XCTAssertEqual(report.dateIssue, "结束日期比开始日期还早")
        XCTAssertFalse(report.canSave)
    }

    /// 结束日期当天订阅还算数（§5.3），所以同一天不是错。
    func testTheEndDateOnTheSameDayAsTheStartIsStillValid() {
        let sameDay = day(2026, 3, 10)
        let report = validate(AddFormInput(name: "iCloud", priceText: "68",
                                           startDate: calendar.date(byAdding: .hour, value: 14, to: sameDay)!,
                                           endDateEnabled: true,
                                           endDate: calendar.date(byAdding: .hour, value: 3, to: sameDay)!))
        XCTAssertNil(report.dateIssue)
        XCTAssertTrue(report.canSave)
    }

    func testAnEndDateThatIsTurnedOffIsNotJudged() {
        let report = validate(AddFormInput(name: "iCloud", priceText: "68",
                                           startDate: day(2026, 3, 10),
                                           endDateEnabled: false,
                                           endDate: day(2020, 1, 1)))
        XCTAssertNil(report.dateIssue)
        XCTAssertTrue(report.canSave)
    }

    // MARK: - 按下保存后先修哪儿

    func testTheFirstFieldToFixPrefersWhatIsWrongOverWhatIsBlank() {
        let report = validate(AddFormInput(priceText: "1x",
                                           shareEnabled: true, shareMode: .custom, shareText: ""))
        // 名称和份额空着（缺）、金额填错（错）：先指错的那一格，再按屏上顺序补缺。
        XCTAssertEqual(report.fieldsToFix, [.price, .name, .share])
    }

    func testTheFieldsToFixCoverEverythingWhenNothingIsFilledIn() {
        XCTAssertEqual(validate(AddFormInput()).fieldsToFix, [.name, .price])
    }

    // MARK: - 没保存的改动

    private var baseDraft: SubscriptionDraft {
        var draft = SubscriptionDraft(id: UUID())
        draft.name = "iCloud"
        draft.priceMinorUnits = 6800
        return draft
    }

    func testNothingCountsAsChangedBeforeTheFormHasLoaded() {
        let tracker = UnsavedChangesTracker()
        XCTAssertFalse(tracker.hasAnchor)
        XCTAssertFalse(tracker.isDirty(baseDraft))
    }

    func testTypingAndThenUndoingLeavesTheFormClean() {
        var tracker = UnsavedChangesTracker()
        let loaded = baseDraft
        tracker.anchor(loaded)
        XCTAssertFalse(tracker.isDirty(loaded))

        var edited = loaded
        edited.priceMinorUnits = 8800
        XCTAssertTrue(tracker.isDirty(edited))
        XCTAssertFalse(tracker.isDirty(loaded))
    }

    /// 换图标、改周期这类只动一个字段的修改也必须被认出来，否则取消就静默丢了改动。
    func testEveryEditableFieldTheFormOwnsIsVisibleToTheTracker() {
        var tracker = UnsavedChangesTracker()
        let loaded = baseDraft
        tracker.anchor(loaded)

        let edits: [(inout SubscriptionDraft) -> Void] = [
            { $0.name = "改名" },
            { $0.priceMinorUnits += 100 },
            { $0.cycle = .yearly },
            { $0.endDate = Date(timeIntervalSince1970: 1) },
            { $0.reminderDays = 7 },
            { $0.shareMyMinorUnits = 100 },
            { $0.iconSymbolName = "cloud" },
            { $0.colorSpec = CardColorSpec(hexes: ["#FF0000"]) },
            { $0.notes = "备注" },
            { $0.paymentMethod = "支付宝" },
        ]
        for edit in edits {
            var edited = loaded
            edit(&edited)
            XCTAssertTrue(tracker.isDirty(edited), "这一处改动没被认出来")
        }
    }

    /// 保存成功之后取消不该再问一遍：锚已经跟着新数据走了。
    func testSavingMovesTheAnchorSoCancellingAsksNoMore() {
        var tracker = UnsavedChangesTracker()
        let loaded = baseDraft
        tracker.anchor(loaded)

        var saved = loaded
        saved.priceMinorUnits = 8800
        XCTAssertTrue(tracker.isDirty(saved))

        tracker.anchor(saved)
        XCTAssertFalse(tracker.isDirty(saved))
        // 但真正的再一次改动还是会问。
        var again = saved
        again.plan = "标准版"
        XCTAssertTrue(tracker.isDirty(again))
    }
}
