# EON 动效规范 · Saury 实现口径

任务书 §15 第 3 项：「`Docs/EON_MOTION_SPEC.md`：动效种类、适用场景和参数」。

这份文件只写**代码里真实存在**的东西。每一条参数都能在源码里 grep 到，每一个时长
要么来自同场景对照录屏的逐帧量测（§8 那张表），要么写明「未实测」。

- 词汇表定义在 `Saury/Views/Components/Motion.swift:20-49`（`enum Motion`）。
- 三块纯算术模型：`NumberRoll`（`Components/NumberRoll.swift`）、
  `CarouselTrack`（`Components/CarouselTrack.swift`）、`SheetRouter`（`Views/SheetRoute.swift:57`）。
  它们不含 SwiftUI，所以 §9.2 那些中断场景能在 `SauryTests/` 里逐帧问出来，而不是靠录屏事后猜。
- 对照录屏在 `build/verification/pr6/{before,after}/`，`before` 是基准提交 `021d939` 本体
  （从 `git worktree` 单独编出来的 App，见 `Docs/EON_QA.md` 的 PR6 段）。
  **`build/` 在 `.gitignore` 里**，MP4、探针日志和接触表只在本机；进仓库的是量测脚本、
  逐条数值和那份 478 项的测试日志（`Docs/verification/pr6/`）。
- 基准那一侧的源码引用一律写成 `git show 021d939:<path>` 能查到的行号。

## 1. 词汇表

| 名字 | 曲线 | 时长 | 用在哪 | 为什么是这个值 |
| --- | --- | --- | --- | --- |
| `Motion.page` | timingCurve 0.16,1,0.3,1 | 460 ms | sheet 进出、全屏覆盖 | 竞品 EON 的 sheet 逐帧边缘走线：详情层呈现 450 ms、编辑层呈现 470 ms、退回 67 ms（3 帧），两次呈现都是单调减速、没有越过终点再回来（`Docs/verification/pr6/results/eon-sheet-edge.txt`，脚本 `edge.py`）。这一条同量级 |
| `Motion.slide` | timingCurve 0.32,0.08,0.24,1 | 440 ms | 翻页、翻月、Tab 切换 | 注释里写着原因：`page` 那条太前载，70 ms 就走完 90% 的路，翻页会「闪一下黑屏再显形」 |
| `Motion.ui` | spring(duration:) 340 ms / bounce 0.12 | 340 ms | 胶囊、开关、展开收起、选中圈 | §9.1「小元素状态变化 160–280 ms」的上沿，因为这里同时要位移和换尺寸 |
| `Motion.pop` | spring 500 ms / bounce 0.34 | 500 ms | 图标抓取成功、数字落定、按钮回弹 | 唯一带可见过冲的一条，只给「事情做完了」这一下 |
| `Motion.entry` | spring 500 ms / bounce 0.10 | 500 ms | 列表行、卡片入场 | 配 `staged(_:)` 的 55 ms 级差 |
| `Motion.chart` | timingCurve 0.22,1,0.36,1 | 860 ms | 环形扫描、柱子生长、折线走线 | §9.1「图表初次生长 500–850 ms」，卡在 860 是因为它同时承担数据变化的插值 |
| `Motion.number` | timingCurve 0.16,1,0.3,1 | 620 ms | 金额滚动 | §9.1「数字更新 350–650 ms」的上沿。**注意**：这条只是给 `Motion.pop` 落定用的动画值，真正决定滚动时长的是那对 0.62 默认值（`AnimatedNumber.duration`，`Motion.swift:62` + `NumberRoll` 的 init，`NumberRoll.swift:23`） |
| `Motion.stagger` | — | 55 ms | 分级入场级差 | `staged(_:)`、`BarsChart.stagger(_:)` 共用 |

`Motion.spring(_:bounce:)`（`Motion.swift:41-48`）是自定义弹簧：`bounce=0` 时是纯 ease-out
（`1-(1-x)^4.2`），带 bounce 时是衰减余弦。`NumberRoll` 和 `CarouselTrack` 都用它算逐帧位置，
所以这两处的运动**不经过** `withAnimation`。

## 2. 八类动效的落点与实测

