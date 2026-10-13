import Foundation
import StoreKit

/// 打赏档位（任务书 §10.4）。
///
/// 一个档位就是一个真实的 StoreKit 产品，`rawValue` 直接是产品 ID ——
/// 页面上那一行、点下去买的那个东西、和 App Store Connect 里配的那条记录，
/// 三者必须是同一个标识。以前是三行写死的「¥8 / ¥22 / ¥38」配一个买断产品，
/// 点哪一行买的都是同一个东西，那是把三个价签贴在一个支付入口上。
enum TipTier: String, CaseIterable, Identifiable, Codable {
    /// 速溶咖啡：最低一档。
    case instant = "com.guofeng.saury.tip.instant"
    /// 冰美式：中间一档，页面上的默认推荐。
    case americano = "com.guofeng.saury.tip.americano"
    /// 冷萃咖啡：最高一档。
    case coldBrew = "com.guofeng.saury.tip.coldbrew"

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .instant: return "☕️"
        case .americano: return "🧋"
        case .coldBrew: return "🫖"
        }
    }

    var title: String {
        switch self {
        case .instant: return "速溶咖啡"
        case .americano: return "冰美式"
        case .coldBrew: return "冷萃咖啡"
        }
    }

    var caption: String {
        switch self {
        case .instant: return "一包速溶冲下去，提神继续敲代码"
        case .americano: return "冰美式续命，Bug 一个个退散"
        case .coldBrew: return "冷萃慢慢滴，功能慢慢磨"
        }
    }
}

/// 一档的报价。价格字符串必须来自 StoreKit（`Product.displayPrice`），
/// 含币种符号和本地化格式，不由 App 自己拼 —— 写死「¥8」在美元区就是错的。
struct TipQuote: Equatable, Identifiable {
    let tier: TipTier
    let displayPrice: String

    var id: String { tier.rawValue }
}

/// 一次购买落下来的结果。分这么细是因为这五种在页面上说的不是同一句话：
/// 取消不是失败，待批准不是成功，验证没过更不能当成成功。
enum TipPurchaseResult: Equatable {
    /// 收据验证通过，钱这件事成立。
    case verified(TipTier)
    /// 用户在系统弹窗上按了取消。
    case cancelled(TipTier)
    /// 待处理：需要家长批准、或条款要先确认。钱还没到账，但也没失败。
    case pending(TipTier)
    /// 买到了但收据验证不过 —— 这一条绝不能记成已支持。
    case unverified(TipTier, reason: String)
    /// 请求本身出错（网络、StoreKit 报错）。
    case failed(TipTier, reason: String)
    /// 这个产品在当前商店没有可售版本。
    case notForSale(TipTier)

    var tier: TipTier {
        switch self {
        case .verified(let t), .cancelled(let t), .pending(let t),
             .unverified(let t, _), .failed(let t, _), .notForSale(let t):
            return t
        }
    }
}

/// 一档在页面上的当前状态。
enum TipStatus: Equatable {
    /// 可以买（报价已就位）。
    case available
    /// 请求在路上，这一档的按钮锁住。
    case buying
    /// 刚验证通过 —— 一句谢谢，然后回到可买：打赏是一次性的，不是买断。
    case thanked
    /// 待批准 / 待确认。
    case pending
    /// 出问题了，带原话。
    case problem(String)
    /// 没有可售产品（报价拿不到，或这个 ID 在当前商店下架）。
    case unavailable
}

/// 打赏页那三档的账本：谁在买、谁买成了、谁报了什么错。
///
/// 做成值类型是故意的：StoreKit 的 `Product` 在测试里造不出来，
/// 但「哪种结果该把哪一档改成什么状态」这件事跟 StoreKit 一点关系都没有，
/// 这一层能整段用 XCTest 逐条问出来（任务书 §12.1 内购那一行）。
struct TipBoard: Equatable {
    private(set) var quotes: [TipTier: TipQuote] = [:]
    private(set) var statuses: [TipTier: TipStatus] = [:]

    /// 三档全没有报价时页面要说「内购暂不可用」，而不是摆三个不能按的按钮。
    var isSellable: Bool { quotes.isEmpty == false }

    func status(of tier: TipTier) -> TipStatus {
        statuses[tier] ?? (quotes[tier] == nil ? .unavailable : .available)
    }

    func quote(of tier: TipTier) -> TipQuote? { quotes[tier] }

    /// 报价到位。已经报过价的档位状态不动，避免每次刷新把「谢谢」抹掉。
    mutating func load(quotes newQuotes: [TipQuote]) {
        for quote in newQuotes {
            quotes[quote.tier] = quote
            if statuses[quote.tier] == nil || statuses[quote.tier] == .unavailable {
                statuses[quote.tier] = .available
            }
        }
        for tier in TipTier.allCases where quotes[tier] == nil {
            statuses[tier] = .unavailable
        }
    }

    /// 起手：只有当前是 `.available` / `.thanked` / `.problem` 的档位能发起。
    /// 返回 false 表示这一下不该再发请求（正在路上、或压根没货）——
    /// 连点两下变成两笔订单是这里要挡掉的事。
    @discardableResult
    mutating func begin(_ tier: TipTier) -> Bool {
        guard quotes[tier] != nil else { return false }
        switch status(of: tier) {
        case .buying: return false
        case .unavailable: return false
        default: break
        }
        statuses[tier] = .buying
        return true
    }

