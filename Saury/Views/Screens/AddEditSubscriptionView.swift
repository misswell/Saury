import SwiftUI
import SwiftData
import UserNotifications

struct AddEditSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let item: ExpiryItem?
    /// 「添加新批次」用的模板（方案 §31）：沿用商品身份，只重填日期和数量。
    let batchTemplate: ExpiryItem?

    @State private var name: String
    @State private var brand: String
    @State private var priceText: String
    @State private var currencyCode: String
    @State private var expiryDate: Date
    @State private var recurrence: ExpiryRecurrence
    @State private var recurrenceInterval: Int
    @State private var category: ExpiryCategory
    @State private var actionDeadline: Date?
    @State private var hasActionDeadline: Bool
    @State private var sourceURL: String
    @State private var notes: String
    @State private var quantityText: String
    @State private var unit: String
    @State private var location: String
    @State private var barcode: String
    @State private var batchNumber: String
    @State private var purchaseDate: Date
    @State private var hasPurchaseDate: Bool
    @State private var manufactureDate: Date
    @State private var hasManufactureDate: Bool
    @State private var shelfLifeText: String
    @State private var openedDate: Date
    @State private var hasOpenedDate: Bool
    @State private var afterOpeningText: String
    @State private var selectedReminderOffsets: Set<Int>
    @State private var showingPermissionPrompt = false
    @State private var isSaving = false
    @State private var scanRequest: ScanRequest?
    /// 从 TabBar 的 `+` 扫完之后带进来的结果，进表单时落一次（方案 §19）。
    @State private var pendingScan: ScanReviewView.Confirmation?
    /// 保存前发现同一批已经存在（方案 §29）：等用户选「加数量 / 仍然新增 / 取消」。
    @State private var duplicateMatch: ExpiryItem?
    @State private var pendingValues: FormValues?
    /// 这次带进来的那张原图（方案 §34）。保存时落盘，活动记录要把它摆出来。
    @State private var scanImage: UIImage?

    init(item: ExpiryItem? = nil, initialDraft: ExternalItemDraft? = nil,
         batchTemplate: ExpiryItem? = nil, scanned: ScanReviewView.Confirmation? = nil) {
        self.item = item
        self.batchTemplate = batchTemplate
        _pendingScan = State(initialValue: scanned)
        _scanImage = State(initialValue: scanned?.image)

        let draftExpiry = item?.expiryDate ?? initialDraft?.expiryDate
        let fallbackExpiry = draftExpiry
            ?? Calendar.current.date(byAdding: .month, value: 1, to: Date())
            ?? Date()

        _name = State(initialValue: item?.name ?? initialDraft?.name ?? batchTemplate?.name ?? "")
        _brand = State(initialValue: item?.brand ?? batchTemplate?.brand ?? "")
        _priceText = State(initialValue: Self.amountText(item?.priceMinorUnits ?? initialDraft?.priceMinorUnits))
        _currencyCode = State(initialValue: item?.currencyCode ?? initialDraft?.currencyCode ?? QJPreferences.defaultCurrencyCode)
        _expiryDate = State(initialValue: fallbackExpiry)
        _recurrence = State(initialValue: item?.recurrence ?? initialDraft?.recurrence ?? batchTemplate?.recurrence ?? .none)
        _recurrenceInterval = State(initialValue: item?.recurrenceInterval ?? 1)
        _category = State(initialValue: item?.category ?? initialDraft?.category ?? batchTemplate?.category ?? .other)
        _actionDeadline = State(initialValue: item?.actionDeadline)
        _hasActionDeadline = State(initialValue: item?.actionDeadline != nil)
        _sourceURL = State(initialValue: item?.sourceURL ?? "")
        _notes = State(initialValue: item?.notes ?? "")
        _quantityText = State(initialValue: item?.quantityText ?? "1")
        _unit = State(initialValue: item?.unit ?? batchTemplate?.unit ?? "件")
        _location = State(initialValue: item?.location ?? batchTemplate?.location ?? "")
        _barcode = State(initialValue: item?.barcode ?? batchTemplate?.barcode ?? "")
        _batchNumber = State(initialValue: item?.batchNumber ?? "")
        _purchaseDate = State(initialValue: item?.purchaseDate ?? Date())
        _hasPurchaseDate = State(initialValue: item?.purchaseDate != nil)
        _manufactureDate = State(initialValue: item?.manufactureDate ?? Date())
        _hasManufactureDate = State(initialValue: item?.manufactureDate != nil)
        _shelfLifeText = State(initialValue: item?.shelfLifeDays.map(String.init) ?? "")
        _openedDate = State(initialValue: item?.openedDate ?? Date())
        _hasOpenedDate = State(initialValue: item?.openedDate != nil)
        _afterOpeningText = State(initialValue: item?.afterOpeningDays.map(String.init) ?? "")
        _selectedReminderOffsets = State(initialValue: Set(
            item?.reminderOffsets ?? batchTemplate?.reminderOffsets
                ?? ReminderPolicy.defaultOffsets(for: item?.category ?? initialDraft?.category ?? batchTemplate?.category ?? .other)
        ))
    }

    /// 金额输入框显示「元」，不带币种符号：符号由右边的币种选择器表达。
    private static func amountText(_ minorUnits: Int?) -> String {
        guard let minorUnits else { return "" }
        return String(format: "%.2f", Double(minorUnits) / 100)
    }

    private var isBatchAdd: Bool { item == nil && batchTemplate != nil }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: QJMetric.section) {
                    intro
                    screenshotImport
                    basicFields
                    dateFields
                    reminderFields
                    extraFields
                }
                .padding(.horizontal, QJMetric.screen)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .background(QJTheme.canvas)
            .navigationTitle(titleText)
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
            Text("期见会按这个分类的默认计划提前提醒你。也可以稍后在系统设置里开启通知。")
        }
        .scanFlow(request: $scanRequest) { apply($0) }
        .onAppear {
            if let scanned = pendingScan {
                pendingScan = nil
                apply(scanned)
            }
            useTemplateDefaults()
        }
        .onChange(of: barcode) { _, _ in
            useTemplateDefaults()
        }
        // 方案 §29：同一批已经存在时问一句，别闷声存两条。
        .alert("可能已经存在这一批", isPresented: duplicateBinding) {
            Button("增加数量") {
                if let match = duplicateMatch, let values = pendingValues { commit(values, addingTo: match) }
                clearDuplicatePrompt()
            }
            Button("仍然新增") {
                if let values = pendingValues { commit(values) }
                clearDuplicatePrompt()
            }
            Button("取消", role: .cancel) { clearDuplicatePrompt() }
        } message: {
            Text(duplicateNote ?? "")
        }
    }

    private var duplicateBinding: Binding<Bool> {
        Binding(get: { duplicateMatch != nil }, set: { if !$0 { clearDuplicatePrompt() } })
    }

    private var duplicateNote: String? {
        guard let match = duplicateMatch else { return nil }
        var lines = ["「\(match.name)」已经在 \(QJFormatters.yearDate.string(from: match.expiryDate)) 到期，现在有 \(match.quantityText) \(match.unit)。"]
        if let batch = match.batchNumber, !batch.isEmpty { lines.append("批次号也是 \(batch)。") }
        lines.append("同一批只是又买了几个的话，选「增加数量」更准。")
        return lines.joined(separator: "")
    }

    private func clearDuplicatePrompt() {
        duplicateMatch = nil
        pendingValues = nil
    }

    /// 条码认得的商品，其余信息按上次的填（方案 §28）。只补空着的地方，
    /// 用户已经打过的字一律不动。
    private func useTemplateDefaults() {
        guard item == nil, let template = ProductTemplateStore.template(forBarcode: barcode, in: modelContext) else { return }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = template.name }
        if brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let templateBrand = template.brand { brand = templateBrand }
        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let locationValue = template.location { location = locationValue }
        if unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || unit == "件" { unit = template.unit }
        if category == .other { category = template.category }
        // 提醒计划只在没人动过的时候跟着模板走：默认的档位是分类算出来的，
        // 一旦用户勾掉过某档，就不该被一次扫码改回去。
        if selectedReminderOffsets == Set(ReminderPolicy.defaultOffsets(for: category)) {
            selectedReminderOffsets = Set(template.reminderOffsets)
        }
    }

    private var titleText: String {
        if item != nil { return "编辑物品" }
        return isBatchAdd ? "添加新批次" : "添加物品"
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.title3.weight(.medium))
                .foregroundStyle(QJTheme.ink)
            Text(subheadline)
                .font(.subheadline)
                .foregroundStyle(QJTheme.subtle)
        }
        .padding(.top, 5)
    }

    private var headline: String {
        if item != nil { return "保持日期和提醒计划准确。" }
        if isBatchAdd { return "这一批什么时候到期？" }
        return "只要名称和有效期就能保存。"
    }

    private var subheadline: String {
        if isBatchAdd {
            return "商品信息和提醒策略已经照着上一批填好了，只需要写日期和数量。"
        }
        return "期见不会读取你的支付信息，所有记录都保存在这台设备上。"
    }

    private var screenshotImport: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(QJTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("扫包装上的日期")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(QJTheme.ink)
                    Text("识别名称、有效日期、生产日期、保质期、开封期、批次和条码，全部在本机完成")
                        .font(.caption)
                        .foregroundStyle(QJTheme.subtle)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button {
                    scanRequest = .package
                } label: {
                    Label("拍照识别", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(QJTheme.accent)

                Button {
                    scanRequest = .library
                } label: {
                    Label("从相册识别", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(QJTheme.calm)
            }
        }
        .padding(15)
        .qjCard(fill: QJTheme.accentSoft.opacity(0.75), radius: 18)
    }

    private var basicFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldLabel("基本信息")
            QJTextField(title: "名称", text: $name, placeholder: "例如：牛奶、签证、视频会员")
            QJTextField(title: "品牌（可选）", text: $brand, placeholder: "例如：蒙牛")
            Picker("分类", selection: $category) {
                ForEach(ExpiryCategory.allCases) { category in Text(category.title).tag(category) }
            }
            .pickerStyle(.menu)
            .tint(QJTheme.ink)
            HStack(alignment: .bottom, spacing: 10) {
                QJTextField(title: "数量", text: $quantityText, placeholder: "1", keyboard: .decimalPad)
                    .frame(maxWidth: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text("单位").font(.caption).foregroundStyle(QJTheme.subtle)
                    Menu {
                        ForEach(UnitCatalog.builtIn, id: \.self) { option in
                            Button(option) { unit = option }
                        }
                    } label: {
                        HStack {
                            Text(unit.isEmpty ? "件" : unit)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline)
                        .foregroundStyle(QJTheme.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(QJTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                }
            }
            locationField
        }
        .padding(16)
        .qjCard(radius: 22)
        .onChange(of: category) { _, newValue in
            selectedReminderOffsets = Set(ReminderPolicy.defaultOffsets(for: newValue))
        }
    }

    private var locationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("位置").font(.caption).foregroundStyle(QJTheme.subtle)
            HStack(spacing: 8) {
                TextField("例如：冰箱第二层", text: $location)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(QJTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                Menu {
                    Button("不设置位置") { location = "" }
                    Divider()
                    ForEach(LocationCatalog.all, id: \.self) { option in
                        Button(option) { location = option }
                    }
                } label: {
                    Image(systemName: "signpost.right")
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(QJTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .frame(width: 52)
            }
        }
    }

    private var dateFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldLabel("有效期")
            DatePicker("到期日", selection: $expiryDate, displayedComponents: .date)
                .font(.subheadline)
                .tint(QJTheme.accent)

            Toggle("有生产日期和保质期", isOn: $hasManufactureDate)
                .font(.subheadline)
                .tint(QJTheme.accent)
            if hasManufactureDate {
                DatePicker("生产日期", selection: $manufactureDate, displayedComponents: .date)
                    .font(.subheadline)
                QJTextField(title: "保质期（天）", text: $shelfLifeText, placeholder: "例如：365", keyboard: .numberPad)
            }

            Toggle("开封后有单独有效期", isOn: $hasOpenedDate)
                .font(.subheadline)
                .tint(QJTheme.accent)
            if hasOpenedDate {
                DatePicker("开封日期", selection: $openedDate, displayedComponents: .date)
                    .font(.subheadline)
                QJTextField(title: "开封后可用（天）", text: $afterOpeningText, placeholder: "例如：30", keyboard: .numberPad)
            }

            Toggle("购买日期", isOn: $hasPurchaseDate)
                .font(.subheadline)
                .tint(QJTheme.accent)
            if hasPurchaseDate {
                DatePicker("购买于", selection: $purchaseDate, displayedComponents: .date)
                    .font(.subheadline)
            }

            Picker("是否重复", selection: $recurrence) {
                ForEach(ExpiryRecurrence.allCases) { recurrence in Text(recurrence.title).tag(recurrence) }
            }
            .pickerStyle(.menu)
            .tint(QJTheme.ink)
            if recurrence == .custom {
                Stepper(value: $recurrenceInterval, in: 1...60) {
                    Text("每 \(recurrenceInterval) 个月").font(.subheadline)
                }
            }
            Text("到期日以最早成立的那个为准：包装日期、生产日期 + 保质期、开封后有效期，三者取先到的。")
                .font(.caption)
                .foregroundStyle(QJTheme.subtle)
        }
        .padding(16)
        .qjCard(radius: 22)
    }

    private var reminderFields: some View {
        VStack(alignment: .leading, spacing: 13) {
            FieldLabel("提醒计划")
            Text("选择多个时间，给自己留出处理的余地。")
                .font(.caption)
                .foregroundStyle(QJTheme.subtle)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ReminderPolicy.presets(for: category)) { preset in
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
            HStack(spacing: 10) {
                QJTextField(title: "金额（可选）", text: $priceText, placeholder: "0.00", keyboard: .decimalPad)
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
            Toggle("设置最晚处理日", isOn: $hasActionDeadline)
                .tint(QJTheme.accent)
            if hasActionDeadline {
                DatePicker("最晚处理日", selection: Binding(get: { actionDeadline ?? expiryDate }, set: { actionDeadline = $0 }), displayedComponents: .date)
                    .font(.subheadline)
            }
            QJTextField(title: "条码", text: $barcode, placeholder: "690…", keyboard: .numbersAndPunctuation)
            QJTextField(title: "批次号", text: $batchNumber, placeholder: "包装上的生产批号")
            QJTextField(title: "管理链接", text: $sourceURL, placeholder: "https://…", keyboard: .URL)
            QJTextField(title: "备注", text: $notes, placeholder: "例如：给孩子的第二瓶")
        }
        .padding(16)
        .qjCard(radius: 22)
    }

    private func save() {
        guard let values = formValues() else { return }
        // 只有新建才查重（方案 §29）：编辑手里这一条，跟自己对「是不是重复」没有意义。
        if item == nil, let match = duplicate(of: values) {
            pendingValues = values
            duplicateMatch = match
            return
        }
        commit(values)
    }

    /// 同一件商品、同一天到期、同一个批次号 —— 那就别再存一条，问一句。
    private func duplicate(of values: FormValues) -> ExpiryItem? {
        ExpiryDuplicateCheck.match(
            ExpiryDuplicateCheck.candidate(
                barcode: values.barcode,
                name: values.name,
                expiryDate: values.expiryDate,
                batchNumber: values.batchNumber
            ),
            in: ((try? modelContext.fetch(FetchDescriptor<ExpiryItem>())) ?? [])
        )
    }

    private func commit(_ values: FormValues, addingTo existing: ExpiryItem? = nil) {
        isSaving = true
        let wasEmpty = ((try? modelContext.fetch(FetchDescriptor<ExpiryItem>())) ?? []).isEmpty

        // 三条路都得拿到「最后存下来的那一条」：原图和它的事件要挂在同一条物品上。
        let settled: ExpiryItem
        let eventType: ExpiryEventType
        if let existing {
            // 「增加数量」：同一批只是又买了两盒，不该多出一条记录。
            existing.quantity += max(values.quantity, 0)
            existing.markUpdated()
            settled = existing
            eventType = .edited
        } else if let item {
            apply(values, to: item)
            settled = item
            eventType = .edited
        } else {
            let created = ExpiryItem(
                name: values.name,
                brand: values.brand,
                category: values.category,
                expiryDate: values.expiryDate,
                manufactureDate: values.manufactureDate,
                purchaseDate: values.purchaseDate,
                openedDate: values.openedDate,
                shelfLifeDays: values.shelfLifeDays,
                afterOpeningDays: values.afterOpeningDays,
                barcode: values.barcode,
                batchNumber: values.batchNumber,
                quantity: max(values.quantity, 0),
                unit: values.unit,
                location: values.location,
                priceMinorUnits: values.price,
                currencyCode: values.currencyCode,
                recurrence: values.recurrence,
                recurrenceInterval: values.recurrenceInterval,
                actionDeadline: values.actionDeadline,
                sourceURL: values.sourceURL,
                reminderOffsets: values.reminders,
                notes: values.notes
            )
            modelContext.insert(created)
            settled = created
            eventType = .created
        }
        recordScan(of: settled, eventType: eventType)
        // 扫过的东西记一次（方案 §28）：下次同一个条码只需要填日期和数量。
        ProductTemplateStore.remember(settled, in: modelContext)
        modelContext.saveOrLog("保存物品")
        pendingValues = nil
        duplicateMatch = nil
        Task {
            await ExpiryActionCenter.shared.refresh(in: modelContext)
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

    /// 扫出来的那一条要在活动记录里留下原图（方案 §34）。手填的没有图，也就不留这一条。
    private func recordScan(of item: ExpiryItem, eventType: ExpiryEventType) {
        guard let scanImage else { return }
        self.scanImage = nil
        let identifier = ImageStore.shared.store(scanImage)
        // 存不下也不影响这条记录成立；但别让一次失败的写入把上一次的图抹掉。
        if let identifier { item.imageIdentifier = identifier }
        modelContext.insert(ExpiryEvent(eventType: eventType, for: item, imageIdentifier: identifier))
    }

    private func formValues() -> FormValues? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let trimmedPrice = priceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let price = trimmedPrice.isEmpty ? nil : QJMoney.minorUnits(from: trimmedPrice, currencyCode: currencyCode)
        let reminders = selectedReminderOffsets.sorted(by: >)
        return FormValues(
            name: trimmedName,
            brand: trimmed(brand),
            expiryDate: expiryDate,
            purchaseDate: hasPurchaseDate ? purchaseDate : nil,
            manufactureDate: hasManufactureDate ? manufactureDate : nil,
            openedDate: hasOpenedDate ? openedDate : nil,
            shelfLifeDays: positiveInt(shelfLifeText),
            afterOpeningDays: positiveInt(afterOpeningText),
            barcode: trimmed(barcode),
            batchNumber: trimmed(batchNumber),
            quantity: Double(quantityText.replacingOccurrences(of: ",", with: ".")) ?? 1,
            unit: trimmed(unit) ?? "件",
            location: trimmed(location),
            price: price,
            currencyCode: price == nil ? nil : currencyCode,
            recurrence: recurrence,
            recurrenceInterval: recurrence == .custom ? max(recurrenceInterval, 1) : nil,
            actionDeadline: hasActionDeadline ? actionDeadline : nil,
            sourceURL: trimmed(sourceURL),
            reminders: reminders.isEmpty ? ReminderPolicy.defaultOffsets(for: category) : reminders,
            notes: notes,
            category: category
        )
    }

    private func apply(_ values: FormValues, to item: ExpiryItem) {
        item.name = values.name
        item.brand = values.brand
        item.category = values.category
        item.expiryDate = values.expiryDate
        // 手动改期等于换锚点；续费推进走 ExpiryRepository，不会覆盖这里。
        item.anchorDay = ExpiryEngine.calendar.component(.day, from: values.expiryDate) ?? item.anchorDay
        item.purchaseDate = values.purchaseDate
        item.manufactureDate = values.manufactureDate
        item.openedDate = values.openedDate
        item.shelfLifeDays = values.shelfLifeDays
        item.afterOpeningDays = values.afterOpeningDays
        item.barcode = values.barcode
        item.batchNumber = values.batchNumber
        item.quantity = max(values.quantity, 0)
        item.unit = values.unit
        item.location = values.location
        item.priceMinorUnits = values.price
        item.currencyCode = values.currencyCode
        item.recurrence = values.recurrence
        item.recurrenceInterval = values.recurrenceInterval
        item.actionDeadline = values.actionDeadline
        item.sourceURL = values.sourceURL
        item.reminderOffsets = values.reminders
        item.notes = values.notes
    }

    private func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func positiveInt(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }

    /// 确认界面上点过的结果才写进表单（方案 §25：OCR 不直接盖用户数据）。
    private func apply(_ confirmation: ScanReviewView.Confirmation) {
        let result = confirmation.result
        scanImage = confirmation.image
        if let value = result.text(for: .name), !value.isEmpty { name = value }
        if let value = result.text(for: .brand), brand.isEmpty { brand = value }
        if let value = result.date(for: .expiryDate) { expiryDate = value }
        if let value = result.date(for: .manufactureDate) {
            manufactureDate = value
            hasManufactureDate = true
        }
        if let life = result.duration(for: .shelfLife) { shelfLifeText = String(life.approxDays) }
        if let life = result.duration(for: .afterOpening) {
            afterOpeningText = String(life.approxDays)
            if confirmation.openedToday {
                openedDate = Date()
                hasOpenedDate = true
            }
        }
        if let value = result.text(for: .batchNumber) { batchNumber = value }
        if let value = result.text(for: .barcode), barcode.isEmpty { barcode = value }
        if let amount = result.amount(for: .amount) {
            priceText = String(format: "%.2f", Double(amount.minorUnits) / 100)
            currencyCode = amount.currencyCode
        }
    }
}

/// 表单一次提交要落下的全部值。收在一起是为了让「新建」和「编辑」
/// 走同一份清洗规则，不至于两条路径存出两种数据。
private struct FormValues {
    var name: String
    var brand: String?
    var expiryDate: Date
    var purchaseDate: Date?
    var manufactureDate: Date?
    var openedDate: Date?
    var shelfLifeDays: Int?
    var afterOpeningDays: Int?
    var barcode: String?
    var batchNumber: String?
    var quantity: Double
    var unit: String
    var location: String?
    var price: Int?
    var currencyCode: String?
    var recurrence: ExpiryRecurrence
    var recurrenceInterval: Int?
    var actionDeadline: Date?
    var sourceURL: String?
    var reminders: [Int]
    var notes: String
    var category: ExpiryCategory
}

struct FieldLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).font(.headline.weight(.medium)).foregroundStyle(QJTheme.ink) }
}

struct QJTextField: View {
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