| 类别 | §9.1 建议 | 我方落点 | 实测（同场景对照，§8） |
| --- | --- | --- | --- |
| 按压反馈 | 80–150 ms | `Pressable`（`Motion.swift:235`）按下 `.easeOut(0.1)`、松手 `Motion.ui`；`CardPressable`（`:249`）按下 0.09、松手 `Motion.pop` | 未单独录屏量测 |
| 小元素状态变化 | 160–280 ms | `Motion.ui` 340 ms | 未单独量测 |
| 选中胶囊移动 | 200–350 ms | `SlidingPill`（`Motion.swift:266`）用 `matchedGeometryEffect`，`withAnimation(Motion.ui)` | 未单独量测 |
| 页面切换 | 300–450 ms | `Motion.slide` 440 ms + `directionalSlide`（`Motion.swift:331`） | 三 Tab 往返与弹窗：8 段 223–433 ms（中位 316，18–57 帧）；基准 7 段 220–510 ms（中位 423，20–44 帧） |
| 弹窗进出 | 350–500 ms | `Motion.page` 460 ms，配 `SheetRouter` 排队 | 近全黑 0 帧（两边都是）。EON 同动作：呈现 450 / 470 ms、退回 67 ms（`edge.py`，§7）；我方这一项没有做同精度的边缘 trace，只量了「过渡里没有空白帧」 |
| 卡片定位 | 250–500 ms | `CarouselTrack` ζ=0.82 / ω=16.5（`CarouselTrack.swift:27-28`），注释即「约 0.4 秒收敛，可中断弹簧」 | 松手到停 157–888 ms、10–48 帧 |
| 数字更新 | 350–650 ms | `NumberRoll` 默认 0.62（`NumberRoll.swift:23`） | 落定的四轮 626–642 ms（中位 637.5）；基准 632–651 ms（中位 649），常量同为 0.62 |
| 图表初次生长 | 500–850 ms | `Motion.chart` 860 ms | 柱↔线切换按下→首帧 +103 ms（基准 +1585 ms，且按下前那 2976 ms 一帧都没有） |

**没有靠拉长时长来凑分数**：数字滚动这一项，新旧两版用的是同一个 0.62 s 常量，
实测中位 637.5 ms 比基准的 649 ms 还短约 1.8%。页面切换中位 423 → 316 ms（短 25%），
帧数没缩水。

## 3. 可中断性：三条硬规则

任务书 §9.2 是硬要求，「禁止靠一批固定 `asyncAfter` 延迟来假装导航协调」。落到代码上是三条：

1. **状态源必须是屏幕上那一个值，不是目标值。**
   `withAnimation` 改的是目标值，模型里的 `position` 在赋值那一帧就到终点了，屏幕上还在半路 ——
   手指在定位动画跑到一半时搭上卡片，读到的就是终点值，卡片先从可见位置瞬移再跟手。
   所以 `CarouselTrack` 自己按帧积分（`CarouselTrack.swift:11-14` 的注释就是这条），
   `position` 永远等于屏幕上那一个值；`NumberRoll.value(at:)` 同理。
2. **新一轮必须让上一轮的收尾作废，而不是取消一个定时器。**
   `NumberRoll.round`（`NumberRoll.swift:20`）是轮次号，视图只接受「轮次号还等于当前号」的落定；
   落定判断走的是这一帧已经在用的那条插值（`Motion.swift:91-94`），没有第二个定时器，
   所以「谁的结束回调」这个问题一开始就不存在。
3. **等动画只能等系统给的信号，不能猜时长。**
   `SheetRouter`（`SheetRoute.swift:57-100`）在退场期间把新的呈现排进 `queued`，
   由 `.sheet(item:onDismiss:)` 的 `noteClosed()` 交出去；没写过一行 `asyncAfter`。

§9.2 那八条场景逐条对账：

