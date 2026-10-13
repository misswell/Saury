# iCloud 同步：模型、冲突与删除策略

对应任务书 §4。这份文件说清四件事：同步**按什么模型走**、**冲突怎么判**、
**删除怎么不留坑**，以及最要紧的一栏 —— 哪些是这一版**编码并自动测过**的，
哪些只是**代码写好了但在这个环境里跑不到**。三件事不混着写。

---

## 0. 一句话结论：这一版换了什么

旧版 `Services/CloudSyncEngine.swift` 已经删除。它最要命的事故是：开自动同步走的是
不带 `ModelContext` 的 `syncNow()`，那条路只在恰好拿到上下文时才合并和推送 —— 于是它
查了一圈云端、把「上次同步」时间写上、报「已同步到 iCloud」，而本机一条数据都没动过。

新版 `Services/Cloud/` 从结构上堵死这个形状：

1. `SyncCoordinator` 必须自己拿着 `ModelContainer` 才建得起来，每次同步自己开上下文；
2. 走到 `success` 之前必须过 `verifying`：服务端返回值里每一条上传都在、且本机该落的行读得回来；
3. 没有 iCloud 能力或账户不可用 → 落成 `failed`，「上次同步」时间**一个字节都不写**。

---

## 1. 能力：读签名，不读编译条件

`CloudAccess.status(profile:)` 是一个纯函数，输入是包里 `embedded.mobileprovision` 的字节，
输出三态之一（`.ready(containerIdentifier:)` / `.unavailable(reason:)` / ready 但容器对不上）。

为什么不写 `#if SAURY_ICLOUD`：编译字样只能说明「这次编译带了这个字样」，说明不了描述文件
真给了什么能力。以后在 Apple 开发者后台给 App ID 勾上 iCloud、把容器和 entitlements 挂上重签，
这里立刻自己就通了，不需要改一行代码 —— 也就不存在「条件忘了加、界面显示已同步」那种假状态。

必须先判的另一个原因：**没有 iCloud 权限时 `CKContainer` 在 `dispatch_once` 里直接抛异常，
Swift 的 `try` 接不住，进程当场没了**。所以任何 CK 对象都只能从 `.ready` 之后才创建，
`live(container:preferences:)` 在探测不通过时干脆不给协调器装搬运工。

界面上不说谎：能力没通时，「iCloud 与数据」页不显示「上次同步」「云端条数」（那些数没有来源），
页脚把缺的那一样原样端出来。

## 2. 数据模型：一层与 CloudKit 无关的形状

同步的真正对象是 `CloudRecord`（`Services/Cloud/CloudRecord.swift`），六个字段：

| 字段 | 含义 |
| --- | --- |
| `kind` | 四类之一：订阅 / 事件 / 设置 / 墓碑 |
| `name` | 稳定标识：订阅和事件用自己的 UUID，设置用组键名，墓碑用「被删的是哪一条」 |
| `updatedAt` | 比新旧的凭据 |
| `deletedAt` | 有值 = 这条已经死了 |
| `payload` | 这条记录的本体（JSON，和备份 V2 同一套编解码） |
| `icon` / `iconChecksum` | 图标字节与它的 SHA-256 |

为什么要这一层：CloudKit 只有「签名有 iCloud 能力 + 登录账户 + 后台建好容器和 Schema」
三件事同时成立才碰得动，这台机器一件都不成立。合并、墓碑、幂等这些规则若写在 `CKRecord`
上面就一行都测不到，而任务书要的恰恰是这些规则可证。于是：

- `CloudRecordStore` 是协议 —— 拉清单、按需取详情、整批存、按名删、查账户，五个动作；
- `CloudKitRecordStore` 只做搬运（`CKRecord` ↔ `CloudRecord`）；
- 测试里用一个内存版 `FakeCloudStore` 当云端，**走的是同一条生产代码路径**。

清单读取（`index(of:)`）**故意不带图标字节**：整表同步只需要比时间戳，一次拖回几百张图
正是最初那一版的负担来源。想要图，按名字单独取（`records(of:names:)`）。

## 3. 同步范围（§4.3 逐条）

