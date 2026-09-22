import Foundation

/// 位置清单（方案 §33）。物品上的 `location` 是自由文本，这里管的是
/// 「建议填哪些」：添加表单的候选、首页位置分组的展示顺序都来自它。
/// 增删改排序都走 `replace`——清单只有一份真相，不给每个操作各留一条路径。
/// 删掉一个位置不会改动任何物品：那是用户的账，不是清单的账。
enum LocationCatalog {
    static let builtIn = ["冰箱", "冷冻室", "厨房", "储物柜", "药箱", "浴室", "卧室", "办公室"]

    private static let key = "qijian.locations"

    static var all: [String] {
        (UserDefaults.standard.array(forKey: key) as? [String]) ?? builtIn
    }

    static func replace(_ value: [String]) {
        let cleaned = value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        UserDefaults.standard.set(cleaned.filter { seen.insert($0).inserted }, forKey: key)
    }

    static func restoreDefaults() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// 物品实际用到的位置，按清单顺序排；不在清单里的追加在后面。
    static func usedLocations(in items: [ExpiryItem]) -> [String] {
        var seen = Set<String>()
        let used = items.compactMap { item -> String? in
            guard let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !location.isEmpty else { return nil }
            return seen.insert(location).inserted ? location : nil
        }
        let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1, $0) })
        return used.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
    }
}

/// 常用单位（方案 §32）。只是候选，用户可以填任何字符串：
/// 「一次一片」和「一瓶 500ml」不共用一套说法。
enum UnitCatalog {
    static let builtIn = ["个", "盒", "瓶", "袋", "包", "片", "支", "罐", "kg", "g", "L", "ml"]
}
