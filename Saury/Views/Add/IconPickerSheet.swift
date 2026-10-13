import SwiftUI
import os
import PhotosUI

/// 选择图标：图标库 / App Store / 网址 / 相册 四个页签。
///
/// 这一层只画 `IconPickerModel` 的状态：什么时候转圈、旧结果留不留、
/// 失败了说哪一句，判断都在模型里，测试跑的是同一份。
struct IconPickerSheet: View {
    @Binding var symbol: String?
    @Binding var imageFile: String?
    @Binding var colorHex: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences
    @StateObject private var model = IconPickerModel()

    @State private var tab: IconPickerModel.Source = .library
    @State private var tabDirection = 1
    @State private var photoItem: PhotosPickerItem?
    @State private var applyHint: String?
    @State private var libraryGroup = IconLibrary.availableGroups.first?.id ?? "general"
    @State private var showingStorefronts = false

    @Namespace private var tabPill

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabSwitcher
                if let applyHint {
                    // 点完成却没关页的那句话：红底胶囊，跟表单里的字段提示同一套。
                    Text(applyHint)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.82, green: 0.21, blue: 0.21)))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                content
            }
            .animation(Motion.pop, value: applyHint)
            .background(Color(light: Color(white: 0.96), dark: Color(white: 0.07)))
            .navigationTitle("选择图标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { apply() }
                        .fontWeight(.bold)
                        .foregroundStyle(accent)
                }
            }
        }
        // 下滑关掉、切走、点取消都走这里：这一趟写到盘上却没选中的文件收干净。
        // 已经「完成」过的话 imageFile 就是那张选中的，不会被误删。
        .onDisappear { model.abandon(currentImageFile: imageFile) }
        #if DEBUG
        .task { await runIconProbe() }
        #endif
    }

    private var accent: Color { Color(hex: preferences.accentHex) ?? .accentColor }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabItems.enumerated()), id: \.offset) { position, item in
                Button {
                    tabDirection = position > currentIndex(of: tab) ? 1 : -1
                    applyHint = nil
                    SelectionHaptics.tick()
                    withAnimation(Motion.slide) { tab = item.1 }
                } label: {
                    Text(item.0)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tab == item.1 ? Color(light: .black, dark: .white) : .secondary)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            if tab == item.1 {
                                Capsule(style: .continuous)
                                    .fill(SauryTheme.surfaceElevated)
                                    .matchedGeometryEffect(id: "iconTabPill", in: tabPill)
                            }
                        }
                }
                .buttonStyle(Pressable(scale: 0.94))
            }
        }
        .padding(3)
        .background(Capsule().fill(SauryTheme.surface))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var tabItems: [(String, IconPickerModel.Source)] {
        [("图标库", .library), ("App Store", .appStore), ("网址", .web), ("相册", .photos)]
    }

    private func currentIndex(of tab: IconPickerModel.Source) -> Int {
        tabItems.firstIndex { $0.1 == tab } ?? 0
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            // 四个来源各写一个 if：旧 pane 留在树上，切换才是两页对滑而不是闪一下黑。
            if tab == .library {
                libraryPane.transition(.directionalSlide(tabDirection, distance: 26))
            }
            if tab == .appStore {
                appStorePane.transition(.directionalSlide(tabDirection, distance: 26))
            }
            if tab == .web {
                webPane.transition(.directionalSlide(tabDirection, distance: 26))
            }
            if tab == .photos {
                photosPane.transition(.directionalSlide(tabDirection, distance: 26))
            }
        }
    }

    // MARK: - 图标库

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(IconLibrary.availableGroups) { group in
                        Button {
                            SelectionHaptics.tick()
                            withAnimation(Motion.ui) { libraryGroup = group.id }
                        } label: {
                            Text(group.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(libraryGroup == group.id ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(libraryGroup == group.id
                                        ? accent
                                        : SauryTheme.surface)
                                )
                                .scaleEffect(libraryGroup == group.id ? 1.04 : 1)
                        }
                        .buttonStyle(Pressable(scale: 0.92))
                    }
                }
            }

            if let group = IconLibrary.availableGroups.first(where: { $0.id == libraryGroup }) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(Array(group.symbols.enumerated()), id: \.element) { index, candidate in
                        Button {
                            SelectionHaptics.tick()
                            symbol = candidate
                            imageFile = nil
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(SauryTheme.surface)
                                Image(systemName: candidate)
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(symbol == candidate && imageFile == nil ? accent : .primary)
                            }
                            .frame(height: 54)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(symbol == candidate && imageFile == nil ? accent : .clear, lineWidth: 2)
                            )
                            .scaleEffect(symbol == candidate && imageFile == nil ? 1.06 : 1)
                            .shadow(color: symbol == candidate && imageFile == nil
                                ? accent.opacity(0.35)
                                : .clear, radius: 7, y: 3)
                        }
                        .buttonStyle(Pressable(scale: 0.9))
                        .staged(min(index, 12))
                    }
                }
                .id(libraryGroup)
                .transition(.opacity)
            }

            Text("颜色")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            // 12 个色点排成一行是 540 点宽，比屏宽出一大截。
            // 整条 HStack 的固有宽度还会把这一页的排版一起撑宽 ——
            // 页签条和图标网格跟着两头被切掉，边上那几列根本点不到。
            // 所以这里让它自己换行，而不是缩着色点硬塞进一行。
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Palette.dotSide,
                                                   maximum: Palette.dotSide),
                                          spacing: Palette.dotSpacing)],
                      alignment: .leading, spacing: Palette.dotSpacing) {
                ForEach(Palette.colors, id: \.self) { hex in
                    Button {
                        SelectionHaptics.tick()
                        colorHex = (colorHex == hex) ? nil : hex
                    } label: {
                        Circle()
                            .fill(Palette.color(hex))
                            .frame(width: Palette.dotSide, height: Palette.dotSide)
                            .overlay(
                                Circle().stroke(colorHex == hex ? Color.primary : .clear, lineWidth: 2.5)
                            )
                            .scaleEffect(colorHex == hex ? 1.12 : 1)
                    }
                    .buttonStyle(Pressable(scale: 0.88, animation: Motion.pop))
                }
            }
            .animation(Motion.pop, value: colorHex)
        }
        .padding(.horizontal, Palette.rowGutter)
        .padding(.bottom, 20)
        .animation(Motion.page, value: libraryGroup)
    }

    // MARK: - App Store

    private var appStorePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    showingStorefronts.toggle()
                } label: {
                    Text(currentFlag)
                        .font(.system(size: 22))
                }
                .confirmationDialog("选择店面", isPresented: $showingStorefronts, titleVisibility: .visible) {
                    ForEach(AppStoreIconClient.storefronts, id: \.code) { store in
                        Button("\(store.flag) \(store.name)") { model.setStorefront(store.code) }
                    }
                }
                TextField("搜索 App，如 爱奇艺", text: termBinding)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(SauryTheme.surface))
                    .submitLabel(.search)
                    .onSubmit { model.submit() }
                Button {
                    model.submit()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(accent))
                }
            }

            // 查的时候旧结果继续摆在底下，只压暗加个转圈：
            // 整屏闪空比多等 200 毫秒难受得多。
            ZStack {
                resultBody
                if model.phase == .searching {
                    Color(light: Color(white: 0.96).opacity(0.6), dark: Color.black.opacity(0.5))
                        .allowsHitTesting(false)
                    ProgressView()
                }
            }
            .animation(Motion.page, value: model.phase == .searching)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
        .animation(Motion.page, value: model.results.count)
        .animation(Motion.pop, value: model.selectedAppID)
    }

    private var termBinding: Binding<String> {
        Binding(get: { model.term }, set: { model.setTerm($0) })
    }

    @ViewBuilder
    private var resultBody: some View {
        switch model.phase {
        case .idle:
            hint("输入名称后点搜索，或者直接回车")
        case .empty:
            hint("没搜到「\(model.term.trimmingCharacters(in: .whitespaces))」，换个说法试试")
        case .failed(let problem):
            failedNotice(problem.message, retry: { model.submit() })
        case .searching, .loaded:
            if model.results.isEmpty {
                hint("正在搜索…")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element) { index, result in
                        appRow(result, at: index)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func appRow(_ result: AppStoreIconClient.AppResult, at index: Int) -> some View {
        Button {
            SelectionHaptics.tick()
            model.select(result)
        } label: {
            HStack(spacing: 12) {
                appIcon(for: result)
                Text(result.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if model.selectedAppID == result.id, model.image(for: result) != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressable())
        .staged(min(index, 10), delay: 0.05)
        // 滚到这一行才拉图；行没了 SwiftUI 自己取消这一趟。
        .task(id: result.id) {
            if model.needsIconLoad(for: result) { await model.loadIcon(for: result) }
        }
    }

    private var currentFlag: String {
        AppStoreIconClient.storefronts.first { $0.code == model.storefront }?.flag ?? "🇨🇳"
    }

    @ViewBuilder
    private func appIcon(for result: AppStoreIconClient.AppResult) -> some View {
        if let image = model.image(for: result) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else if model.iconFailures.contains(result.id) {
            // 下载失败单独说，并且就地给重试 —— 别让人以为这个 App 没有图标。
            Button {
                Task { await model.retryIcon(result) }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text("重试").font(.system(size: 8))
                }
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SauryTheme.surface))
            }
            .accessibilityLabel("重试下载 \(result.name) 的图标")
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(SauryTheme.surfaceElevated)
                .frame(width: 38, height: 38)
        }
    }

    private func hint(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func failedNotice(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 30)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Text("重试")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(Pressable(scale: 0.94))
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    // MARK: - 网址

    private var webPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("输入网址，如 setapp.com", text: webBinding)
                    .font(.subheadline)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(SauryTheme.surface))
                    .submitLabel(.go)
                    .onSubmit { model.fetchWebIcon() }
                Button {
                    model.fetchWebIcon()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(accent))
                }
            }
            switch model.webPhase {
            case .idle:
                Text("输入网址获取图标 —— Mac 软件 / 网页服务都行")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 26)
                    .transition(.opacity)
            case .loading:
                HStack {
                    Spacer(); ProgressView(); Spacer()
                }
                .padding(.top, 26)
                .transition(.opacity)
            case .failed(let problem):
                failedNotice(problem.message, retry: { model.fetchWebIcon() })
            case .done:
                if let image = model.webImage {
                    VStack(spacing: 10) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                        Text("已获取，点完成应用")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
        .animation(Motion.pop, value: model.webPhase)
    }

    private var webBinding: Binding<String> {
        Binding(get: { model.webInput }, set: { model.setWebInput($0) })
    }

    // MARK: - 相册

    private var photosPane: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                VStack(spacing: 8) {
                    switch model.photoPhase {
                    case .loading:
                        ProgressView()
                            .frame(width: 96, height: 96)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(SauryTheme.surface))
                    case .done, .empty:
                        if let image = model.photoImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                                .transition(.scale(scale: 0.72).combined(with: .opacity))
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 26))
                                .foregroundStyle(accent)
                                .frame(width: 96, height: 96)
                                .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(SauryTheme.surface))
                                .transition(.opacity)
                        }
                    case .failed(let problem):
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                            Text(problem.message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 96, height: 96)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(SauryTheme.surface))
                        .transition(.opacity)
                    }
                    Text(model.photoImage == nil
                        ? "从相册选择图片\n会自动裁成方形图标"
                        : "已选好，点完成应用")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .buttonStyle(Pressable(scale: 0.95, animation: Motion.pop))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .animation(Motion.pop, value: model.photoPhase)
        .onChange(of: photoItem) { _, item in model.loadPhoto(item) }
    }

    // MARK: - 应用

    private func apply() {
        let chosen = model.finish(source: tab, currentImageFile: imageFile)
        if tab == .library {
            imageFile = nil
            // 库里挑的符号带颜色；没点颜色就清掉，让卡片用自动色。
            if symbol == nil { symbol = "sparkles" }
            SelectionHaptics.success()
            dismiss()
            return
        }
        guard let chosen else {
            // 没图就别关页：以前这里静默 dismiss，用户以为选上了，
            // 回到表单才发现图标还是那个加号。
            applyHint = missingImageHint
            SelectionHaptics.warning()
            return
        }
        imageFile = chosen
        symbol = nil
        SelectionHaptics.success()
        dismiss()
    }

    /// 差在哪一步就说哪一步，不给一句万能提示。
    private var missingImageHint: String {
        switch tab {
        case .library:
            return ""
        case .appStore:
            if let id = model.selectedAppID, model.iconFailures.contains(id) {
                return "这个图标没取到，点行上的重试"
            }
            return model.selectedAppID == nil ? "先选一个 App，再点完成" : "图标还在下载，等一下再点完成"
        case .web:
            return "先取到图标，再点完成"
        case .photos:
            return "先从相册选一张图，再点完成"
        }
    }
}

