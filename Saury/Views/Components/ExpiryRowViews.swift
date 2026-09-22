import SwiftUI

/// 分类图形。颜色一律来自 `ExpiryUrgency`，分类只给形状，
/// 否则同一个物品会在不同页面显示成不同的紧急度。
///
/// 扫进来的物品有主图，列表就把缩略图压在分类图形上（方案 §34）；
/// 解图丢到后台线程，图不在设备上时留下的正好是原来那个分类图形。
struct ServiceIcon: View {
    let item: ExpiryItem
    let size: CGFloat
    var light = false
    /// 详情页下面已经摆了大图，头部那一小块就不该再来一份同样的照片。
    var showsPhoto = true

    @State private var photo: UIImage?

    var body: some View {
        badge
            .overlay {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.31, style: .continuous))
                }
            }
            .task(id: item.imageIdentifier) {
                guard showsPhoto else { photo = nil; return }
                photo = await StoredImageLoader.load(item.imageIdentifier)
            }
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(light ? .white.opacity(0.86) : QJTheme.accentSoft)
            Image(systemName: item.category.symbolName)
                .font(.system(size: size * 0.40, weight: .medium))
                .foregroundStyle(QJTheme.accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ExpiryItemRow: View {
    let item: ExpiryItem
    /// 同一件商品下有几个批次（方案 §30）。列表本身按 productKey 挨着排，
    /// 这里只负责让人一眼看出「不止一盒」。
    var batchCount = 1

    var body: some View {
        HStack(spacing: 11) {
            ServiceIcon(item: item, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(QJTheme.ink)
                        .lineLimit(1)
                    if batchCount > 1 {
                        Text("\(batchCount) 批")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(QJTheme.subtle)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(QJTheme.canvas)
                            .clipShape(Capsule())
                    }
                }
                Text(item.contextText)
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(ExpiryUrgency.label(daysRemaining: item.daysRemaining))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(item.urgency.textTint)
                Text(item.hasPrice ? item.formattedPrice : item.effectiveExpiryDate.qjDateText)
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
            }
        }
        .padding(.vertical, QJMetric.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
