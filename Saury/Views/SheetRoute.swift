import SwiftUI
import SwiftData

/// 全站「现在弹着哪一层」的唯一凭据（任务书 §6.3）。
///
/// # 为什么要收成一条
/// 以前同一个视图上挂着三张 sheet（列表页：详情 / 编辑 / 筛选；根视图：新增 / 详情 / 提醒引导），
/// 而同一层只认一张：第二张要么压根弹不出来，要么正好撞上第一张的退场动画 ——
/// 表现出来就是「点了没反应」和「连点两下弹出错的那一页」。
/// 「详情→编辑」更糟：先 `dismiss()` 详情、再让父层弹编辑，两件事挤在同一帧，
/// 编辑页有时根本不出现。现在一层只有一张 sheet，编辑挂在详情自己的层里。
///
/// # 为什么带 id 而不是带对象
/// sheet 挂着的时候那条订阅可能被归档、被删掉、被另一台设备同步走。
/// 按 id 每次渲染重新查一遍：查得到就照常办事，查不到就明说，
/// 而不是攥着一个已经不存在的旧对象继续显示。
enum SheetRoute: Identifiable, Equatable {
    /// 新增。初值从哪儿来都行，反正表单只认 `AddPrefill` 这一个形状。
    case add(prefill: AddPrefill)
    /// 直接编辑某一条（列表长按菜单那条路）。
    case edit(UUID)
    case detail(UUID)
    case filter
    /// 第一笔订阅保存后的「要不要开提醒」引导。
    case reminderPrompt

    var id: String {
        switch self {
        case .add(let prefill): return "add:\(prefill.token.uuidString)"
        case .edit(let id): return "edit:\(id.uuidString)"
        case .detail(let id): return "detail:\(id.uuidString)"
        case .filter: return "filter"
        case .reminderPrompt: return "reminderPrompt"
        }
    }

    /// 底部那颗「+」现在是不是表单。表单挂着的时候它转成 ×。
    var isFormSheet: Bool {
        switch self {
        case .add, .edit: return true
        case .detail, .filter, .reminderPrompt: return false
        }
    }
}

/// 添加表单的初值。
///
/// 以前这一层只带一个 `prefill: String`（只有名字），所以分享扩展那句
/// 「链接会记在来源里」和「图片会当图标」都没有落点 —— 话说了，字段没带。
/// 现在名字、备注、图标各走各的格，带不进来的东西就不该出现在这句话里。
struct AddPrefill: Equatable {
    var name: String = ""
    /// 落进「备注」。订阅这一层没有独立的来源字段，硬说「记在来源里」是假话。
    var note: String?
    /// 已经搬进 `IconImageStore` 的文件名。
    var iconImageFile: String?
    /// 两条一模一样的草稿也要各弹一次：sheet 的身份按这一条区分。
    let token = UUID()

    static let empty = AddPrefill()

    var isEmpty: Bool { name.isEmpty && note == nil && iconImageFile == nil }
}

/// 根视图那一张 sheet 的控制器。
///
/// # 一次只开一层
/// 同一层挂两张 sheet，SwiftUI 只认其中一张，另一张的表现就是「点了没反应」。
/// 所以这里把「已经开着的时候又要弹别的」解释成：先把这一层退场，退干净了再上下一层。
///
/// # 退场动画还在跑的时候按下一个入口
/// 那次呈现会被系统整段丢掉 —— 用户点了、什么都没发生、也不报错。
/// 这里把这一层等出来：退场期间要弹的先排着，`onDismiss` 一到就补上，
/// 不靠固定延时去猜动画时长。
@MainActor
final class SheetRouter: ObservableObject {
    @Published var route: SheetRoute? {
        didSet {
            // 「有 → 没有」就是这一层开始退场；SwiftUI 要到动画跑完才回调 `onDismiss`。
            if route == nil, oldValue != nil { isClosing = true }
        }
    }

    private var isClosing = false
    private var queued: SheetRoute?

    func present(_ next: SheetRoute) {
        // 这一张正弹着的时候又点了一次同一个入口：不该把它推倒重来。
        // 连点两下在观感上就是「页面闪一下又回到原样」，等于什么都没做还白掉一次动画。
        if route == next { return }
        guard route == nil else {
            queued = next
            route = nil
            return
        }
        // 退场动画还在播：这一次呈现会被系统整段丢掉，所以排到 `noteClosed` 后面补上。
        // 这里取「最后一次点击为准」——快速连点三行，落在第三行上才是用户要的那件事。
        guard isClosing == false else {
            queued = next
            return
        }
        route = next
    }

    func close() {
        route = nil
    }

    /// 排在退场后面的那一层还没上。给测试和调用方看一眼，不拿它做别的决定。
    var hasQueuedRoute: Bool { queued != nil }

    /// 挂在 `.sheet(item:onDismiss:)` 的 `onDismiss` 上：这一层真的没了，把排队的交出去。
    func noteClosed() {
        isClosing = false
        guard let queued else { return }
        self.queued = nil
        route = queued
    }
}

// MARK: - 按 id 解析的 sheet 内容

/// 详情：按 id 现查。
///
/// 返回来源不用额外记：这一层是谁弹出来的，关掉就回到谁那里。
/// 「编辑」挂在详情页自己的层上，所以详情页不会被关掉，编辑的也是同一条订阅
/// （`AddSubscriptionView` 拿到的就是这一条，保存按同一个 id upsert）。
struct RoutedDetailView: View {
    let id: UUID
    @Query private var found: [Subscription]

    init(id: UUID) {
        self.id = id
        let uuid = id
        _found = Query(filter: #Predicate<Subscription> { $0.id == uuid })
    }

    var body: some View {
        if let subscription = found.first {
            SubscriptionDetailView(subscription: subscription)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            MissingSubscriptionView()
        }
    }
}

/// 编辑：同样按 id 现查，身份就是查到的这一条。
struct RoutedEditView: View {
    let id: UUID
    @Query private var found: [Subscription]

    init(id: UUID) {
        self.id = id
        let uuid = id
        _found = Query(filter: #Predicate<Subscription> { $0.id == uuid })
    }

    var body: some View {
        if let subscription = found.first {
            AddSubscriptionView(editing: subscription)
        } else {
            MissingSubscriptionView()
        }
    }
}

/// 这一层要办的对象已经不在了。
///
/// 只有一种情况下会走到这里：sheet 还挂着的时候那条被删了（自己删的、撤销没按住的、
/// 或者别的设备同步下来的）。留一个空表单在屏幕上，用户填完点保存就什么都没了。
struct MissingSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text("这条订阅已经不在库里了")
                .font(.headline)
            Text("可能是刚才被删掉了。关掉这一页，列表里的内容还是最新的。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("关闭") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SauryTheme.background)
    }
}
