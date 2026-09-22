import SwiftUI

/// TabBar 中间那个 `+` 点开来的东西（方案 §19）。
///
/// 一个 sheet、五条路：连续扫描、扫包装、从相册、快速模板、自己填。扫完两条走
/// `ScanFlowModifier`，识别完先进确认界面再进表单（方案 §25：OCR 不直接盖用户数据）；
/// 连续扫描自己是一个全屏流程，确认即入库（方案 §20）。
struct AddOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    let onScan: (ScanRequest) -> Void
    let onContinuousScan: () -> Void
    let onQuickAdd: () -> Void
    let onManualAdd: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: QJMetric.section) {
                    group("拍一下就行") {
                        row("camera.viewfinder", "连续扫描",
                            "一件接一件拍，认完自动存好，接着拍下一件",
                            tint: QJTheme.accent, fill: QJTheme.accentSoft) {
                            onContinuousScan()
                        }
                        row("text.viewfinder", "扫包装上的日期",
                            "对准有效期喷码，认完逐项确认",
                            tint: QJTheme.accent, fill: QJTheme.accentSoft) {
                            onScan(.package)
                        }
                        row("photo.on.rectangle", "从相册识别",
                            "已经拍好的包装照片，在本机识别",
                            tint: QJTheme.calm, fill: QJTheme.calmSoft) {
                            onScan(.library)
                        }
                    }
                    group("自己填") {
                        row("plus.circle.fill", "添加物品",
                            "只要名称和有效期就能保存",
                            tint: QJTheme.accent, fill: QJTheme.accentSoft) {
                            onManualAdd()
                        }
                        row("square.grid.2x2", "快速添加",
                            "常用订阅和常用品，点一下就进来",
                            tint: QJTheme.calm, fill: QJTheme.calmSoft) {
                            onQuickAdd()
                        }
                    }
                }
                .padding(.horizontal, QJMetric.screen)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .background(QJTheme.canvas)
            .navigationTitle("添加")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(spacing: 9) {
                content()
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ note: String,
                     tint: Color, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(fill)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(QJTheme.ink)
                    Text(note).font(.caption).foregroundStyle(QJTheme.subtle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(QJTheme.subtle)
            }
            .padding(15)
            .qjCard()
        }
        .buttonStyle(.plain)
    }
}
