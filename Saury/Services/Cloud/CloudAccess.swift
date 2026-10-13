import Foundation

/// CloudKit 到底能不能碰：读签名里那份 entitlements，不碰 CloudKit 本身。
///
/// 为什么不用编译条件：`#if SAURY_ICLOUD` 只能说明「这次编译带了这个字样」，
/// 说明不了描述文件里真给了什么能力。真正给没给，写在包里的
/// `embedded.mobileprovision` 中 —— 那才是签名结果。以后在 Xcode 里给 App ID
/// 勾上 iCloud、把带 CloudKit 的 entitlements 挂上重签，这里立刻自己就通了，
/// 不需要改一行代码，也就不存在「条件忘了加、界面显示已同步」那种假状态。
///
/// 还有必须先判的原因之一：没有 iCloud 权限时 `CKContainer.default()` 会在
/// dispatch_once 里直接抛异常，Swift 的 `try` 接不住，进程当场没了。
/// 所以任何 CK 对象都只能从这里判定 ready 之后才许创建。
enum CloudAccess {
    /// 期望的容器。对不上不算错（别的团队会用别的 id），但界面上要说出来。
    static let expectedContainerIdentifier = "iCloud.com.guofeng.saury"

    enum Status: Equatable {
        /// 没 iCloud 能力 / 容器缺失。带着「缺的是哪一样」，页面要能照原话说。
        case unavailable(reason: String)
        case ready(containerIdentifier: String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        /// 给界面看的一句话。ready 时是容器名，不 ready 时是缺了什么。
        var displayText: String {
            switch self {
            case .unavailable(let reason): return reason
            case .ready(let container): return container
            }
        }

        /// 签名通了但容器和这个 App 预期的不是同一个：能用，但要说出来，
        /// 不然「同步到了另一个库」这种事故在界面上完全看不出来。
        var containerMismatch: String? {
            guard case .ready(let container) = self,
                  container != CloudAccess.expectedContainerIdentifier else { return nil }
            return container
        }
    }

    /// 当前这个包的真实能力。生产路径唯一入口。
    static var current: Status { status(profile: embeddedProvisioningProfile()) }

    /// 纯函数：给一份描述文件字节，判它有没有 CloudKit。测试喂的就是这里，
    /// 不需要真签名也能把「缺服务 / 缺容器 / 全都有」三条路都考一遍。
    static func status(profile: Data?) -> Status {
        guard let profile else {
            return .unavailable(reason: "这个包没有签名描述文件，读不到 iCloud 能力")
        }
        guard let entitlements = entitlements(in: profile) else {
            return .unavailable(reason: "签名描述文件里没有权限清单，读不到 iCloud 能力")
        }
        let services = entitlements["com.apple.developer.icloud-services"] as? [String] ?? []
        guard services.contains("CloudKit") else {
            return .unavailable(reason: "App ID 没开 iCloud（CloudKit）能力")
        }
        let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
        guard let container = containers.first(where: { !$0.isEmpty }) else {
            return .unavailable(reason: "开了 iCloud，但描述文件里没有一个容器标识")
        }
        return .ready(containerIdentifier: container)
    }

    // MARK: - 描述文件读取

    static func embeddedProvisioningProfile() -> Data? {
        // 模拟器上由 Xcode 安装的包、真机上的 ipa 都有这个文件；
        // 纯命令行造出来的未签名产物没有 —— 那就当作「没能力」，正好是要的结果。
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// 描述文件是 DER/CMS 包着一份 plist。整份字节里 XML 只出现一次，
    /// 所以直接掐 `<?xml` 到 `</plist>` 这段，不用解 ASN.1。
    private static func entitlements(in profile: Data) -> [String: Any]? {
        guard let open = profile.range(of: Data("<?xml".utf8)),
              let close = profile.range(of: Data("</plist>".utf8)),
              close.upperBound > open.lowerBound else { return nil }
        let xml = profile.subdata(in: open.lowerBound..<close.upperBound)
        guard let root = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
                as? [String: Any] else { return nil }
        return root["Entitlements"] as? [String: Any]
    }
}
