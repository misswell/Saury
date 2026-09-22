import SwiftUI
import SwiftData
import UserNotifications
import PhotosUI

struct AddEditSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let item: RenewalItem?
    @State private var name: String
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var nextRenewalDate: Date
    @State private var cycle: RenewalCycle
    @State private var intervalMonths: Int
    @State private var category: RenewalCategory
    @State private var isAutoRenewing: Bool
    @State private var cancelByDate: Date?
    @State private var hasCancelByDate: Bool
    @State private var managementURL: String
    @State private var notes: String
    @State private var selectedReminderOffsets: Set<Int>
    @State private var showingPermissionPrompt = false
    @State private var isSaving = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isRecognizingScreenshot = false
    @State private var ocrMessage: String?

    init(item: RenewalItem? = nil, initialDraft: ExternalRenewalDraft? = nil) {
        self.item = item
        _name = State(initialValue: item?.name ?? initialDraft?.name ?? "")
        _amountText = State(initialValue: item.map { String(format: "%.2f", Double($0.amountMinorUnits) / 100) } ?? initialDraft?.amountMinorUnits.map { String(format: "%.2f", Double($0) / 100) } ?? "")
        _currencyCode = State(initialValue: item?.currencyCode ?? initialDraft?.currencyCode ?? QJPreferences.defaultCurrencyCode)
        _nextRenewalDate = State(initialValue: item?.nextRenewalDate ?? initialDraft?.renewalDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date())
        _cycle = State(initialValue: item?.cycle ?? initialDraft?.cycle ?? .monthly)
        _intervalMonths = State(initialValue: item?.intervalMonths ?? 1)
        _category = State(initialValue: item?.category ?? .other)
        _isAutoRenewing = State(initialValue: item?.isAutoRenewing ?? true)
        _cancelByDate = State(initialValue: item?.cancelByDate)
        _hasCancelByDate = State(initialValue: item?.cancelByDate != nil)
        _managementURL = State(initialValue: item?.managementURLString ?? "")
        _notes = State(initialValue: item?.notes ?? "")
        let initialCycle = item?.cycle ?? initialDraft?.cycle ?? .monthly
        _selectedReminderOffsets = State(initialValue: Set(item?.reminderOffsets ?? QJPreferences.reminderOffsets(for: initialCycle)))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    intro
                    screenshotImport
                    basicFields
                    reminderFields
                    extraFields
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .background(QJTheme.canvas)
            .navigationTitle(item == nil ? "添加到期提醒" : "编辑订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert("从现在开始提前提醒", isPresented: $showingPermissionPrompt) {
            Button("开启提醒") {
                Task {
                    _ = await ReminderScheduler.shared.requestAuthorization()
                    dismiss()
                }
            }
            Button("稍后", role: .cancel) { dismiss() }
        } message: {
            Text("期见会在到期前 7 天、3 天、1 天和当天提醒你。你也可以稍后在系统设置里开启通知。")
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task { await recognize(newValue) }
        }
        .alert("截图识别", isPresented: Binding(get: { ocrMessage != nil }, set: { if !$0 { ocrMessage = nil } })) {
            Button("好的", role: .cancel) { ocrMessage = nil }
        } message: { Text(ocrMessage ?? "") }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item == nil ? "记录一次，少一次忘记。" : "保持日期和提醒计划准确。")
                .font(.title3.weight(.medium))
                .foregroundStyle(QJTheme.ink)
            Text("期见不会读取你的支付信息，所有记录都保存在这台设备上。")
                .font(.subheadline)
                .foregroundStyle(QJTheme.subtle)
        }
        .padding(.top, 5)
    }

    private var screenshotImport: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .automatic) {
            HStack(spacing: 10) {
                Image(systemName: isRecognizingScreenshot ? "hourglass" : "text.viewfinder")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(QJTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isRecognizingScreenshot ? "正在识别截图…" : "从截图快速填写")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(QJTheme.ink)
                    Text("识别名称、金额和到期日，结果只保存在本机")
                        .font(.caption)
                        .foregroundStyle(QJTheme.subtle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(QJTheme.subtle)
            }
            .padding(15)
            .qjCard(fill: QJTheme.accentSoft.opacity(0.75), radius: 18)
        }
        .disabled(isRecognizingScreenshot)
    }

    private var basicFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldLabel("基本信息")
            QJTextField(title: "订阅名称", text: $name, placeholder: "例如：视频会员")
            HStack(spacing: 10) {
                QJTextField(title: "续费金额", text: $amountText, placeholder: "0.00", keyboard: .decimalPad)
                VStack(alignment: .leading, spacing: 6) {
                    Text("币种").font(.caption).foregroundStyle(QJTheme.subtle)
                    Picker("币种", selection: $currencyCode) {
                        Text("人民币 ¥").tag("CNY")
                        Text("美元 $").tag("USD")
                        Text("港币 HK$").tag("HKD")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(QJTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
            DatePicker("下次到期日", selection: $nextRenewalDate, displayedComponents: .date)
                .font(.subheadline)
                .tint(QJTheme.accent)
            Picker("周期", selection: $cycle) {
                ForEach(RenewalCycle.allCases) { cycle in Text(cycle.title).tag(cycle) }
            }
            .pickerStyle(.menu)
            .tint(QJTheme.ink)
            if cycle == .customMonths {
                Stepper(value: $intervalMonths, in: 1...24) { Text("每 \(intervalMonths) 个月续费").font(.subheadline) }
            }
            Picker("分类", selection: $category) {
                ForEach(RenewalCategory.allCases) { category in Text(category.title).tag(category) }
            }
            .pickerStyle(.menu)
            .tint(QJTheme.ink)
        }
        .padding(16)
        .qjCard(radius: 22)
    }

    private var reminderFields: some View {
        VStack(alignment: .leading, spacing: 13) {
            FieldLabel("提醒计划")
            Text("选择多个时间，给自己留出取消或继续的余地。")
                .font(.caption)
                .foregroundStyle(QJTheme.subtle)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(reminderPresets) { preset in
                    Button {
                        if selectedReminderOffsets.contains(preset.minutesBefore) {
                            selectedReminderOffsets.remove(preset.minutesBefore)
                        } else {
                            selectedReminderOffsets.insert(preset.minutesBefore)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: selectedReminderOffsets.contains(preset.minutesBefore) ? "checkmark.circle.fill" : "circle")
                            Text(preset.title)
                            Spacer()
                        }
                        .font(.subheadline)
                        .foregroundStyle(selectedReminderOffsets.contains(preset.minutesBefore) ? QJTheme.accent : QJTheme.subtle)
                        .padding(11)
                        .background(selectedReminderOffsets.contains(preset.minutesBefore) ? QJTheme.accentSoft : QJTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(selectedReminderOffsets.contains(preset.minutesBefore) ? QJTheme.accent.opacity(0.35) : QJTheme.line, lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .qjCard(radius: 22)
    }

    private var extraFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldLabel("可选信息")
            Toggle("自动续费", isOn: $isAutoRenewing)
                .tint(QJTheme.accent)
            Toggle("设置取消截止日", isOn: $hasCancelByDate)
                .tint(QJTheme.accent)
            if hasCancelByDate {
                DatePicker("最晚取消日期", selection: Binding(get: { cancelByDate ?? nextRenewalDate }, set: { cancelByDate = $0 }), displayedComponents: .date)
                    .font(.subheadline)
            }
            QJTextField(title: "管理链接", text: $managementURL, placeholder: "https://…", keyboard: .URL)
            QJTextField(title: "备注", text: $notes, placeholder: "例如：从 App Store 订阅")
        }
        .padding(16)
        .qjCard(radius: 22)
    }

    private var reminderPresets: [ReminderPreset] {
        let values: [Int]
        switch cycle {
        case .yearly: values = [30 * 24 * 60, 7 * 24 * 60, 24 * 60, 0]
        case .freeTrial: values = [3 * 24 * 60, 24 * 60, 3 * 60]
        case .oneTime: values = [7 * 24 * 60, 24 * 60, 0]
        default: values = [7 * 24 * 60, 3 * 24 * 60, 24 * 60, 0]
        }
        return values.map(ReminderPreset.init(minutesBefore:))
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        let amount = max(Int((Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0) * 100), 0)
        let reminders = selectedReminderOffsets.sorted(by: >)
        let wasEmpty = ((try? modelContext.fetch(FetchDescriptor<RenewalItem>())) ?? []).isEmpty
        if let item {
            item.name = trimmedName
            item.amountMinorUnits = amount
            item.currencyCode = currencyCode
            item.nextRenewalDate = nextRenewalDate
            item.anchorDay = Calendar.current.component(.day, from: nextRenewalDate)
            item.cycle = cycle
            item.intervalMonths = max(intervalMonths, 1)
            item.category = category
            item.isAutoRenewing = isAutoRenewing
            item.cancelByDate = hasCancelByDate ? cancelByDate : nil
            item.reminderOffsets = reminders.isEmpty ? cycle.defaultReminderOffsets : reminders
            item.managementURLString = managementURL
            item.notes = notes
            item.status = .active
            item.markUpdated()
        } else {
            modelContext.insert(RenewalItem(name: trimmedName, amountMinorUnits: amount, currencyCode: currencyCode, nextRenewalDate: nextRenewalDate, cycle: cycle, intervalMonths: intervalMonths, category: category, isAutoRenewing: isAutoRenewing, cancelByDate: hasCancelByDate ? cancelByDate : nil, reminderOffsets: reminders.isEmpty ? cycle.defaultReminderOffsets : reminders, managementURLString: managementURL, notes: notes))
        }
        try? modelContext.save()
        Task {
            let allItems = (try? modelContext.fetch(FetchDescriptor<RenewalItem>())) ?? []
            WidgetSnapshotStore.update(items: allItems)
            await ReminderScheduler.shared.rescheduleAll(items: allItems)
            let status = await ReminderScheduler.shared.authorizationStatus()
            await MainActor.run {
                isSaving = false
                if wasEmpty && status == .notDetermined {
                    showingPermissionPrompt = true
                } else {
                    dismiss()
                }
            }
        }
    }

    private func recognize(_ photo: PhotosPickerItem) async {
        isRecognizingScreenshot = true
        defer { isRecognizingScreenshot = false }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw SubscriptionOCRError.invalidImage }
            let draft = try await SubscriptionOCRService().recognize(image: image)
            await MainActor.run {
                if let value = draft.name { name = value }
                if let amount = draft.amountMinorUnits { amountText = String(format: "%.2f", Double(amount) / 100) }
                currencyCode = draft.currencyCode
                if let date = draft.renewalDate { nextRenewalDate = date }
                if let cycleValue = draft.cycle { cycle = cycleValue; selectedReminderOffsets = Set(cycleValue.defaultReminderOffsets) }
            }
        } catch {
            await MainActor.run { ocrMessage = error.localizedDescription }
        }
    }
}

private struct FieldLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).font(.headline.weight(.medium)).foregroundStyle(QJTheme.ink) }
}

private struct QJTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(QJTheme.subtle)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .background(QJTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}