#if DEBUG
extension IconPickerSheet {
    private static let probeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")

    /// 图标选择剧本（任务书 §7.2）。
    ///
    /// 这台机器的命令行没有辅助功能权限，按不动页签和按钮，所以这里调的是那些控件背后的
    /// **同一批**方法（`setTerm`／`submit`／`fetchWebIcon`／`apply`），不是另搭一条演示通路。
    /// 单测那一层用的是假传输：`HTTPIconTransport` 这条真链路 —— 状态码、MIME、
    /// URLError 翻译、按 trackId 落盘 —— 从来没在线上任上走过一次，这一条就是那一次。
    /// 每步等真条件成立再往下（网络多久就是多久，不掐秒数猜），到点自己按一次快门。
    func runIconProbe() async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-icon") else { return }
        probe("① 弹窗打开：图标库页签")
        await snap("01-library", settle: 1.6)

        // 相册页排在最前面：`apply()` 按「当前页签」取图，所以这一页只能在看图之前先扫一眼。
        // 系统选择器要人手点（这台机器的命令行没有辅助功能权限），这里只拍到它的空状态和入口。
        tab = .photos
        probe("② 相册页签：状态=\(photoState())，入口是系统 PhotosPicker，探针不代跑")
        await snap("02-photos-empty")

        probe("③ 切到 App Store，店面 us，提交搜索 netflix（真网络）")
        tab = .appStore
        model.setStorefront("us")
        model.setTerm("netflix")
        model.submit()
        guard await waitProbe("搜索返回", { self.model.phase.isSettled }) else { return }
        probe("④ 搜索回来：\(searchState())，\(model.results.count) 条"
              + (model.results.first.map { "，第一条「\($0.name)」" } ?? ""))
        await snap("03-appstore-results")

