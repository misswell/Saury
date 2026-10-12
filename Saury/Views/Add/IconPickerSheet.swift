import SwiftUI
import PhotosUI

/// 选择图标：图标库 / App Store / 网址 / 相册 四个页签。
/// 选完直接写回表单的三个绑定（符号、图片文件、颜色）。
struct IconPickerSheet: View {
    @Binding var symbol: String?
    @Binding var imageFile: String?
    @Binding var colorHex: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences

    enum Tab: Hashable { case library, appStore, web, photos }

    @State private var tab: Tab = .library
    @State private var tabDirection = 1
    @Namespace private var tabPill

    // 图标库
    @State private var libraryGroup = IconLibrary.groups.first?.id ?? "general"

    // App Store
    @State private var storefront = AppStoreIconClient.storefronts[0].code
    @State private var showingStorefronts = false
    @State private var searchTerm = ""
    @State private var searching = false
    @State private var results: [AppStoreIconClient.AppResult] = []
    @State private var selectedAppID: Int64?
    @State private var downloadedAppImage: UIImage?
    @State private var searchFailed = false

    // 网址
    @State private var webInput = ""
    @State private var webState: WebState = .idle
    @State private var webImage: UIImage?

    enum WebState: Equatable {
        case idle, loading, failed, done
    }

