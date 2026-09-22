import SwiftUI
import SwiftData

/// 推迟一条提醒（方案 §45）。每个档位都把真正的触发时间写在右边：
/// 「今晚」在晚上十点半选到的是明晚，这句话必须让用户看得见。
struct SnoozeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let item: ExpiryItem

    @State private var customDate = Date().addingTimeInterval(24 * 60 * 60)

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 5) {
                Text("稍后再提醒").font(.headline)
                Text(item.name)
                    .font(.subheadline)
                    .foregroundStyle(QJTheme.subtle)
            }
            .padding(.top, 22)
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                ForEach(SnoozeChoice.presets, id: \.self) { choice in
                    Button { apply(choice) } label: {
                        HStack {
                            Text(choice.title).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(choice.fireDate().qjShortDateTimeText)
                                .font(.subheadline)
                                .foregroundStyle(QJTheme.subtle)
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(QJTheme.ink)
                    if choice != SnoozeChoice.presets.last { Divider().overlay(QJTheme.line) }
                }
            }
            .padding(.horizontal, QJMetric.card)
            .qjCard(fill: QJTheme.elevated, radius: 16)

            VStack(spacing: 12) {
                DatePicker("自定义时间", selection: $customDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .tint(QJTheme.accent)
                Button { apply(.custom(customDate)) } label: {
                    Text("就定这个时间")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(QJTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 16)

            Button("取消", role: .cancel) { dismiss() }
                .font(.subheadline)
                .foregroundStyle(QJTheme.subtle)
                .padding(.vertical, 16)
        }
        .padding(.horizontal, QJMetric.screen)
        .background(QJTheme.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func apply(_ choice: SnoozeChoice) {
        let context = modelContext
        Task {
            await ExpiryActionCenter.shared.perform(.snoozed, on: item, in: context, snoozeChoice: choice)
            dismiss()
        }
    }
}