        if let row = model.results.first {
            model.select(row)
            await waitProbe("首行图标落地", {
                self.model.image(for: row) != nil || self.model.iconFailures.contains(row.id)
            })
            if let image = model.image(for: row) {
                let key = IconPickerModel.appStoreKey(row.id)
                probe("⑤ 首行「\(row.name)」图标当场刷出来：\(Int(image.size.width))x\(Int(image.size.height))；"
                    + "落盘 \(key) 在不在=\(IconImageStore.shared.exists(key))；"
                    + "同一行再问一次要不要下=\(model.needsIconLoad(for: row))")
            } else {
                probe("⑤ 首行图标没落地：失败记上了=\(model.iconFailures.contains(row.id))")
            }
            await snap("04-appstore-selected")

            // 换店面等于换条件重查。这一张要拍的是「还在查，旧结果没闪空」：
            // 快门就在搜索态这一格里按，不等结果 —— 等到了再拍，拍到的是换完的那一批。
            model.setStorefront("cn")
            if await waitProbe("换店面后进入搜索态", timeout: 5, { self.model.phase == .searching }) {
                probe("⑥ 换店面重查中：状态=\(searchState())，屏上还是 \(model.results.count) 条旧结果（没闪空）")
                // 这一张必须快门快：搜索态只有约一秒多，按默认 0.8 秒等下去，
                // 拍到就已经是换完的那一批，图跟上面这句话就对不上了。
                await snap("05-appstore-searching-keeps-old", settle: 0.35)
            }
            await waitProbe("第二次搜索返回", { self.model.phase.isSettled })
            probe("⑦ 换店面查完：\(searchState())，\(model.results.count) 条")
            await snap("06-appstore-new-storefront")
        }