| §9.2 场景 | 谁负责 | 证据 |
| --- | --- | --- |
| 动画进行到 20% 时反向 | `CarouselTrack.drag` 只加在 `anchor` 上 | `CarouselTrackTests.testReversingMidGestureFollowsTheFingerBack`；录屏 `01` 第 2、4 枪就是反向 |
| 动画进行到 50% 时再次触发 | `beginDrag` 把 `target` 清成 nil、`anchor` 钉在当前 `position` | `testASettleInterruptedAtHalfwayIsTakenOverFromTheVisiblePosition`、`testPullingBackAfterAnInterruptedSettleReturnsToTheOrigin`；录屏 `01` 四枪之间只歇 90 ms，短于一轮定位 |
| 连续快速点击同一个入口 | `NumberRoll.round` + `SheetRouter.route == next` 直接返回 | `NumberRollTests.testThreeQuickChangesStillLandOnTheLastNumber`、`SheetRouterTests.testTappingTheRouteThatIsAlreadyOpenChangesNothing`、`testReTappingTheOriginalRouteWhileClosingBringsItBack` |
| 快速在三个 Tab 间往返 | `RootView.select(_:haptic:)` 一次 `withAnimation(Motion.slide)` | 录屏 `05` 前后对照（同一份脚本时刻表） |
| 弹窗尚未完全出现时尝试关闭 | `SheetRouter` 的 `isClosing` / `queued` | `testPresentDuringTheClosingAnimationWaitsInsteadOfBeingSwallowed`、`testQueuedLayerAppearsAsSoonAsTheDismissalFinishes`、`testTheLastTapWinsWhileALayerIsQueued` |
| 键盘正在退出时切换字段 | `AddFormRules` 的字段链（`FocusField` 顺序，不含延时） | `AddFormRulesTests.testTheChainWalksTheFormTopToBottom`、`testTheEndsOfTheChainDoNotWrapAround` |
| 数据更新时立即切换统计周期 | `NumberRoll.roll(to:at:)` 从当前显示值起新轮 | `testARetargetReplacesTheGoalInsteadOfTheJourney`、`testAReplacedRoundCannotEndTheRoundThatReplacedIt`；录屏 `03` 第 4–7 轮（130 ms 一枪） |
| 异步图片到达时用户已经离开该界面 | `IconPickerModel` 的按行落地 / 取消 | `IconPickerTests.testSelectionDropsWhenTheAppLeavesTheResultList`、`testCancelledIconDownloadLeavesNoFailureBehind`、`testSlowFirstQueryCannotOverwriteTheLatestOne` |

## 4. 减少动态效果

统一读 `@Environment(\.accessibilityReduceMotion)`，落点：

| 位置 | 关掉什么 | 换成什么 |
| --- | --- | --- |
| `AnimatedNumber.durationForCurrentSettings`（`Motion.swift:129`，`onChange` 在 `:116-117`） | 滚动 | 直接落位，仍然换轮次号让在路上的旧收尾作废 |
| `AnimatedNumber.onAppear`（`Motion.swift:106`） | 从 0 数上来 | `roll.prime(value)` |
| `SlideFade`（`Motion.swift:318-320`） | 位移与缩放 | 透明度仍由同一个 `x` 派生 → 一次轻微淡入，**不是空白帧** |
| `CarouselTrack.animatesSettle`（`OverviewComponents.swift:93,136,174`） | 松手回弹 | 直接钉在目标格，翻页判断照做 |
| `DonutChart.grow()`（`Charts.swift:85-88`）→ `land()`（`:96`） | 顺时针扫描 | `land()` 落到位 |
| `BarsChart` / `LineChart`（`Charts.swift:149-157,165,240`） | 生长动画 | `.animation(nil)`，`grown = true` / `drawn = 1` |
| `AmbientSwing`（`Motion.swift:358-360`） | 铃铛摆动 | 静止 |

实测（`before-reduce-motion/` vs `after-reduce-motion/`，系统开关由
`record-reduce-motion.sh` 用 `com.apple.Accessibility/ReduceMotionEnabled` 真写进去，
脚本回读打印 `系统「减少动态效果」已开：1`，我方探针也记到 `减少动态效果=true`）：

- 日历 8 连点：现在那 10 段里 7 段是 1 帧 / 0 ms 的直换月（峰值单帧 MAD 1.30–8.60），
  剩下 3 段 2–4 帧 / 102–148 ms 是同一帧里跟着重排的当日列表；基准仍然跑 1057 ms/32 帧
  和 453 ms/23 帧的推页。两边近全黑都是 0 帧。
