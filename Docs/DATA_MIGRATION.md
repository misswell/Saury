# 数据迁移、备份恢复与坏库处置

这份文件回答三个问题：老库怎么升上来、备份包里到底有什么、库打不开时 App 凭什么决定动不动用户的文件。
每条规则都能对到代码和用例上，对不上的写在最后「没证到的部分」里。

## 1. 库文件在哪

- SwiftData 的库文件名是 `default.store`，SQLite 会带出 `default.store-wal` 和 `default.store-shm` 两个伴生文件。
- 实测（iPhone 17e 模拟器，当前 Debug 构建）：库落在 **App Group 容器**里 ——
  `…/Shared/AppGroup/<uuid>/Library/Application Support/default.store`，
  不在 App 自己的 data 容器里。`simctl uninstall` 只清后者，所以卸载重装并不会清掉这份库。
- 代码不赌这一条：`PersistenceController.candidateStoreLocations()` 同时把
  「App 自己的 Application Support」和「App Group 的 Application Support」两个位置都列为候选，
  判据和留底都按候选逐个走（`Saury/Data/PersistenceController.swift:116`）。
- 图标是磁盘文件，不在库里：`Application Support/Saury/Icons/<文件名>`，订阅行只存文件名。
  所以「库完好、图标丢了」是一种真实存在的坏法，数据体检专门看它。

## 2. Schema 版本线

四个版本都必须一直声明在 `SauryMigrationPlan.schemas` 里。**删掉任何一个旧版本，
装了老版本的用户就再也升不上来**，那是比 bug 更糟的事（任务书 §16「不移除已有迁移版本」）。

| 版本 | 模型 | 说明 |
|---|---|---|
| V1 | `RenewalItem`、`DecisionRecord` | 最早那版「续费提醒」 |
| V2 | `ExpiryItem`、`ExpiryEvent` | 改成「到期物品」，加流水账 |
| V3 | V2 + `ProductTemplate` | 只是多一张表 |
| V4 | `Subscription`、`SubscriptionEvent` | 期见改做订阅管理；当前版本，运行时用的就是它 |

V4 之后又给 `Subscription` 加过一列（`remindersEnabled`），但**它没有被做成第五条版本线**，
原因写在下面「加一列但不开新版本」那一节 —— 那是这一版里最贵的一条教训，别再犯第二遍。

### V1 → V2：custom stage

`willMigrate` 把两张表整个读成快照存进 `SauryMigrationHandoff`，`didMigrate` 再写进目标库。
两个 context 属于不同 schema，数据只能经这里过一手；SwiftData 在同一次迁移里按顺序调用二者。

字段映射（`Saury/Data/MigrationPlan.swift`）：

- 周期：`oneTime` → 不重复；`monthly`/`freeTrial` → 按月；`yearly` → 按年；
  `customMonths` → 自定义 N 个月（下限 1）。**关掉了自动续费的一律不再产生下一次**。
- 状态：`active`/`expired` → 跟踪中（到期与否由 `ExpiryEngine` 按天数实时判，不入库）；
  `paused` → 归档；`cancelled` → 已取消。
- 金额：`amountMinorUnits == 0` 视为「旧版没记钱」，写成 `nil` 而不是 0 —— 0 会被读成「免费」。
- `nextRenewalDate` → `expiryDate`；`cancelByDate` → `actionDeadline`；
  `managementURLString` → `sourceURL`（空串不写）；`reminderOffsets` 为空时用该分类的默认提醒档。
- 旧决定 → 事件类型：`continued` → 已续期、`cancelled` → 已取消、`paused` → 已归档、`snoozed` → 稍后再提醒。
- 编号原样带过去，重复 id 跳过（`@Attribute(.unique)` 撞上会让整个容器起不来，等于把用户的旧数据锁死）。

### V2 → V3：lightweight

只是多一张 `ProductTemplate` 表，老数据一行不动，交给 SwiftData 的轻量迁移。

### V3 → V4：custom stage