    /// 结果落账。规则只有一条硬线：**只有 `.verified` 能把这一档记成成功**。
    mutating func finish(_ result: TipPurchaseResult) {
        switch result {
        case .verified(let tier):
            statuses[tier] = .thanked
        case .cancelled(let tier):
            // 取消不是失败：回到可买，不弹错误，也不给成功触感。
            statuses[tier] = quotes[tier] == nil ? .unavailable : .available
        case .pending(let tier):
            statuses[tier] = .pending
        case .unverified(let tier, let reason):
            statuses[tier] = .problem("这笔没能确认：\(reason)")
        case .failed(let tier, let reason):
            statuses[tier] = .problem(reason)
        case .notForSale(let tier):
            quotes[tier] = nil
            statuses[tier] = .unavailable
        }
    }

    /// 「谢谢」看完要能收回可买状态（打赏不是一次性买断）。
    mutating func resetAfterThanks(_ tier: TipTier) {
        guard statuses[tier] == .thanked else { return }
        statuses[tier] = quotes[tier] == nil ? .unavailable : .available
    }

    /// 恢复购买之后：StoreKit 认账的档位才标成已支持，其余一律不动。
    /// 空集就是空集 —— 一次性消耗型打赏本来就没有可恢复的内容，
    /// 这里不许把「没查到」写成「都恢复了」。
    mutating func applyEntitlements(_ tiers: Set<TipTier>) {
        for tier in tiers where quotes[tier] != nil {
            statuses[tier] = .thanked
        }
    }

    func tier(inState state: TipStatus) -> [TipTier] {
        TipTier.allCases.filter { status(of: $0) == state }
    }
}

/// 打赏页的控制器。真正的 StoreKit 调用全部关在 `TipSelling` 后面。
@MainActor
final class PurchaseStore: ObservableObject {
    @Published private(set) var board = TipBoard()
    /// 恢复购买之后要告诉用户的那句话（nil = 这一趟没什么要说）。
    @Published private(set) var restoreNotice: String?

    private let seller: TipSelling

    init(seller: TipSelling = StoreKitTipSeller()) { self.seller = seller }

    var isSellable: Bool { board.isSellable }

    func status(of tier: TipTier) -> TipStatus { board.status(of: tier) }

    func quote(of tier: TipTier) -> TipQuote? { board.quote(of: tier) }

    func load() async {
        let quotes = await seller.quotes()
        board.load(quotes: quotes)
    }

    /// 买这一档。同一档的请求在路上时，第二下直接被 `begin` 挡掉。
    func buy(_ tier: TipTier) async {
        guard board.begin(tier) else { return }
        let result = await seller.buy(tier)
        board.finish(result)
        switch result {
        case .verified: SelectionHaptics.success()
        case .pending: SelectionHaptics.impact(.light)
        case .unverified, .failed, .notForSale: SelectionHaptics.error()
        case .cancelled: break   // 用户自己按的取消，什么都不该响。
        }
    }

    /// 恢复购买：把 StoreKit 认账的档位标出来，并如实说明剩下的为什么没恢复。
    func restore() async {
        restoreNotice = nil
        let paid = await seller.purchasedTiers()
        board.applyEntitlements(paid)
        restoreNotice = paid.isEmpty
            ? "没有查到已完成的打赏。打赏是一次性消耗品，本来就没有需要恢复的东西。"
            : "已恢复 \(paid.count) 档的打赏记录。"
    }

    func clearThanks(_ tier: TipTier) { board.resetAfterThanks(tier) }
}

/// 真 StoreKit 那一侧。测试里不会走到这里，所以这一份只负责把结果翻译干净。
struct StoreKitTipSeller: TipSelling {
    func quotes() async -> [TipQuote] {
        let ids = TipTier.allCases.map(\.rawValue)
        guard let products = try? await Product.products(for: ids) else { return [] }
        return products.compactMap { product in
            guard let tier = TipTier(rawValue: product.id) else { return nil }
            return TipQuote(tier: tier, displayPrice: product.displayPrice)
        }
    }

    func buy(_ tier: TipTier) async -> TipPurchaseResult {
        do {
            let products = try await Product.products(for: [tier.rawValue])
            guard let product = products.first else { return .notForSale(tier) }
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    return .verified(tier)
                case .unverified(_, let error):
                    // 收据没验过：这一笔不算成功，也不替用户吞掉。
                    return .unverified(tier, reason: error.localizedDescription)
                }
            case .userCancelled:
                return .cancelled(tier)
            case .pending:
                return .pending(tier)
            @unknown default:
                return .failed(tier, reason: "StoreKit 返回了一个不认识的购买结果")
            }
        } catch {
            return .failed(tier, reason: error.localizedDescription)
        }
    }

    func purchasedTiers() async -> Set<TipTier> {
        var paid: Set<TipTier> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  let tier = TipTier(rawValue: transaction.productID) else { continue }
            paid.insert(tier)
        }
        return paid
    }
}

/// 打赏页要问 StoreKit 的三件事。抽出来是为了让上面那台状态机能被逐条问出来，
/// 不是为了给实现留余地 —— 生产实现只有 `StoreKitTipSeller` 一个。
protocol TipSelling: Sendable {
    func quotes() async -> [TipQuote]
    func buy(_ tier: TipTier) async -> TipPurchaseResult
    func purchasedTiers() async -> Set<TipTier>
}
