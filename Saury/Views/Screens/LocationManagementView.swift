import SwiftUI

/// 位置清单的增删改排序（方案 §33）。这里改的是建议清单，
/// 已经记在某个位置上的物品不会因为清单被删就丢失自己的位置。
struct LocationManagementView: View {
    @State private var names = LocationCatalog.all
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(names.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.footnote)
                            .foregroundStyle(QJTheme.subtle)
                        TextField("位置名称", text: $names[index])
                            .textFieldStyle(.plain)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) { names.remove(at: index) }
                    }
                }
                .onMove { offsets, destination in
                    names.move(fromOffsets: offsets, toOffset: destination)
                }
            } header: {
                Text("位置")
            } footer: {
                Text("拖动排序决定了它们在添加表单和首页里的先后。")
            }

            Section {
                HStack(spacing: 10) {
                    TextField("新增位置，例如「车库」", text: $newName)
                        .textFieldStyle(.plain)
                    Button("添加", action: add)
                        .fontWeight(.semibold)
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section {
                Button("恢复默认位置", role: .destructive) {
                    names = LocationCatalog.builtIn
                }
            } footer: {
                Text("删除位置只会把它从清单里去掉，已经记在这个位置上的物品不受影响。")
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background(QJTheme.canvas)
        .navigationTitle("位置管理")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: names) { _, next in
            LocationCatalog.replace(next)
        }
    }

    private func add() {
        let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !names.contains(value) else { return }
        names.append(value)
        newName = ""
    }
}