        probe("⑧ 切到网址页签，填 icloud（少后缀，该当场说清楚，一条请求都不该发）")
        tab = .web
        model.setWebInput("icloud")
        model.fetchWebIcon()
        await waitProbe("icloud 的判定", { self.model.webPhase.isSettled })
        probe("⑨ 网址填 icloud → \(webState())")
        await snap("07-web-badhost")

        probe("⑩ 网址填一个查无此站的域名（看真网络失败翻成哪句话）")
        model.setWebInput("this-domain-really-does-not-exist-8f2a.com")
        model.fetchWebIcon()
        await waitProbe("不存在域名的判定", { self.model.webPhase.isSettled })
        probe("⑪ 查无此站 → \(webState())")
        await snap("08-web-offline")

        probe("⑫ 网址填 setapp.com（180x180 和 precomposed 都是 404，看它往下走到哪一条）")
        model.setWebInput("setapp.com")
        model.fetchWebIcon()
        await waitProbe("setapp 取图", { self.model.webPhase.isSettled })
        probe("⑬ setapp.com → \(webState())"
              + (model.webImage.map { "，尺寸 \(Int($0.size.width))x\(Int($0.size.height))" } ?? ""))
        await snap("09-web-fetched")

        model.setWebInput("icloud.com")
        probe("⑭ 换了网址：预览还挂着=\(model.webImage != nil)，状态=\(webState())")
        await snap("10-web-address-changed")

