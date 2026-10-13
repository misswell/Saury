import Foundation

/// 墓碑：「某条东西确实被删掉了」这件事的凭据。
///
/// 为什么非要单独记一笔：设备 A 删了一条订阅，设备 B 那会儿离线、手里还留着
/// 活的那一条。等 B 恢复上线，只看库里那一条它会认为「我这份更新」于是整条推回去 ——
/// 订阅就在 A 上复活了。墓碑让同步两边都先问一句「这条是不是已经被判过死刑」，
/// 判过的就不许作为活记录上传，本机那一条也只进回收站、不硬删（还能捞回来）。
///
/// 存在偏好里而不是库里：彻底删除会把行从库里拿走，行自身留不下证据；
/// 而这份证据必须活过「回收站清空」和这一次进程。
@MainActor
final class SyncTombstoneLog {
    static let shared = SyncTombstoneLog()

    /// 墓碑保留期。超过这个时间的删除凭据从云端连目标记录一起清掉 ——
    /// 不留一辈子，否则「重装 App 想从头再来」会被三年前的删除记录管着。
    /// 离线超过这个时间才回来的设备，删掉的那条有可能复活：
    /// 这个数字是这条风险的边界，写在 `Docs/CLOUD_SYNC.md` 里。
    static let retention: TimeInterval = 180 * 24 * 60 * 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: - 读写

    func record(kind: CloudRecordKind, name: String, at: Date) {
        var log = entries(for: kind)
        log[name] = at.timeIntervalSince1970
        write(log, for: kind)
    }

    func date(for kind: CloudRecordKind, name: String) -> Date? {
        guard let value = entries(for: kind)[name] else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    func entries(for kind: CloudRecordKind) -> [String: Double] {
        (defaults.dictionary(forKey: key(for: kind)) as? [String: Double]) ?? [:]
    }

    /// 用户亲手「从回收站恢复」= 明确的、比墓碑更近的意图。撤掉这一条的死刑凭据，
    /// 下一次同步它才允许作为活记录推上去。别的任何路径都不许撤墓碑。
    func pardon(kind: CloudRecordKind, name: String) {
        var log = entries(for: kind)
        guard log.removeValue(forKey: name) != nil else { return }
        write(log, for: kind)
    }

    func forgetExpired(before cutoff: Date) -> [Marker] {
        var expired: [Marker] = []
        for kind in [CloudRecordKind.subscription, .event] {
            let threshold = cutoff.timeIntervalSince1970
            let log = entries(for: kind)
            let dying = log.filter { $0.value < threshold }
            guard dying.isEmpty == false else { continue }
            expired += dying.map { Marker(kind: kind, name: $0.key, deletedAt: Date(timeIntervalSince1970: $0.value)) }
            write(log.filter { $0.value >= threshold }, for: kind)
        }
        return expired
    }

    struct Marker: Equatable {
        let kind: CloudRecordKind
        let name: String
        let deletedAt: Date
    }

    private func write(_ log: [String: Double], for kind: CloudRecordKind) {
        defaults.set(log, forKey: key(for: kind))
    }

    private func key(for kind: CloudRecordKind) -> String { "saury.sync.tombstones.\(kind.cloudKitType)" }
}

/// 云端墓碑记录的本体：记的是「哪一种、哪一条、什么时候删的」。
struct SyncTombstoneMarker: Codable, Equatable {
    var kind: CloudRecordKind
    var name: String
    var deletedAt: Date

    init(kind: CloudRecordKind, name: String, deletedAt: Date) {
        self.kind = kind
        self.name = name
        self.deletedAt = deletedAt
    }

    init?(_ data: Data) {
        guard let decoded = try? JSONDecoder.backup.decode(SyncTombstoneMarker.self, from: data),
              decoded.name.isEmpty == false else { return nil }
        self = decoded
    }

    /// 一张墓碑表里要能分清「这条墓碑管的是订阅还是事件」，
    /// 所以名字里带上目标的类型；到期时顺手把目标记录也删掉。
    var recordName: String { "\(kind.cloudKitType)-\(name)" }

    var encoded: Data { (try? JSONEncoder.backup.encode(self)) ?? Data() }
}