- 只有分类为「订阅」的 `ExpiryItem` 会变成 `Subscription`。食品、药品、证件这些在新产品里没有对应概念，
  **不再迁移** —— 这是产品决定，不是丢数据丢顺手了；它们的 `ExpiryEvent` 也一并留下不搬，
  免得新库里出现认不出主人的事件（体检会把这种行报成孤儿）。
- 重复规则 → 计费周期：`none` → 一次性、`weekly` → 每周、`monthly` → 每月、`quarterly` → 每季、
  `everySixMonths` → 半年、`yearly` → 每年、`custom` → 自定义 N 个月。
- 状态：`active` → 自动续费，其余 → 已停用。分类一律落到「其他」，因为旧分类和新分类不是同一套。
- 流水账跟着走（`Saury/Data/MigrationPlan.swift:82`）：旧版每一次「已续期」「已取消」都是用户真实做过的决定，
  只搬物品不搬历史等于把账本删了一半。类型折到语义最近的一个：
  已续期 → 扣费、已取消/已归档/已丢弃 → 停用、稍后再提醒 → 跳过、已恢复 → 恢复、
  已添加/已修改/已用完 → 备注；**原来的说法原样写进事件备注**（`旧版记录：已续期`），
  新产品里没有对应动作时不硬套一个假类型。
- 「活下来的订阅」= 这次转出来的 + 目标库里本来就有的。已经存在的订阅，它的事件照样要接上。

### 加一列但不开新版本：`remindersEnabled`（PR4）

提醒改成显式模型要给 `Subscription` 加一列 `remindersEnabled`。第一版把它做成了 Schema V5
加一条 `.custom(V4 → V5)` 阶段，**这台机器上直接把装上老库的设备炸了**：

- `VersionedSchema.models` 只能列**在用的**模型类型，加一列不引入新类型，
  所以 V4 和 V5 的 `models` 完全相同 → 两个 `Schema` 转成 `NSManagedObjectModel` 后相等；
- SwiftData 在建这条 stage 的当场抛
  `The current model reference and the next model reference cannot be equal`，
  容器根本建不起来 —— 不是「迁移失败」，是**每个持有老库的设备一进 App 就闪退**，
  新库用户反倒没事（他们的库不开这一条路）。这就是为什么它现在被整个删掉了。

现在的做法分三件事，每件都由最合适的那一层负责：

1. **列由 CoreData 的自动轻量迁移补上。** 新增一列是它能推出来的改动，前提是这一列
   要么可空、要么有存储默认值：`var remindersEnabled: Bool = true`（`Saury/Domain/Models/Subscription.swift`）。
   那个 `= true` 不是摆设也不是兜底 —— NOT NULL 又没默认值时 CoreData 不肯替老库猜一个值，
   于是整个库直接拒开（实测报 `loadIssueModelContainer`，计划不计划、带不带 URL 都一样）。
2. **每行的意思由启动补算给。** 默认值只活一瞬：`ReminderIntentBackfill.runIfNeeded`
   在启动时按**用户当年看到的说法**把老库每一行重算一遍，认哨兵键 `saury.reminderIntent.v5rows`。
   判据只有一条，和备份恢复、云端旧载荷、V1 JSON 导入是同一套（见下面那张表）：

   - `reminderDays > 0` → 开关打开，天数原样留着。
   - `reminderDays == 0` → 开关关掉。旧库里 0 这个值在新增页和详情页上都写着「不提醒」，
     而调度器把它读成「扣费当天提醒」—— 两者本来就矛盾。新口径下 0 只有一个意思（当天），
     要不要提醒交给开关；选用户看到的那一句，不选调度器的行为
     （任务书 §5.1「不得静默改变提醒规则」）。
   - **天数不改**（不顺手改成 3 之类的「正常值」）：用户将来把开关打开时，他当初挑的那一天还在。
   - **`updatedAt` 一个字都不盖**：补算不是用户改动。盖了时间戳，升级完的那台设备会把库里每一行
     都当成「本机这份最新」整片推上云，把另一台设备刚改的东西盖掉。

   位置也刻意的：跑在同步和调度**之前**（`Saury/App/SauryApp.swift` 的 `init`）。
   补算没做完就把整片推上云会盖掉另一台设备的开关；反过来先排通知，那一趟会按还没补的开关
   排出该静默的订阅。兜底跑在内存库上时**不写哨兵**，那一趟下次启动还要再来一遍。