        model.setWebInput("setapp.com")
        model.fetchWebIcon()
        await waitProbe("第二次取同一个网址", { self.model.webPhase.isSettled })
        probe("⑮ 同一个网址再取一次 → \(webState())")
        await snap("11-web-refetched")

        apply()
        probe("⑯ 点完成：写回表单 imageFile=\(imageFile ?? "nil")，symbol=\(symbol ?? "nil")，弹窗收掉")
        // 这一张要拍的是**表单**：弹窗退场还在跑的时候按快门，拍到的仍是弹窗那一层。
        await snap("12-form-after-apply", settle: 1.0)
    }

    /// 等 SwiftUI 把刚才那步画上去，再按快门。
    /// 这段等待只为截图服务，不参与任何判定 —— 判定全部走 `waitProbe` 的条件。
    private func snap(_ step: String, settle: TimeInterval = 0.8) async {
        probe(await ProbeShutter.capture(step, settle: settle))
    }

    private func photoState() -> String {
        switch model.photoPhase {
        case .empty: return "还没选"
        case .loading: return "在读相册"
        case .done: return "已读到图"
        case .failed(let problem): return "失败：\(problem.message)"
        }
    }

    private func probe(_ line: String) {
        Self.probeLogger.log("图标探针 \(line, privacy: .public)")
    }

    /// 等条件成立。超时就把「没等到」如实说一句，不假装等到了再往下走。
    private func waitProbe(_ label: String, timeout: TimeInterval = 20, _ done: () -> Bool) async -> Bool {
        let began = Date()
        while !done() {
            if Date().timeIntervalSince(began) > timeout {
                probe("⏱ \(label)：\(Int(timeout)) 秒内没等到")
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func searchState() -> String {
        switch model.phase {
        case .idle: return "还没查"
        case .searching: return "在查（旧结果还摆在底下）"
        case .loaded: return "有结果"
        case .empty: return "0 条"
        case .failed(let problem): return "失败：\(problem.message)"
        }
    }

    private func webState() -> String {
        switch model.webPhase {
        case .idle: return "空闲"
        case .loading: return "在取"
        case .done: return "已获取"
        case .failed(let problem): return "失败：\(problem.message)"
        }
    }
}

private extension IconPickerModel.SearchPhase {
    var isSettled: Bool {
        switch self {
        case .loaded, .empty, .failed: return true
        case .idle, .searching: return false
        }
    }
}

private extension IconPickerModel.WebPhase {
    var isSettled: Bool {
        switch self {
        case .done, .failed: return true
        case .idle, .loading: return false
        }
    }
}
#endif