- 总额数字：现在四次里三次是 1 帧 / 0 ms 的硬切（单帧 MAD 34.02–34.04）、一次 2 帧 / 117 ms；
  基准仍然滚 647 / 817 / 840 ms（43–48 帧）。
- 基准**源码**里 `accessibilityReduceMotion` `grep -rn` **0 命中**，当前树 10 命中
  （`Motion.swift` 4、`Charts.swift` 3、`CalendarAndStats.swift` / `OverviewComponents.swift` /
  `OverviewView.swift` 各 1），所以它在开关打开时的表现和关闭时统计上相同 ——
  这是 021d939 的真实缺口，不是量测噪声。

## 5. 触觉反馈

`SelectionHaptics`（`Motion.swift:5-15`）五个档位，映射按 §9.4：

| 事件 | 用哪个 | 备注 |
| --- | --- | --- |
| Tab / 分段选择 | `tick()` | `RootView.select`、`SlidingPill` |
| 保存成功 | `success()` | `AddSubscriptionView.submit()` 只在落库成功后 |
| 归档 / 移入回收站 | `impact(_:)` / `warning()` | 和成功区分开 |
| 写库失败 | `error()` | 注释写明「绝不能给失败操作配一个成功触感」 |
| 轮播跨页 | `tick()`，**只在真的跨过一格时** | `CarouselTrack.drag` 返回 `Int?`，nil 就不响（`OverviewComponents.swift:142-145`）；`CarouselTrackTests.testTheHapticIsOfferedOnlyWhenAPageIsCrossed` |

## 6. 性能红线

§9.5 的口径，落到具体实现：

- 时间轴只在真的在动的时候跑：`TimelineView(.animation(minimumInterval: nil, paused: !roll.isRolling))`
  （`Motion.swift:85`）。`minimumInterval` 写死 `1/60` 会把 120 Hz 设备按回 60 Hz ——
  基准提交就是这么写的（pristine `021d939` 的 `Saury/Views/Components/Motion.swift:83`：
  `TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !running))`），现在这条是 `nil`。
- `CarouselTrack.isSettling`（`:61`）落定之后停掉逐帧刷新，不为屏幕外的卡片持续启动时间轴。
- 金额排版用 `.monospacedDigit()` + `.fixedSize(horizontal: true)`（`Motion.swift:88-89`），
  滚动过程中宽度不抖。
- 轮播的位置算术是纯值类型，每帧不算 SwiftData 查询；统计在 `SubscriptionStats` 一侧算好再传进来。

## 7. EON 对标尺（竞品录屏实测）

来自那份 9 分 21 秒的 EON 录屏的运动扫描输出 `/tmp/motion/events.txt`
（16×34 格逐帧扫描，`dur` 秒、`pk` 峰值能量、`nframes` 帧数 @51.3 fps）。
**这份文件和录屏本身都不在仓库里**：录屏是用户提供的第三方素材（任务书 §16
「不在未经授权的情况下向公共仓库提交竞品录屏」），扫描器是一次性的 Swift 工具。
下面这张表就是它的完整转录，本文其余地方引用竞品数字时都指回这里，不再指向 `/tmp`。

扫描器给的 `dur` 是「突发窗口」而不是「边缘到达终点用了多久」，它会把前后的低能量帧也算进去。
所以这一列只用来判量级；需要精确到「哪一帧停住」的地方（比如 §1 的 sheet 时长）改用
`Docs/verification/pr6/scripts/edge.py` 的逐帧竖条 trace，输出在
`Docs/verification/pr6/results/eon-sheet-edge.txt`。两者对同一动作可以差到 1.7 倍
（编辑层呈现：`dur` 820 ms，边缘走线 470 ms）。
这把尺只对有**横贯屏幕的明暗边**的层成立（底部 sheet）；中部锚定的菜单 / 弹窗不适用，
那一列读到的是菜单里的文字行 —— EON-017 的币种浮层就是这种，所以它的开合至今只有 1 fps 扫描这一半证据，
「关闭无回弹」这类说法已经从矩阵里撤掉。反向对照的两段原始走线也留在同一个文件末尾，
免得下一个人以为 trace 到处都能用。