| 内容 | 云端形状 | 位置 |
| --- | --- | --- |
| 订阅（含金额、周期、起止日、状态、分类 id、支付方式名） | `Subscription` 一条记录 | payload = `BackupSubscription` |
| 归档 / 置顶 / 回收站状态 | 同一记录的 payload 字段 | **恢复时一个都不清空**，见 §5 |
| 历史事件（扣费、跳过、改价、续期） | `SubscriptionEvent` 一条记录 | payload = `BackupEvent` |
| 自定义分类 | `UserSetting`，一组一条 | 组：`categories` |
| 自定义支付方式 | `UserSetting` | 组：`paymentMethods` |
| 基础货币 / 常用币种 / 只看常用 / 显示原币种 | `UserSetting` | 组：`currency` |
| 默认提醒开关、默认提前天数、提醒小时 | `UserSetting` | 组：`reminders`。`defaultRemindersEnabled` 是这一版新加的列 |
| 图标 | 订阅记录上的 `icon`（≤100 KB）或 `iconAsset`（`CKAsset`），永远带 `iconChecksum` | 稳定文件名 `<订阅 UUID>.png` |
| 删除凭据 | `Tombstone` | 名字 `Subscription-<UUID>` / `SubscriptionEvent-<UUID>` |

四组设置是**一组一条记录**，不是每个键一条 —— 分类数组内部顺序有意义，拆开就没法整体判新旧。

## 4. 触发：一个入口，六个来源

`SyncCoordinator.requestSync(reason:)` 是唯一的同步入口，六种来源都走它：

| `SyncReason` | 谁叫的 |
| --- | --- |
| `.firstEnable` | 用户把「自动同步」打开的那一下（setter 里直接触发） |
| `.localChange` | 本机写了库 —— `SubscriptionRepository.commit` 广播 `.sauryDataChanged` |
| `.foreground` | App 回到前台（`RootView` 的 `scenePhase`） |
| `.manual` | 页面上「立即同步」那一下 |
| `.networkRestored` | `NWPathMonitor` 从断到通的那一次（一直通着不反复同步） |
| `.accountChanged` | `Notification.Name.CKAccountChanged`，先刷账户状态再同步 |

三条规矩：

- 没开自动同步时，除 `.manual` 之外五个被动来源都被咽下（`respectsAutoSwitch`）；
- 同一时刻只跑一趟。跑的过程中来的调用进 `queued`，跑完只补最后一次；
- `RootView` 里**不再**自己脚一脚踩同步（旧版挂两处会把同一趟跑两遍）。

## 5. 冲突与删除策略（`SyncMerge`，纯函数）

`SyncMerge.plan(local:remote:retentionCutoff:)` 不碰数据库、不碰网络，输入输出全是值。
§4.3 那些要求全在这里判，所以全部能用单元测试考。出的计划一律按稳定键排序并相邻去重 ——
「这一趟和上一趟判得一样」是幂等要证的命题，字典遍历顺序每次都不一样就不成立。

订阅按这个顺序判：

1. **有删除凭据且本机这份不比它新 → 删除赢**（时间戳相等也算删除赢）。
   本机那条**进回收站，不硬删**（用户还能看见、还能捞）；绝不作为活记录上传；
   云端那条记录本身也一并改成「已删除」的样子，免得出现「记录说活着、墓碑说死了」两边要猜。
2. **本机这份确实更新**（删过之后又改过、或在回收站里恢复了）→ 本机赢，那张凭据作废
   （本机日志抹 + 云端删），**并记一条冲突** —— 悄悄复活和悄悄消失一样糟。
   单纯「软删除后自己恢复」不算冲突，那本来就是回收站允许的。
3. 没凭据 → `updatedAt` 新的一方赢。
4. **时间戳相同而内容不同 → 不覆盖任何一边**，云端那一份原样留档报出来。
5. 云端没有这一条 → 本机这份传上去。

删除时间的四个来源取最新的一个：本机墓碑日志、云端墓碑记录、云端记录的 `deletedAt` 列、
payload 里的 `deletedAt`。

事件按自己的 UUID 合并：云端没有的补进本机、本机没有的从云端收下、已有的一条都不动
（所以同一个事件不会重复）。同一个编号两边内容不一样时**谁都不覆盖** —— 事件身上的时间是
「发生时间」，判不出哪一份是后来改的。

### 为什么墓碑存偏好而不是存库

彻底删除会把行从库里拿走，行自身留不下证据；而这份证据必须活过「清空回收站」和这一次进程。
所以 `SyncTombstoneLog` 写在 `UserDefaults`。只有两条路能动它：用户亲手「从回收站恢复」
（`pardon`），和到期销毁（`forgetExpired`）。别的任何路径都不许撤墓碑。

### 保留期与离线边界

墓碑保留 **180 天**。到期时连墓碑带它压着的那条记录一起从云端清掉，只清本机日志里过期那批 ——
别人留下的凭据由留它的那台负责清。本机库里还留着这一条（躺在回收站）的名字跳过，否则每趟
白删白传一次。