3. **开库按库自己留下的证据分流。** 拿着迁移计划去开一个「结构没变」的当前库会让 SwiftData
   误判成需要迁移，所以 `PersistenceController.openContainer` 先问文件本身，
   证据有两级（`StoreFileProbe.schemaEvidence`）：

   1. `Z_METADATA.Z_PLIST` 里 CoreData 盖的版本章（`NSStoreModelVersionIdentifiers`）—— 最权威；
   2. 版本章读不到时看表名：`ZEXPIRYITEM`、`ZRENEWALITEM` 这些只有老库才有，
      `ZSUBSCRIPTION` 只有 V4 之后才有。表结构在主文件里，不受 WAL 影响。

   章是 `1.0.0`/`2.0.0`/`3.0.0`、或只剩老表名的 → 带 `SauryMigrationPlan` 打开；
   章是 `4.0.0`、或只剩当前表名的 → 不开计划，直接交给自动轻量迁移。
   **判不清（没有章、表名也认不出、文件打不开、库还不存在）一律按老库待**，
   因为两种错的代价不对等：不带计划去开一个老库，CoreData 会做自动迁移，
   而旧实体在它眼里就是要删掉的表 —— 实测会把用户的行洗成零（日志里那句
   `Persistent History … due to the following entities being removed` 是这一条）。
   带计划开不出来顶多是打不开，文件还在原处。
   为什么第一级会读不到：刚写完的库，`Z_METADATA` 那一行还在 `-wal` 里，只读连接不一定看得见，
   所以探测先按可读写谈、谈不拢再退回只读（`openForReading`），并留了表名这一级兜底。
   **读的都是文件里的事实，不是错误文本** —— SwiftData 抛出来的那一句分不出这两种情况。

设置层（`SubPreferences`）那侧的同类回填走的是另一条路，判据也刻意不同：
那里旧的「新建订阅不提醒」是挂在 `defaultReminderDays == 0` 上的，而老 getter 又把 0 读回 3，
所以存进 0 的人表达的就是「不提醒」→ 换成「开关关掉 + 天数还回 3」。
这条只做一次，认一个哨兵键 `saury.reminderSemantics.v5`；不认的话新装用户日后真把天数调成 0
（那是「当天提醒」），下次启动会被当成旧值「修」成不提醒。

同一个「这一列缺了该怎么读」的判断挂在下面这些入口，口径必须一致，否则同一份数据从不同路进来
会给出相反结论，用户迟早会撞上：

| 入口 | 缺这一列时怎么办 | 代码 |
|---|---|---|
| 启动补算（老库里那一列是自动迁移填的默认值） | `enabled = days > 0` | `ReminderIntentBackfill.intent(reminderDays:)` |
| 备份正文 / 云端订阅载荷里缺这一列 | `remindersEnabled ?? (days > 0)` | `BackupSubscription.resolvedRemindersEnabled` |
| V1 JSON 导入 | 同上，另一份同名实现 | `ExportedSubscription.resolvedRemindersEnabled` |
| 备份恢复里旧的整体偏好（那一组压根没这键） | `legacyReminderDefault(days:)`：0 → 关 + 3 | `BackupPreferences.applyEach` |
| 云端偏好下发（旧载荷） | 同上 | `SyncedSettings.apply` |

前两条是「一行订阅」的口径（0 天按用户看到的「不提醒」），后两条是「新建订阅默认值」的口径
（0 天按老 getter 读回的 3，所以要把天数还回去）—— 分得开是因为旧界面对这两件事的说法不一样。

### 迁移这一段必须成立的事

`SauryTests/MigrationAndBackupTests.swift` 的 `RealStoreMigrationTests` 在磁盘上真造 V1/V2/V3/V4 的库文件、
写真数据、落盘，再让当前 V4 计划去升，逐条断言：