这一列是**竞品自己的数**，用来判断「有没有缺失」，不用来宣称比它快。

| EON 交互 | ev | dur | nframes | pk |
| --- | --- | --- | --- | --- |
| 轮播卡片拖动 | 296 / 297 / 298 / 299 | 480 / 170 / 450 / 420 ms | 24 / 9 / 26 / 23 | 5.49 / 1.41 / 1.47 / 2.01 |
| 周期分段切换 | 300–303 | 0–180 ms | 1 / 1 / 1 / 4 | ≤0.40（只动顶区） |
| 日历推入 | 310 / 311 | 520 / 500 ms | 32 / 26 | 8.97 / 6.30 |
| 日历选日 | 313–317 | 20–220 ms | 2–13 | 0.18–0.88 |
| 全年视图 | 318 / 319 / 322 | 970 / 320 / 2230 ms | 54 / 20 / 130 | 4.56 / 4.61 / 4.80 |
| 柱 ↔ 线切换 | 325 / 326 | 500 / 500 ms | 31 / 27 | 2.95 / 2.93 |
| Tab 切换 | 327 / 329 | 100 / 850 ms | 3 / 48 | 8.65 / 3.79 |

对照结论：
- 卡片拖动：EON 一次拖 170–480 ms、9–26 帧。我方松手后 157–888 ms、10–48 帧，同量级。
- 柱 ↔ 线：EON 每次约 500 ms / 27–31 帧。我方「切到折线」13.645 → 13.925（280 ms、17 帧），
  「切回柱状」17.288 → 17.890（602 ms、36 帧）—— 同量级，没有更长。
  尺子：**相邻帧差 ≥0.15 算「这一帧在动」**，两边和基准都用这一条（基准那一下真正走线
  14.665 → 14.963，298 ms / 19 帧）。
- 周期分段：EON 的能量只落在顶区（`mid≈0`），即切换不引发整页重排。我方同样只重画头部与图表。

## 8. 同场景前后对照（021d939 vs 现在）

五个场景，两棵树各自编译安装、同一段脚本时刻表、同一台 iPhone 17e 模拟器、
`simctl io recordVideo --codec=h264`。量测脚本在仓库里
（`Docs/verification/pr6/scripts/{motion,latency,fling,track,runs,edge}.py`），
逐条原始输出也在（`Docs/verification/pr6/results/*.txt`）；
「之前」那一侧用的基准探针 diff 同样在仓库里（`Docs/verification/pr6/baseline-probes.patch`，
5 个文件 +293 行，只有打点、白带和启动参数，没有一行改动画语义），
所以这张表不是「看过一次就没了」的对照：`git worktree add <目录> 021d939` + `git apply` 即可重搭。
判定逻辑：区域缩到 96 宽取相邻帧平均绝对差（MAD），突发=连续过阈帧，
彩色占比与近全黑帧数同时给出。`runs.py` 那条 0.15 底线用来把「其实一直在动、
只是幅度低于 1.0 阈值」的段切出来。

