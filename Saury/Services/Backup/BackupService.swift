import Foundation
import SwiftData
import UniformTypeIdentifiers

/// 完整备份的打包与恢复（任务书 §3.1）。
///
/// 三条硬规矩写在这里：
/// 1. 打包不带「看起来成功」——清单记的条数和摘要都是实际写进包里的东西；
/// 2. 恢复要么整批落盘、要么一条不写，半途出错绝不留半套数据还报成功；
/// 3. 恢复完必须做统计与事件关联校验，报出来的数字来自库里的真实行，不是备份里的期望值。
@MainActor
enum BackupService {
    static let fileExtension = "saurybackup"

    /// 备份文件的类型：`com.guofeng.saury.backup`，扩展名 `.saurybackup`，
    /// 由 Info.plist 的 `UTExportedTypeDeclarations` 声明 —— 没登记的话，包发到文件 App
    /// 就成了「未知类型」，选回来时也认不出该交给谁。
    /// 容器自己还带文件头校验，所以类型认错了也只是读的时候报一句，不会写坏数据。
    static var documentType: UTType {
        UTType(exportedAs: "com.guofeng.saury.backup")
    }

    enum Failure: LocalizedError, Equatable {
        case unsupportedSchemaVersion(Int)
        case documentPartMissing
        case documentUnreadable
        case emptyBackup

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                return "这份备份的内容版本是 V\(version)，这个版本的 App 读不了它"
            case .documentPartMissing:
                return "备份里没有正文那一份数据，只有清单和图标"
            case .documentUnreadable:
                return "备份正文读不出来，文件可能已经损坏"
            case .emptyBackup:
                return "这份备份里什么都没有：没有订阅、没有历史、也没有分类和设置，多半是拿错了文件"
            }
        }
    }

    // MARK: - 打包

    /// 打好的一个备份包：字节、文件名、清单，外加「本机已经没有原图」的那几个图标名。
    /// 包里的一切都由清单记账，这几个字段只是把清单里的说法摊开给界面用。
    struct BackupFile {
        let fileName: String
        let data: Data
        let manifest: BackupManifest
        /// 订阅身上还指着图，但本机磁盘上已经没有那个文件了：包里带不出不存在的东西。
        let missingIconFileNames: [String]

        var summaryText: String {
            var text = "已打包 \(manifest.subscriptionCount) 条订阅、\(manifest.eventCount) 条事件、\(manifest.iconCount) 个图标"
            if !missingIconFileNames.isEmpty {
                text += "；\(missingIconFileNames.count) 个图标本机已经没有文件，没进包"
            }
            return text
        }
    }

    /// 把当前库里的一切打成一个备份包。
    ///
    /// 归档和回收站里的订阅也一起走：那些同样是用户的数据，只挑「在用的」会在恢复后
    /// 凭空少掉一块。图标取磁盘上的原始字节，重新编码会产出另一份数据、摘要就对不上清单了。
    static func build(context: ModelContext,
                      preferences: SubPreferences,
                      icons: IconImageStore = .shared) throws -> BackupFile {
        let subscriptions = (try? context.fetch(FetchDescriptor<Subscription>())) ?? []
        let events = (try? context.fetch(FetchDescriptor<SubscriptionEvent>())) ?? []

        // 图标按订阅身上的文件名收，一台机器上同一张图可能被多条订阅共用，只进包一次。
        var iconFileNames: [String] = []
        var missing: [String] = []
        var iconBlocks: [BackupContainer.Part] = []
        for subscription in subscriptions {
            guard let file = subscription.iconImageFile, !file.isEmpty, !iconFileNames.contains(file) else { continue }
            guard let data = icons.data(for: file) else {
                missing.append(file)
                continue
            }
            iconFileNames.append(file)
            iconBlocks.append(.init(name: BackupManifest.iconPartName(forFile: file), data: data))
        }

        let payload = BackupPayload(exportedAt: Date(),
                                   subscriptions: subscriptions.map(BackupSubscription.init),
                                   events: events.map(BackupEvent.init),
                                   categories: preferences.categories,
                                   paymentMethods: preferences.paymentMethods,
                                   preferences: .current(from: preferences),
                                   iconFileNames: iconFileNames)
        let document = BackupContainer.Part(name: BackupManifest.documentPartName,
                                           data: try JSONEncoder.backup.encode(payload))

        // 清单里的 parts 顺序就是文件里的块顺序，读的时候一一对位，错位就当损坏报出来。
        var manifestParts: [BackupManifest.Part] = [
            .init(name: document.name,
                  sha256: BackupContainer.sha256(document.data),
                  byteLength: document.data.count,
                  kind: .document)
        ]
        manifestParts += iconBlocks.map {
            BackupManifest.Part(name: $0.name,
                                sha256: BackupContainer.sha256($0.data),
                                byteLength: $0.data.count,
                                kind: .icon)
        }
        let manifest = BackupManifest(schemaVersion: BackupPayload.schemaVersion,
                                     createdAt: Date(),
                                     appVersion: appVersion,
                                     subscriptionCount: payload.subscriptions.count,
                                     eventCount: payload.events.count,
                                     iconCount: iconFileNames.count,
                                     parts: manifestParts)
        let manifestData = try JSONEncoder.backup.encode(manifest)
        return BackupFile(fileName: fileName(date: payload.exportedAt),
                          data: try BackupContainer.write(manifest: manifestData, parts: [document] + iconBlocks),
                          manifest: manifest,
                          missingIconFileNames: missing)
    }

    static func fileName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "期见备份-\(formatter.string(from: date)).\(fileExtension)"
    }

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - 读包

    /// 一份备份文件读完之后的样子：清单、正文、图标字节，加上文件本身。
    /// 四者出自同一次读取，所以清单说的条数和正文里的条数是同一份事实。
    struct Contents: Identifiable {
        /// 每次读盘生成一个，只用来让 SwiftUI 知道「这是新的一份」，不参与数据比较。
        let id = UUID()
        /// 备份文件的原始字节。带着它，恢复这一步不必再依赖文件还在不在原地。
        let data: Data
        let manifest: BackupManifest
        let payload: BackupPayload
        /// 图标：备份里的块名 → 原始字节。
        let icons: [String: Data]
    }

    /// 只读清单：预览页要先把「这份包里有什么」摆出来，再决定读不读那几十张图。
    static func inspect(_ data: Data) throws -> BackupManifest {
        if isContainer(data) { return try BackupContainer.readManifest(data) }
        return try legacyManifest(from: data)
    }

    static func read(_ data: Data) throws -> Contents {
        guard isContainer(data) else { return try legacyContents(from: data) }
        let (manifest, parts) = try BackupContainer.read(data)
        guard manifest.schemaVersion == BackupPayload.schemaVersion else {
            throw Failure.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard let document = parts[BackupManifest.documentPartName] else { throw Failure.documentPartMissing }
        guard let payload = try? JSONDecoder.backup.decode(BackupPayload.self, from: document) else {
            throw Failure.documentUnreadable
        }
        var icons: [String: Data] = [:]
        for part in manifest.iconParts {
            guard let file = BackupManifest.iconFile(forPart: part.name), let bytes = parts[part.name] else { continue }
            icons[file] = bytes
        }
        return Contents(data: data, manifest: manifest, payload: payload, icons: icons)
    }

    private static func isContainer(_ data: Data) -> Bool {
        data.count >= BackupContainer.magic.count && data.prefix(BackupContainer.magic.count) == BackupContainer.magic
    }

    // MARK: - 旧版 JSON（V1）兼容

    /// V1 是当年那一份纯 JSON。它没有稳定编号，所以转进来的订阅只能现场发号：
    /// 重复恢复时的去重靠「名字 + 金额 + 币种 + 周期 + 创建时间」这条内容指纹，
    /// 报告里会写清楚这是按内容判的重复，不是按编号。
    static func legacyPayload(from data: Data) throws -> BackupPayload {
        guard let decoded = try? JSONDecoder.backup.decode(SubscriptionImportExport.ExportPayload.self, from: data) else {
            throw BackupContainer.Failure.notABackupFile
        }
        let subscriptions = decoded.subscriptions.map { item in
            BackupSubscription(Subscription(
                name: item.name,
                plan: item.plan,
                iconSymbolName: item.iconSymbolName,
                iconImageFile: item.iconImageFile,
                iconColorHex: item.iconColorHex,
                colorSpec: CardColorSpec(hexes: item.colorHexes),
                priceMinorUnits: item.priceMinorUnits,
                currencyCode: item.currencyCode,
                cycle: BillingCycle(rawValue: item.cycle) ?? .monthly,
                customMonths: item.customMonths,
                category: item.category,
                state: SubscriptionState(rawValue: item.state) ?? .autoRenew,
                startDate: item.startDate,
                endDate: item.endDate,
                remindersEnabled: item.resolvedRemindersEnabled,
                reminderDays: item.reminderDays,
                shareEnabled: item.shareEnabled,
                shareHeadcount: item.shareHeadcount,
                shareMode: ShareMode(rawValue: item.shareMode) ?? .even,
                shareMyMinorUnits: item.shareMyMinorUnits,
                paymentMethod: item.paymentMethod,
                notes: item.notes,
                createdAt: item.createdAt
            ))
        }
        // 事件在 V1 里只记了订阅名字，按名字认领；同名多条时全部指给第一条，
        // 这比整批丢掉真实历史要接近用户看到的样子，报告里也会说明。
        var nameToID: [String: UUID] = [:]
        for item in subscriptions where nameToID[item.name] == nil { nameToID[item.name] = item.id }
        let events = decoded.events.compactMap { item -> BackupEvent? in
            guard let subscriptionID = nameToID[item.subscriptionName] else { return nil }
            return BackupEvent(SubscriptionEvent(id: UUID(),
                                                 subscriptionID: subscriptionID,
                                                 type: SubscriptionEventType(rawValue: item.type) ?? .note,
                                                 amountMinorUnits: item.amountMinorUnits,
                                                 currencyCode: item.currencyCode,
                                                 note: item.note,
                                                 happenedAt: item.happenedAt))
        }
        return BackupPayload(exportedAt: decoded.exportedAt,
                            subscriptions: subscriptions,
                            events: events,
                            // V1 不带分类和支付方式清单，用当前 App 的内置项补齐。
                            categories: DefaultCategories.items,
                            paymentMethods: PaymentCatalog.builtIn,
                            preferences: BackupPreferences(),
                            iconFileNames: subscriptions.compactMap(\.iconImageFile))
    }

    private static func legacyContents(from data: Data) throws -> Contents {
        let payload = try legacyPayload(from: data)
        return Contents(data: data, manifest: try legacyManifest(from: data), payload: payload, icons: [:])
    }

    private static func legacyManifest(from data: Data) throws -> BackupManifest {
        let payload = try legacyPayload(from: data)
        return BackupManifest(schemaVersion: 1,
                             createdAt: payload.exportedAt,
                             appVersion: "旧版 JSON",
                             subscriptionCount: payload.subscriptions.count,
                             eventCount: payload.events.count,
                             iconCount: 0,
                             parts: [])
    }

    // MARK: - 恢复

    /// 一次恢复的实况：写了多少、跳过了多少、图标怎么样，以及恢复完之后库里的数字对不对。
    /// `summaryText` 只报这些实际发生的数，不报备份文件里「本来应该有」的数。
    struct Report {
        var schemaVersion: Int
        var manifest: BackupManifest
        var counts: SubscriptionRepository.RestoreCounts
        /// 旧版备份按内容判出来、因此没有再写一遍的订阅条数。
        var duplicatesSkippedByContent: Int
        /// 跟着上面那些重复订阅一起留下的历史事件条数。
        var eventsSkippedAsDuplicates: Int
        var issues: [BackupPayload.Issue]
        var iconsWritten: Int
        var iconWriteFailures: [String]
        var consistency: Consistency
        var mode: SubscriptionRepository.RestoreMode

        var isClean: Bool { consistency.problems.isEmpty && iconWriteFailures.isEmpty }

        var summaryText: String {
            var lines: [String] = []
            let written = counts.subscriptionsInserted + counts.subscriptionsUpdated
            var head = "已恢复 \(written) 条订阅（新增 \(counts.subscriptionsInserted)、覆盖 \(counts.subscriptionsUpdated)）"
            if counts.subscriptionsSkipped > 0 { head += "，本机已有、按「本机优先」跳过 \(counts.subscriptionsSkipped)" }
            if duplicatesSkippedByContent > 0 {
                head += "，内容重复没再写 \(duplicatesSkippedByContent)"
                if eventsSkippedAsDuplicates > 0 { head += "（连带 \(eventsSkippedAsDuplicates) 条已导入过的历史）" }
            }
            lines.append(head)
            lines.append("事件 \(counts.eventsInserted) 条新增、\(counts.eventsUpdated) 条已存在"
                + (counts.eventsSkipped > 0 ? "，\(counts.eventsSkipped) 条因为找不到所属订阅没写" : ""))
            if manifest.iconCount > 0 || iconsWritten > 0 {
                lines.append("图标 \(iconsWritten) 张已写回"
                    + (iconWriteFailures.isEmpty ? "" : "，\(iconWriteFailures.count) 张写不进去")
                    + (consistency.missingIconFiles.isEmpty ? "" : "，\(consistency.missingIconFiles.count) 个订阅要的图标包里没带"))
            }
            if let note = schemaNote { lines.append(note) }
            lines.append(consistency.problems.isEmpty ? "恢复后校验：条数、金额、事件关联都对得上" : "恢复后校验发现 \(consistency.problems.count) 处不对：" )
            lines.append(contentsOf: consistency.problems.map { "· \($0)" })
            if !issues.isEmpty {
                lines.append("备份本身有 \(issues.count) 处可疑，坏的那几条没写：")
                lines.append(contentsOf: issues.map { "· \($0.text)" })
            }
            return lines.joined(separator: "\n")
        }

        private var schemaNote: String? {
            guard schemaVersion == 1 else { return nil }
            return "这是旧版 JSON 备份：里面没有稳定编号，重复恢复时按名字、金额、币种、周期和创建时间判重"
        }
    }

    /// 恢复完成后拿库里的真实数据对一遍：数量、金额、事件指向、图标引用。
    struct Consistency: Equatable {
        var eventsExpected: Int
        var missingSubscriptionNames: [String]
        var amountMismatches: [String]
        var orphanEvents: Int
        var eventShortfall: Int
        var missingIconFiles: [String]

        var problems: [String] {
            var list: [String] = []
            if !missingSubscriptionNames.isEmpty {
                list.append("\(missingSubscriptionNames.count) 条订阅写完了却查不到：\(missingSubscriptionNames.prefix(3).joined(separator: "、"))")
            }
            if !amountMismatches.isEmpty {
                list.append("\(amountMismatches.count) 条订阅的金额和备份不一致：\(amountMismatches.prefix(3).joined(separator: "、"))")
            }
            if orphanEvents > 0 { list.append("库里有 \(orphanEvents) 条事件指向已经不存在的订阅") }
            if eventShortfall > 0 { list.append("事件只落库了 \(eventsExpected - eventShortfall) 条，备份里有 \(eventsExpected) 条") }
            if !missingIconFiles.isEmpty {
                list.append("\(missingIconFiles.count) 个图标文件不在包里、本机也没有：\(missingIconFiles.prefix(3).joined(separator: "、"))")
            }
            return list
        }
    }

    /// 把备份写回本机。
    ///
    /// 顺序是刻意的：图标最后写、且写完才发现写不进去也只报不返工；
    /// 数据整批一次落盘，任何一条不合格在校验阶段就抛，库里一行都不会变。
    static func restore(data: Data,
                        into context: ModelContext,
                        preferences: SubPreferences,
                        mode: SubscriptionRepository.RestoreMode = .overwrite,
                        icons: IconImageStore = .shared) throws -> Report {
        let contents = try read(data)
        let payload = contents.payload
        guard !payload.hasNothingToRestore else { throw Failure.emptyBackup }
        let issues = payload.validate()
        let recoverableSubscriptions = payload.recoverableSubscriptions()
        let recoverableEvents = payload.deduplicatedEvents()

        // V1 没有稳定编号：内容指纹撞上本机已有的行就当重复，不再写第二份。
        // 它带的那几条历史也一并留下 —— 第一次恢复已经写进去了，再写就是双份账。
        var duplicatesSkipped = 0
        var duplicateEventSkips = 0
        var skippedIDs = Set<UUID>()
        var rows: [(draft: SubscriptionDraft, status: BackupRow)] = []
        var eventsToWrite = recoverableEvents
        if contents.manifest.schemaVersion == 1 {
            let fingerprints = Set(legacyFingerprints(of: (try? context.fetch(FetchDescriptor<Subscription>())) ?? []))
            for item in recoverableSubscriptions {
                if fingerprints.contains(legacyFingerprint(item)) {
                    duplicatesSkipped += 1
                    skippedIDs.insert(item.id)
                    continue
                }
                rows.append((item.draft, item.status))
            }
            let kept = eventsToWrite.filter { !skippedIDs.contains($0.subscriptionID) }
            duplicateEventSkips = eventsToWrite.count - kept.count
            eventsToWrite = kept
        } else {
            rows = recoverableSubscriptions.map { ($0.draft, $0.status) }
        }

        let repository = SubscriptionRepository(context: context)
        let counts = try repository.restore(rows: rows,
                                           events: eventsToWrite.map(\.draft),
                                           mode: mode)

        // 分类和支付方式合并而不是整份替换：本机有、备份里没有的分类还在用，
        // 直接覆盖会把那些订阅甩进「其他」。
        merge(categories: payload.categories, paymentMethods: payload.paymentMethods, into: preferences, mode: mode)
        payload.preferences.apply(to: preferences)

        var iconsWritten = 0
        var iconFailures: [String] = []
        for (file, bytes) in contents.icons {
            if icons.restore(bytes, named: file) { iconsWritten += 1 } else { iconFailures.append(file) }
        }

        let consistency = check(payload: payload,
                                written: rows,
                                events: eventsToWrite,
                                context: context,
                                icons: icons,
                                mode: mode)
        return Report(schemaVersion: contents.manifest.schemaVersion,
                      manifest: contents.manifest,
                      counts: counts,
                      duplicatesSkippedByContent: duplicatesSkipped,
                      eventsSkippedAsDuplicates: duplicateEventSkips,
                      issues: issues,
                      iconsWritten: iconsWritten,
                      iconWriteFailures: iconFailures,
                      consistency: consistency,
                      mode: mode)
    }

    private static func merge(categories: [SubscriptionCategory],
                              paymentMethods: [String],
                              into preferences: SubPreferences,
                              mode: SubscriptionRepository.RestoreMode) {
        var merged = preferences.categories
        for incoming in categories {
            if let index = merged.firstIndex(where: { $0.id == incoming.id }) {
                if mode == .overwrite { merged[index] = incoming }
            } else {
                merged.append(incoming)
            }
        }
        preferences.categories = merged
        preferences.paymentMethods = preferences.paymentMethods + paymentMethods.filter {
            !preferences.paymentMethods.contains($0)
        }
    }

    private static func legacyFingerprint(_ item: BackupSubscription) -> String {
        "\(item.name)|\(item.priceMinorUnits)|\(item.currencyCode)|\(item.cycle)|\(Int(item.createdAt.timeIntervalSince1970))"
    }

    private static func legacyFingerprints(of subscriptions: [Subscription]) -> [String] {
        subscriptions.map { "\($0.name)|\($0.priceMinorUnits)|\($0.currencyCode)|\($0.cycleRawValue)|\(Int($0.createdAt.timeIntervalSince1970))" }
    }

    private static func check(payload: BackupPayload,
                              written rows: [(draft: SubscriptionDraft, status: BackupRow)],
                              events: [BackupEvent],
                              context: ModelContext,
                              icons: IconImageStore,
                              mode: SubscriptionRepository.RestoreMode) -> Consistency {
        let repository = SubscriptionRepository(context: context)
        var missing: [String] = []
        var amountMismatch: [String] = []
        var iconGaps: [String] = []
        for row in rows {
            guard let stored = repository.subscription(id: row.draft.id) else {
                missing.append(row.draft.trimmedName)
                continue
            }
            // 「本机优先」下本机那条本来就该和备份不一样，不该报成不一致。
            if mode == .overwrite, stored.priceMinorUnits != max(row.draft.priceMinorUnits, 0) {
                amountMismatch.append("\(stored.name)（库里 \(stored.billAmount.amountText)，备份里 \(row.draft.priceMinorUnits) 分）")
            }
            // 订阅要的那张图既不在包里、本机也找不到文件：界面只能退回首字母块。
            if let file = stored.iconImageFile, !file.isEmpty,
               !payload.iconFileNames.contains(file), icons.data(for: file) == nil {
                iconGaps.append(file)
            }
        }

        let storedEvents = (try? context.fetch(FetchDescriptor<SubscriptionEvent>())) ?? []
        let storedSubscriptionIDs = Set(((try? context.fetch(FetchDescriptor<Subscription>())) ?? []).map(\.id))
        let orphanEvents = storedEvents.filter { !storedSubscriptionIDs.contains($0.subscriptionID) }.count
        // 只对该落库的那些：指向不存在订阅的事件是「备份体检」里已经点名跳过的那几条，
        // 再按「少了几条」报一遍就是把同一个问题说两次、还让人以为写了失败。
        let expectedEventIDs = Set(events.filter { storedSubscriptionIDs.contains($0.subscriptionID) }.map(\.id))
        let eventShortfall = expectedEventIDs.subtracting(storedEvents.map(\.id)).count

        return Consistency(eventsExpected: expectedEventIDs.count,
                           missingSubscriptionNames: missing,
                           amountMismatches: amountMismatch,
                           orphanEvents: orphanEvents,
                           eventShortfall: eventShortfall,
                           missingIconFiles: Array(Set(iconGaps)))
    }
}