    // 相册
    @State private var photoItem: PhotosPickerItem?
    @State private var photoImage: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabSwitcher
                content
            }
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
                        .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                }
            }
        }
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabItems.enumerated()), id: \.offset) { position, item in
                Button {
                    tabDirection = position > currentIndex(of: tab) ? 1 : -1
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

    private var tabItems: [(String, Tab)] {
        [("图标库", .library), ("App Store", .appStore), ("网址", .web), ("相册", .photos)]
    }

    private func currentIndex(of tab: Tab) -> Int {
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
                    ForEach(IconLibrary.groups) { group in
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
                                        ? Color(hex: preferences.accentHex) ?? .accentColor
                                        : SauryTheme.surface)
                                )
                                .scaleEffect(libraryGroup == group.id ? 1.04 : 1)
                        }
                        .buttonStyle(Pressable(scale: 0.92))
                    }
                }
            }

            if let group = IconLibrary.groups.first(where: { $0.id == libraryGroup }) {
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
                                    .foregroundStyle(symbol == candidate && imageFile == nil
                                        ? Color(hex: preferences.accentHex) ?? .accentColor
                                        : .primary)
                            }
                            .frame(height: 54)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(symbol == candidate && imageFile == nil
                                        ? Color(hex: preferences.accentHex) ?? .accentColor
                                        : .clear, lineWidth: 2)
                            )
                            .scaleEffect(symbol == candidate && imageFile == nil ? 1.06 : 1)
                            .shadow(color: symbol == candidate && imageFile == nil
                                ? (Color(hex: preferences.accentHex) ?? .accentColor).opacity(0.35)
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
            HStack(spacing: 12) {
                ForEach(Palette.colors, id: \.self) { hex in
                    Button {
                        SelectionHaptics.tick()
                        colorHex = (colorHex == hex) ? nil : hex
                    } label: {
                        Circle()
                            .fill(Palette.color(hex))
                            .frame(width: 34, height: 34)
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
        .padding(.horizontal, 14)
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
                        Button("\(store.flag) \(store.name)") { storefront = store.code }
                    }
                }
                TextField("搜索 App，如 爱奇艺", text: $searchTerm)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(SauryTheme.surface))
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                Button {
                    Task { await search() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(hex: preferences.accentHex) ?? .accentColor))
                }
            }

            if searching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.top, 30)
                .transition(.opacity)
            } else if results.isEmpty {
                VStack(spacing: 8) {
                    Spacer().frame(height: 40)
                    Text(searchFailed ? "没搜到，换个说法试试" : "输入名称后点搜索")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element) { index, result in
                        Button {
                            selectApp(result)
                        } label: {
                            HStack(spacing: 12) {
                                appIcon(for: result)
                                Text(result.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if selectedAppID == result.id, downloadedAppImage != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CardPressable())
                        .staged(min(index, 10), delay: 0.05)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
        .animation(Motion.page, value: results.count)
        .animation(Motion.page, value: searching)
        .animation(Motion.pop, value: selectedAppID)
    }

    private var currentFlag: String {
        AppStoreIconClient.storefronts.first { $0.code == storefront }?.flag ?? "🇨🇳"
    }

    private func appStoreIconKey(_ id: Int64) -> String {
        "appstore-\(id).png"
    }

    @ViewBuilder
    private func appIcon(for result: AppStoreIconClient.AppResult) -> some View {
        if let image = IconImageStore.shared.image(for: appStoreIconKey(result.id)) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(SauryTheme.surfaceElevated)
                .frame(width: 38, height: 38)
                .task {
                    guard let url = result.artworkURL,
                          let image = await AppStoreIconClient().downloadImage(from: url) else { return }
                    _ = IconImageStore.shared.store(image, named: appStoreIconKey(result.id))
                }
        }
    }

    private func selectApp(_ result: AppStoreIconClient.AppResult) {
        SelectionHaptics.tick()
        selectedAppID = result.id
        searchTerm = result.name
        Task {
            searching = true
            var image = IconImageStore.shared.image(for: appStoreIconKey(result.id))
            if image == nil, let url = result.artworkURL {
                image = await AppStoreIconClient().downloadImage(from: url)
                if let image {
                    _ = IconImageStore.shared.store(image, named: appStoreIconKey(result.id))
                }
            }
            downloadedAppImage = image
            searching = false
        }
    }

    private func search() async {
        let term = searchTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        searching = true
        searchFailed = false
        do {
            results = try await AppStoreIconClient().search(term: term, storefront: storefront)
        } catch {
            results = []
            searchFailed = true
        }
        searching = false
    }

    // MARK: - 网址

    private var webPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("输入网址，如 setapp.com", text: $webInput)
                    .font(.subheadline)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(SauryTheme.surface))
                    .submitLabel(.go)
                    .onSubmit { Task { await fetchWebIcon() } }
                Button {
                    Task { await fetchWebIcon() }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(hex: preferences.accentHex) ?? .accentColor))
                }
            }
            if webState == .idle {
                Text("输入网址获取图标 —— Mac 软件 / 网页服务都行")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 26)
                    .transition(.opacity)
            } else if webState == .loading {
                HStack {
                    Spacer(); ProgressView(); Spacer()
                }
                .padding(.top, 26)
                .transition(.opacity)
            } else if webState == .failed {
                Text("没找到图标，检查网址后重试")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 26)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let webImage {
                VStack(spacing: 10) {
                    Image(uiImage: webImage)
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
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
        .animation(Motion.pop, value: webState)
    }

    private func fetchWebIcon() async {
        webState = .loading
        if let image = await WebIconClient().fetchIcon(for: webInput) {
            webImage = image
            webState = .done
            SelectionHaptics.success()
        } else {
            webState = .failed
            SelectionHaptics.warning()
        }
    }

    // MARK: - 相册

    private var photosPane: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                VStack(spacing: 8) {
                    if let photoImage {
                        Image(uiImage: photoImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                            .transition(.scale(scale: 0.72).combined(with: .opacity))
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 26))
                            .foregroundStyle(Color(hex: preferences.accentHex) ?? .accentColor)
                            .frame(width: 96, height: 96)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SauryTheme.surface))
                            .transition(.opacity)
                    }
                    Text("从相册选择图片\n会自动裁成方形图标")
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
        .animation(Motion.pop, value: photoImage == nil)
        .onChange(of: photoItem) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                photoImage = image
                SelectionHaptics.success()
            }
        }
    }

    // MARK: - 应用

    private func apply() {
        switch tab {
        case .library:
            imageFile = nil
            // 库里挑的符号带颜色；没点颜色就清掉，让卡片用自动色。
            if symbol == nil { symbol = "sparkles" }
        case .appStore:
            if let result = results.first(where: { $0.id == selectedAppID }),
               IconImageStore.shared.image(for: appStoreIconKey(result.id)) != nil {
                imageFile = appStoreIconKey(result.id)
                symbol = nil
            }
        case .web:
            if let image = webImage, let stored = IconImageStore.shared.store(image) {
                imageFile = stored
                symbol = nil
            }
        case .photos:
            if let image = photoImage, let stored = IconImageStore.shared.store(image) {
                imageFile = stored
                symbol = nil
            }
        }
        SelectionHaptics.success()
        dismiss()
    }
}