- 编号、金额、周期一路不变；
- 旧决定变成事件，条数对得上，每条都认得出主人（零孤儿）；
- 被丢掉分类的物品，其事件不迁进来；
- 升完的库再过一遍 `StoreIntegrityReport.check`，零问题。

提醒意图那一趟单独由 `RealStoreMigrationTests` 里的三个用例覆盖（`SauryTests/MigrationAndBackupTests.swift:377`）：
造一个装了数据的 V4 库、跑 `runIfNeeded`，断言「当天提醒」那行被关掉、
提前 3 天/1 天的都开着且天数没被改、名字与 `updatedAt` 都原样、
第二次调用什么也不做，以及它和 `ExportedSubscription.resolvedRemindersEnabled` 对同样的天数
给出同样的结论。哨兵用单独的 `UserDefaults(suiteName:)`，测试结束删掉，不碰真偏好。

**这一段有一条证不全的地方，而且单元测试结构上补不了**：`VersionedSchema.models` 列的是在用的类型，
所以测试里造出来的「V4 库」物理上已经带着 `remindersEnabled` 这一列（值取初始化的默认「要提醒」），
测试覆盖的是补算规则本身。**真·发布版 V4 的库里没有这一列** —— 「自动轻量迁移肯不肯补这一列、
补完老数据还在不在」只能在升级前的构建造出的库上验，这台机器的单测造不出那种库。
它改由装好的 App 现场验过一次（见 `Docs/EON_QA.md` PR4 一段「已装机验证」）。

## 3. 备份与恢复规则

备份是 `.saurybackup` 单文件（UTType `com.guofeng.saury.backup`），容器格式与内容格式**分开计版本**：

```
"SAURYBAK" | 容器版本 UInt8 (=1)
清单块：SHA-256(未压缩清单) | u32le 未压缩长度 | u32le 压缩后长度 | 压缩数据
之后按清单顺序，每块：u32le 名字长度 | 名字 UTF8 | 同上三样 + 压缩数据
```

- 清单（`manifest.json`）记：内容 `schemaVersion`、打包时间、App 版本、订阅/事件/图标条数、
  每块的 `sha256` 与字节长度。分块各自压缩、各自校验，坏哪块报哪块，不必整份读进内存。
- 清单自己的摘要记在文件头而不是清单内部 —— 让清单写自己的 SHA-256 就成了先有鸡还是先有蛋。
- 正文（`document.json`，`schemaVersion = 2`）带：订阅（稳定 UUID + 全部业务字段 + 时间戳）、
  事件（自己的 UUID + 所属订阅 UUID）、自定义分类、常用支付方式、偏好、包里带了哪几张图。
- 图标按磁盘原始字节单独分块（`icons/<文件名>`），不转 base64：重新编码会产出另一份数据、摘要就对不上清单了。
- **归档和回收站里的订阅一起打包**：那些同样是用户的数据，只挑「在用的」会在恢复后凭空少掉一块。
- 订阅身上指着图但本机已经没有那个文件时，如实记进 `missingIconFileNames`，报出来而不是留个空位。

恢复：

1. 先只读清单做预览，再决定读不读那几十张图。
2. 空包（订阅、事件、分类、支付方式、偏好全都空）直接拒绝：那种文件多半是拿错了，
   恢复完让用户以为数据没了。
3. 整批校验后一次落盘。名字为空的行是坏行 → **整批不写、直接抛**；
   指向已不存在的订阅的事件不进库，但只记进 `eventsSkipped`，不连累同一批里正常的订阅。
4. 两种模式：`备份优先`（同一条整份覆盖，重复恢复幂等，不会越恢复越多）/
   `本机优先`（库里已有就原样留着，只补没有的）。
5. 分类和支付方式**合并而不是替换**：本机有、备份里没有的分类还在用，直接覆盖会把那些订阅甩进「其他」。
6. 恢复完拿库里的真实数据对一遍：数量、金额、事件指向、图标引用。
   报告里的数字来自库里的真实行，不是备份文件里「本来应该有」的数。
