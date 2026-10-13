import Foundation
import os

/// 汇率。相对基准（默认人民币）给出「1 单位外币 = N 元本币」——
/// 实际存的是「1 单位该币 = N 美元」，换算时经过美元一跳，增删币种都不用改表。
@MainActor
final class ExchangeRateStore: ObservableObject {
    static let shared = ExchangeRateStore()

    private static let logger = Logger(subsystem: "com.guofeng.saury", category: "rates")
    private static let ratesKey = "saury.ratesPerUSD"
    private static let updatedKey = "saury.ratesUpdatedAt"
    /// 兜底汇率：拉不到网络时也能折算，数字不一定准但不至于归零。
    private static let fallbackPerUSD: [String: Double] = [
        "USD": 1, "CNY": 7.12, "EUR": 0.92, "GBP": 0.78, "JPY": 152.0, "KRW": 1360,
        "HKD": 7.8, "TWD": 32.2, "AUD": 1.52, "NZD": 1.66, "CAD": 1.37, "CHF": 0.88,
        "SGD": 1.34, "THB": 35.8, "MYR": 4.45, "VND": 25400, "PHP": 57.5, "IDR": 15900,
        "INR": 84.0, "RUB": 92.0, "TRY": 34.2, "BRL": 5.55, "MXN": 19.6, "ARS": 1010,
        "CLP": 950, "COP": 4050, "AED": 3.67, "SAR": 3.75, "QAR": 3.64, "ILS": 3.7,
        "EGP": 48.5, "ZAR": 17.6, "NGN": 1650, "SEK": 10.5, "NOK": 10.8, "DKK": 6.87,
        "PLN": 3.95, "CZK": 23.2, "HUF": 362, "RON": 4.58, "UAH": 41.3, "BDT": 119,
        "PKR": 278, "BOB": 6.91, "UYU": 40.2
    ]

    @Published private(set) var ratesPerUSD: [String: Double]
    @Published private(set) var updatedAt: Date?
    @Published var isRefreshing = false

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.dictionary(forKey: Self.ratesKey) as? [String: Double], !raw.isEmpty {
            ratesPerUSD = raw
        } else {
            ratesPerUSD = Self.fallbackPerUSD
        }
        updatedAt = defaults.object(forKey: Self.updatedKey) as? Date
    }

    /// 换算表：从任意币种折到任意币种的乘数（目标 = 原值 × rates[to] / rates[from]）。
    /// 这里直接暴露「每美元」表，`Money.converting` 按需要取。
    var rates: [String: Double] { ratesPerUSD }

    /// 距上次成功更新超过 24 小时才拉一次，避免每次回前台都打网络。
    func refreshIfStale() async {
        if let updatedAt, Date().timeIntervalSince(updatedAt) < 24 * 3600 {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://open.er-api.com/v6/latest/USD")!)
            struct Payload: Decodable { let rates: [String: Double] }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard !payload.rates.isEmpty else { return }
            ratesPerUSD = payload.rates
            updatedAt = Date()
            UserDefaults.standard.set(payload.rates, forKey: Self.ratesKey)
            UserDefaults.standard.set(updatedAt, forKey: Self.updatedKey)
            Self.logger.info("汇率已更新：\(payload.rates.count) 个币种")
        } catch {
            Self.logger.error("刷新汇率失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func lastUpdatedText() -> String {
        guard let updatedAt else { return "从未更新" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: updatedAt)
    }
}
