import Foundation
import StoreKit

@MainActor
final class PurchaseStore: ObservableObject {
    static let lifetimeProductID = "com.guofeng.saury.lifetime"
    @Published private(set) var product: Product?
    @Published private(set) var isPurchased = false

    func load() async {
        product = try? await Product.products(for: [Self.lifetimeProductID]).first
        await updateEntitlement()
    }

    func purchase(_ product: Product) async {
        guard let result = try? await product.purchase() else { return }
        switch result {
        case .success(let verification):
            if case .verified = verification { isPurchased = true }
        default: break
        }
    }

    private func updateEntitlement() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.lifetimeProductID {
                isPurchased = true
            }
        }
    }
}