7. V1 那份纯 JSON 老备份仍可读：它没有稳定编号，转进来时现场发号，
   去重靠「名字 + 金额 + 币种 + 周期 + 创建时间」的内容指纹，报告里会写清楚这是按内容判的重复。

## 4. 库打不开时的分级处置

`StoreFailure` 分四类。**判据以文件证据为主**（`StoreFileProbe`）：实测 SwiftData 抛出的错误经常只有
一个 `loadIssueModelContainer`、一句解释都没有，「文件不是库」和「目录写不进去」在它嘴里是同一条错误；
而这两种处置完全相反。错误文本只在文件给不出结论时兜底。

| 分类 | 判据 | 处置 | 用户看到 |
|---|---|---|---|
| 文件坏了 `.unreadableStore` | `PRAGMA integrity_check` 报 `SQLITE_CORRUPT`/`SQLITE_NOTADB`，或文件不可解析 | **唯一**允许改名留底并重建新库的一类 | 横幅 + 数据页 Section，点名「留在原目录 N 个文件」 |
| 结构读不懂 `.migration` | 文件体检通过，但这一版读不动它的结构 | 一个字节都不动，不重建（挪走会让下一个版本也找不到它） | 「旧文件原样留着，没有删」+ 别在临时库里记账 |
| 写不进去 `.unwritable` | 文件/目录不可写、空间不足、`SQLITE_BUSY`/`LOCKED`/`PERM`/`READONLY`/`FULL`/`CANTOPEN`/`IOERR` | 不动文件、不重建 | 「App 没有动你原来的文件」+ 腾空间或改权限后重开 |
| 认不出来 `.other` | 上面都凑不出结论 | 不动文件、不重建 | 「原因没能认出来」，不编一句「文件坏了」 |

- 判据顺序刻意是「可写性 → 体检」：只读目录里的库体检多半也失败，但那种情况把旧库挪走是错的。
- 别的连接正独占着库时**不许**判成坏了：占用中改名等于把正在用的账本抢走。
- 一次都没挪到文件时（库不在候选位置、或压根不存在）拒绝说「文件坏了」，改成如实交代
  「原因没认出来，没动过任何东西」—— 判据只剩错误文本时可信度不够。
- 连新库都建不起来：`makeContainerForLaunch` 退回内存库让 App 照常开起来，
  并把原因挂在 `lastOpenFailure` 上。闪退和静默的空库都不是选项。

### 留底与说明

- 留底只改名、不删除：`default.store` → `default.store.quarantined-<时间戳>-<随机>`，
  三件套一起改，仍在原目录。
- 这件事必须说出来：首屏横幅（`PersistenceController.launchNotice`）+ 数据页顶部的 Section。
- **记录跨启动保留**（存在 App 自己的偏好 `saury.store.recovery` 里）。一次成功的打开不会把
  「留底文件还在磁盘上、现在用的是另建的新库」变成假话；只有用户在数据页点
  「我看过了，不再提示」才撤 —— 撤的只是提示，磁盘上的留底文件一个都不动。
- 找回路径：「从备份恢复」、「导入订阅」、或把留底文件发给能读懂旧版本的设备。

## 5. 数据体检

「iCloud 与数据」页的「检查现在的库」（`StoreIntegrityReport`）对着当前这个容器数一遍：
事件认不认得出自己的订阅、编号有没有重复、名字/币种/周期成不成样子、结束日期是否早于开始、
图标文件还在不在、分类还认不认得。

**只列出来，一个字节都不改。** 没有人确认过的「自动修数据」只是另一种破坏。
临时库（跑在内存库上那一趟）同样能查，查的是当前容器里的行。

## 6. 没证到的部分

- 四种分级里只在装好的 App 上演练过「文件确实坏了」这一条；迁移失败 / 权限 / 磁盘满只在单测里造过现场。
- 留底文件**手工把名字改回去**这条退路：单测证到留底字节不变，
  但改回去之后 App 能不能正常读，没演过。
- 磁盘满这一条的阈值是「可用空间小于 8 MB」，按 SQLite 页数量级取的，没在真满的盘上验证过。
- 详细验收分级见 `Docs/EON_QA.md` 的 PR2d 一段。