**这条边界要讲明白**：一台设备离线超过 180 天才回来，它手里那条被删掉的订阅有可能复活。
这个数字就是该风险的边界，可调，但必须有人知道自己在调什么。

销毁顺序是**先云端后本机**：云端确认删掉了才动本机日志。反着来会出现最坏的那种状态 ——
云端还压着墓碑而本机已经不知道这件事了。云端删除没确认时，本机日志原样留着，
报告里写 `cloudCleanupDeferred`，下一趟再试（`SyncCoordinatorTests` 有这一条）。

### 不可判定时留什么

`SyncConflict` 带：哪一种（订阅/记录/设置）、稳定名、两边时间、**云端那一份的原始 JSON**、
一句人话原因。处理方式两边都不动。留档最多 50 条、按 id 去重、存在偏好里（重启还在），
页面上「两边都不动的地方」逐条列出，用户点「清掉这些留档」才清。
这就是 §4.3「不可判定时保留可恢复记录」。

### 幂等怎么做到的

- 从云端收到的订阅**照 payload 里的 `updatedAt` 落库**，不重新盖本机时刻；
- 从云端收到的一组设置，收下之后把该组的「改动时间」写成**云端那份的时间**；
- **唯一的例外**：提醒那一组的旧载荷里没有 `defaultRemindersEnabled` 这一列，收下时按旧意思补齐
  （0 天 = 「不提醒」+ 天数还回 3，见 `Docs/DATA_MIGRATION.md` 的「加一列但不开新版本」）。补齐之后本机这份
  内容和云端那份**不再相同**，协调器就把这组的时间戳重盖成本机时刻、让这一版推上去一次 ——
  照字面「写云端时间」的话，两边时间相同内容不同，每趟同步都会报一次假冲突；
  判据是内容指纹比对（`SyncedSettings.fingerprint` vs `sha256(payload)`），不是猜；
  对齐之后的载荷再收一次就是完全幂等；
- 设置写回时「payload 里有的键就照写」，不再自作主张跳过空数组 ——
  否则本机值变了而时间戳没跟上，下一轮两边时间相同、内容不同，会被判成冲突反复报出来；
- 计划整体排序 + 相邻去重。

于是「同一步同步跑第二遍」不写云端、不重复加事件，`SyncMergeTests` 和
`SyncCoordinatorTests` 各有一条钉住它。

### 批量失败可以安全重试

`save` 返回的是**服务端确认收下**的那些条，核对阶段读的是这个返回值而不是「我叫了保存」。
CloudKit 那边一批是一个原子事务（`modifyRecords` 每 200 条一片）：一条没成整批报错，
`batchRequestFailed` / `partialFailure` 翻成「这一批没有整体存进云端，本机数据没动，
下次同步会原样重推」。因为重推的是同样的名字和同样的内容，结果一样。

清单里单条读失败**不当成「云端没有这一条」**，直接报出去 —— 清单少一条，下一轮就会把那条
判成「本机独有」重新上传，或者该收下的没收下。

## 6. 图标：稳定标识 + 校验和

稳定标识就是文件名 `<订阅 UUID>.png`（`Subscription.iconImageFile`），两边同名同内容不重传
（`iconChecksum` 对得上就跳过）。字节只在缺的时候才取，**落盘前验校验和，验不过就不写** ——
「看着回来了其实是另一张图」不是修复。大图（>100 KB）用 `CKAsset` 存，避开 CloudKit
单字段 1 MB / 整条 1.5 MB 的墙。

## 7. 状态机与界面

`idle → checkingAccount → fetching → merging → uploading → verifying → success / failed`。
页面上「当前阶段」直接显示 `phase.title`，busy 的那五格带转圈；失败是页脚一句橙色的话，
不弹打断人的窗；成功后铺 `SyncReport.summaryText`（云端几个数、本机收下几条、上传几条、
收进回收站几条、补回几张图、清掉几条、几处冲突）。

「云端」那一行读的是最近一次**真读到**的清单；没读到过写「这台设备还没读过云端」，
不写 0 —— 0 条和没读过是两件事。

两个重动作单独放着：
- **以本机数据为准**（`pushLocalAsSource`）：整包盖上这一刻推上去，归档和删除状态照本机写，
  本机彻底删过的带着凭据推上去，别的设备那一条**进回收站不硬删**，本机一个字节都不删；
- **修复图标**（`repairIcons`）：库里有文件名、磁盘上没这张图的，按名字从云端取回并自验校验和。

`verifying` 有两道核对：服务端返回值里每条上传都在；本机该落的订阅行读得回来。
后者在测试里**造不出失败**（能强迫写库失败的手段这里都没有，见 `Docs/EON_QA.md`），
所以只有第一道有测试覆盖，这一条如实记下。

