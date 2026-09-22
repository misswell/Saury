import Foundation
import SwiftData

@MainActor
enum DemoDataSeeder {
    static func seedIfNeeded(in context: ModelContext) {
        #if DEBUG
        let existing = (try? context.fetch(FetchDescriptor<RenewalItem>())) ?? []
        guard existing.isEmpty, !UserDefaults.standard.bool(forKey: "qijian.didSeedDemoData") else { return }
        RenewalItem.previewItems().forEach(context.insert)
        try? context.save()
        UserDefaults.standard.set(true, forKey: "qijian.didSeedDemoData")
        #endif
    }
}
