import Foundation

struct ExternalRenewalDraft: Codable {
    var name: String
    var amountMinorUnits: Int?
    var currencyCode: String
    var renewalDate: Date?
    var cycle: RenewalCycle?
    var source: String
}

enum ExternalInputStore {
    private static let suiteName = "group.com.guofeng.saury"
    private static let key = "qijian.externalRenewalDraft"

    private static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    static func store(_ draft: ExternalRenewalDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: key)
    }

    @MainActor
    static func consume() -> ExternalRenewalDraft? {
        guard let data = defaults.data(forKey: key), let draft = try? JSONDecoder().decode(ExternalRenewalDraft.self, from: data) else { return nil }
        defaults.removeObject(forKey: key)
        return draft
    }
}