## 8. 这一版验证到哪一步（三分，不含糊）

**已编码**：以上全部，`Saury/Services/Cloud/` 六个文件 + 界面接线。

**已自动测试**（`./scripts/test-ios.sh` 里跑得到的绿色用例，用例清单见 `Docs/EON_QA.md` 的 PR3 段）：
合并五步判定、删除不复活、事件按 UUID、四组设置新旧与不可信、幂等第二趟为空、
到期销毁顺序、图标校验和、批量被拒可重试、六个触发源与自动开关、能力探测三态、
账户不可用不写成功时间、`verifying` 拦假成功、阶段链一格不落。
两台设备 + 共享「云端」那条（A 删、B 离线、B 上线不许复活）用的是同一套生产代码 +
内存版云端。
提醒那一组多出一列之后的两条也在这套里：旧载荷缺列时按旧意思补齐、补齐后重盖时间戳推一次而不是
每趟报冲突；对齐之后再收同样的载荷则完全幂等（`SauryTests/PreferencesPublishingTests.swift`）。

**未验证（这个环境做不到，必须补的都在 §9）**：
- `CloudKitRecordStore` **一次都没运行过**。它只被编译验证过，
  用的 API 形状（`modifyRecords(saving:deleting:savePolicy:)` 的 `saveResults`/`deleteResults`、
  `records(for:desiredKeys:)`、分页游标、`CKQueryOperation.maximumResults`）是对着
  iPhoneSimulator SDK 的接口签名核对的，不是跑出来的。
- §4.4 的两台真实设备验收：没做过。
- 「同步后云端三个数一致」这类只有真账户能回答的判据：没看过。

## 9. 还需要 Apple 开发者后台或真机的外部前置条件

这些不是代码能自己完成的，缺一条同步就一条都跑不起来：

1. **App ID 开 iCloud 能力**（Xcode 里勾 CloudKit，或在开发者后台给
  `com.guofeng.saury` 加上 iCloud capability），并**重新生成描述文件**。
2. **建容器** `iCloud.com.guofeng.saury`（`CloudAccess.expectedContainerIdentifier`）。
  容器 id 和这个不一致不算错，但界面会红字标出「容器对不上」，说数据可能进了另一个库。
3. **写进 entitlements**。现在 `Saury/App/Saury.entitlements` 只有 App Group，需要加：
  - `com.apple.developer.icloud-services` = `["CloudKit"]`
  - `com.apple.developer.icloud-container-identifiers` = `["iCloud.com.guofeng.saury"]`
  注意：在 App ID 还没开能力之前先把这两行加进去，会让**整个 App 签名失败**，
  所以现在故意不加 —— 能力探测读的是签名结果，签上了它就自己通了。
4. **四个 record type 及字段**，部署到 Development（以及将来 Distribution）：

  | record type | 字段 |
   | --- | --- |
   | `Subscription` | `updatedAt` (Date)、`deletedAt` (Date?)、`payload` (Data)、`icon` (Data?)、`iconChecksum` (String?)、`iconAsset` (Asset?) |
   | `SubscriptionEvent` | `updatedAt`、`payload` |
   | `UserSetting` | `updatedAt`、`payload` |
   | `Tombstone` | `updatedAt`、`deletedAt`、`payload` |

   每个类型的 `updatedAt` 建议加查询索引。字段名拼错或类型没部署，同步会在第一步报错，
   报错文案是「云端容器或表还没建好：到 iCloud 控制台把四个 record type 部署到当前环境」
   （对应 `zoneNotFound` / `missingEntitlement` / `badContainer` / `badDatabase`）。
   提醒开关（`defaultRemindersEnabled`）和订阅的 `remindersEnabled` 都**不需要动云端结构**：
   它们装在 `payload` 这块 Data 里，四个 record type 一个字段都不用加。
5. **真机 + 两个 Apple 账户**，做 §4.4 那三件事：A 建 B 收、A 删 B 不复活、
   B 离线期间 A 改、B 上线后按时间戳收敛。两台设备的「云端」那一行三个数一致才算通。
6. **付费 iCloud 配额**不是前置条件（私有库走用户自己的空间），但 `quotaExceeded`
   那句「iCloud 空间已满或超出用量额度」是真会走到的分支，只能真账户触发。
7. SwiftData 的自动 CloudKit 同步**永久关闭**（`ModelConfiguration(cloudKitDatabase: .none)`
   是写死的静态值），否则和这套自研引擎同时写就是双写。
