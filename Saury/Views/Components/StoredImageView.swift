import SwiftUI

/// 从 `ImageStore` 里取一张图出来摆。
///
/// SwiftData 只存文件名，解图这件事不能踩主线程（方案 §74）；取哪一张有讲究：
/// 列表和图标只要 256px 的缩略图，详情页才解全尺寸原图（方案 §34）。
enum StoredImageLoader {
    @MainActor
    static func load(_ identifier: String?, original: Bool = false) async -> UIImage? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let priority: TaskPriority = original ? .userInitiated : .utility
        return await Task.detached(priority: priority) {
            original ? ImageStore.shared.image(for: identifier) : ImageStore.shared.thumbnail(for: identifier)
        }.value
    }
}

/// 点开看原图。留这张图的全部理由就是这一刻：日期到底写的是 1 还是 7，这里能自己看清。
struct StoredOriginalView: View {
    let identifier: String?
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                } else if loaded {
                    // 记录还在、图没了（换机、备份里没带图）：说清楚，比一直转圈诚实。
                    Text("这张照片不在这台设备上了")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 30)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { dismiss() }
                }
            }
        }
        .task {
            image = await StoredImageLoader.load(identifier, original: true)
            loaded = true
        }
    }
}

/// 详情页的主图（方案 §34：详情用全尺寸）。
///
/// 图没解出来就整块不摆，而不是留一个点不开的相框。
struct ItemPhotoCard: View {
    let item: ExpiryItem

    @State private var image: UIImage?
    @State private var showingOriginal = false

    var body: some View {
        Group {
            if let image {
                Button { showingOriginal = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看当时拍下的照片")
            }
        }
        .padding(.top, image == nil ? 0 : 18)
        .sheet(isPresented: $showingOriginal) {
            StoredOriginalView(identifier: item.imageIdentifier, title: item.name)
        }
        .task(id: item.imageIdentifier) {
            image = await StoredImageLoader.load(item.imageIdentifier, original: true)
        }
    }
}
