import Foundation

/// 同步用的云端记录，和 CloudKit 无关的一种形状。
///
/// 为什么要这一层：CloudKit 只有「签名里有 iCloud 能力 + 登录了账户 + 后台建好
/// 容器和 Schema」三件事同时成立才碰得动，这台机器上一件都不成立。
/// 如果合并、墓碑、幂等这些规则写在 CKRecord 上面，它们就一行都测不到 ——
/// 而任务书要的恰恰是这些规则可证。所以下面这个形状是同步的真正对象，
/// `CloudKitRecordStore` 只是它到 CKRecord 的搬运工，测试用的是内存版搬运工。
enum CloudRecordKind: String, CaseIterable, Codable {
    case subscription
    case event
    case setting
    case tombstone

    /// CloudKit 的 record type 名。后台部署 Schema 时要按这张表建表，
    /// 少一个类型，同步就在那一步报错（报错内容见 `Docs/CLOUD_SYNC.md`）。
    var cloudKitType: String {
        switch self {
        case .subscription: return "Subscription"
        case .event: return "SubscriptionEvent"
        case .setting: return "UserSetting"
        case .tombstone: return "Tombstone"
        }
    }
}

/// 一条云端记录。`payload` 是这条记录的本体（JSON），其余几列都是同步规则要用到的：
/// 比时间戳、判删除、验图标。字段种类故意很少 —— CloudKit 那边好映射，内存版也好装。
struct CloudRecord: Equatable {
    var kind: CloudRecordKind
    /// 稳定标识：订阅和事件用自己的 UUID，设置用键名，墓碑用「被删的是哪一条」。
    var name: String
    var updatedAt: Date
    /// 删除时间。有值 = 这条已经死了；墓碑记录只有这个字段有用。
    var deletedAt: Date?
    var payload: Data
    /// 图标字节。整表拉取时不带它（见 `CloudRecordStore.index`），单独取才有。
    var icon: Data?
    /// 图标字节的 SHA-256。带着它才能做到「本机这张和云端那张一模一样就别再传一遍」。
    var iconChecksum: String?

    static func iconChecksum(of icon: Data) -> String { BackupContainer.sha256(icon) }
}

enum CloudStoreError: LocalizedError, Equatable {
    /// 能力或账户不具备：界面直接说明缺什么，不做任何重试。
    case unavailable(String)
    /// 网络、权限撤销、CloudKit 报错。携带人话原因，同步状态落成 failed。
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "云端读写不可用：\(reason)"
        case .requestFailed(let reason): return "云端请求失败：\(reason)"
        }
    }
}

/// 云端存储的最小接口。四个动作够表达「拉清单、按需取图、整批存、按名删」。
protocol CloudRecordStore: AnyObject {
    /// 整表清单：带 payload 和时间戳，**不带图标字节**。
    /// 同步主循环只需要比时间戳，把几百张图一次拖回来是最初那版的负担来源。
    func index(of kind: CloudRecordKind) async throws -> [CloudRecord]

    /// 按名字取若干条（含图标）。清单里没有图标字节，补图这一步走这里。
    func records(of kind: CloudRecordKind, names: [String]) async throws -> [CloudRecord]

    /// 返回**服务端确认收下**的那些条。核对阶段读的是这个返回值，
    /// 不是「我叫了保存所以一定存上了」—— 任务书 §4.2 不许那种成功。
    @discardableResult
    func save(_ records: [CloudRecord]) async throws -> [CloudRecord]

    /// 返回真删掉的名字。少删的那几条由核对阶段报成失败，不静默。
    @discardableResult
    func delete(_ kind: CloudRecordKind, names: [String]) async throws -> [String]

    /// 账户状态。CloudKit 的类型不出现在这一层，测试里才装得进假件。
    func accountStatus() async throws -> CloudAccountStatus
}