| 指标 | 基准 021d939 | 现在 | 结论 |
| --- | --- | --- | --- |
| 卡片拖动 −150 pt 时轨道位置 | −0.217 页（**逆着手指**） | +0.621 页 | 方向与线性都改对了：现在每 pt 恒为 0.00414 页 |
| 拖动途中 `focused` 翻转那一帧 | 1.505 → 2.212（单帧 +0.707 页） | 不存在这个量 | 基准把基准点挂在会跳的 `focused` 上 |
| 松手时还差多少页 | 1.217 / 1.283 / 1.348 / 1.413 页 | 0.379 / 0.083 / 1.006 / 0.446 页 | 基准四枪全是「松手才跳」；现在那一页 1.006 是甩动速度该走的路，不是补跳 |
| 松手到停 | 1067 / 868 / 602 / 387 ms（64/52/37/24 帧） | 888 / 640 / 408 / 157 ms（48/34/24/10 帧） | 更短且帧数没缩水 |
| 松手→首帧动 | +46 / +1 / +32 / +4 ms | +17 / +20 / +10 / +20 ms | 两边都在一帧内（这段录屏平均帧间隔 25 ms，运动密集时 17 ms） |
| 数字每轮时长 | 632–651 ms（中位 649） | 626–642 ms（中位 637.5） | 同一个 0.62 常量，没有拉长 |
| 数字动画竞争 | 上一轮收尾把下一轮掐掉：`第2轮收尾回调 当前第3轮 屏幕上=361.22 真值=681.36`、`第6轮收尾回调 … 屏幕上=227.12 真值=681.36 还在动=false` | 只有带轮次号的 `第N轮落定`，显示==真值；被顶掉的轮次不出声 | 基准那句收尾落下时 `running=false` → `Text` 立刻换成 `target`，屏幕上一步跳到位（361.22 → 227.12，单帧 −134.10），比自己那行落定早 0.49 秒 |
| 柱↔线切换 按下→首帧 | 1585 ms；且该区域按下前 11.657–14.633 s **一帧都没有** | 103 ms | 基准的偏好 setter 不发布变更（`SubPreferences` 只写 UserDefaults） |
| 「切回柱状」那一次点击 | 按下 16.878 s 之后，该区域到录屏结束（18.435 s）只交出 18.382 / 18.408 两帧，MAD=0.00 | 602 ms / 36 帧把柱子长到位 | 基准那一次点击根本没上屏 |
| 三 Tab / 弹窗过渡 | 7 段，220–510 ms，中位 423 ms，20–44 帧 | 8 段，223–433 ms，中位 316 ms，18–57 帧 | 中位短 25%；两棵树剧本同为 7 个动作但段数对不上，只能按聚合量比（见 QA 场景 05） |
| 近全黑空白帧（全部场景合计） | 0 | 0 | 两边都没有空白闪屏 |

## 9. 已知不足（不写成已完成）

1. **`track.py` 那条逐帧位移量测作废。** 列亮度剖面在这两个裁剪框上都撞到 `--max` 上限
   （`--max 60` 报 279 px、`--max 80` 报 171 px，都正好等于搜索边界），说明剖面被卡片重复图案带偏了。
   「单帧有没有瞬移」这个结论因此**只由探针日志和源码支撑**（`position` 序列 + `cardLayer` 的
   `depth = index - position`），不由像素支撑。录屏侧只保留「帧数 / 跨度 / 彩色占比 / 近全黑」这几项。
2. **`latency.py` 的首帧判定受录屏帧率限制。** 这台机器的 `simctl recordVideo` 是 VFR，
   整段平均帧间隔 25–56 ms、运动密集处 17 ms，所以「+12 ms」这类数字的真实含义是
   「落在下一帧里」，不能当成 12 ms 精度。凡是中位小于一个帧间隔的项，本文一律写成
   「一帧内」而不是比值。
3. **图表切换的「首帧 +103 ms」和「切回柱状 602 ms」不是突发检测器给的数。** 折线→柱状起步
   那几帧单帧 MAD 只有 0.2–0.8，在检测器 1.0 的阈值以下，它把「切回柱状」的首帧动一路报到了
   18.742 s（+1543 ms）—— 那是脚本收尾重排面板的那一下，不是这次点击的回车。本文的数出自
   逐帧 dump（`--mad -1`）加 0.15 这条静止底线（`runs.py`），接触表在
   `build/verification/pr6/frames/after-chart-morph-strip.png`（13.66 / 13.90 / 14.20 / 14.60 /
   17.40 / 17.70）和 `after-chart-second-toggle-strip.png`（17.20 / 17.85 / 18.40 / 18.76 / 18.95）。
   同一把尺在基准上量到的是 14.665 → 14.963（298 ms / 19 帧），所以「280 / 602 ms」可以横比。
4. **日历翻月的「按下→首帧」两版都在一帧内**（基准 7 ms、现在 21 ms，各 1 个静止样本）。
   这一项没有可声称的差距，本文不把它算作改进。
5. **未做真机量测。** 以上全部来自 iPhone 17e 模拟器；120 Hz 真机的帧预算、
   Instruments 的 Core Animation / Time Profiler 数据都还没有，见 `Docs/EON_QA.md` PR6 段「未验证」。
