# 期见 · 订阅续费提醒

"别再被自动续费偷袭。"

期见是一款本地优先的订阅管理 App：把散落各处的订阅收进一个地方，扣费之前提醒你，月/季/年花在哪一目了然。它不读取银行、邮件或其他 App 的数据，也不上传任何东西 —— 所有记录都留在设备上。

## 已实现

- SwiftUI + SwiftData 本地数据模型，V1（旧续费记录）→ V2/V3（到期物品）→ V4（订阅）版本化迁移；旧库里分类为「订阅」的到期记录自动接进新产品
- 订阅字段：名称、套餐、金额与币种、周期（每周 / 每月 / 每季度 / 每半年 / 每年 / 自定义 / 一次性）、分类、状态（自动续费 / 手动续费 / 停用）、开始与结束日期、提前提醒天数、支付方式、备注
- 图标三形态：内置图标库（SF 符号 + 调色板）、App Store 搜索（iTunes Search API，按店面国家）、网址抓图标、相册选图；卡片颜色可「自动」取自图标，也可手动单色或两三色渐变
- 总览页：月/季/年总额、即将扣费卡片轮播（今天 / 明天角标 + 圆点指示，一卡一订阅）、分类支出环形图、扣费日历（迷你月历可翻页）、支出趋势（柱状 / 折线切换）、累计支付、月均与平均每个；面板可在设置里隐藏、恢复或拖动排序
- 订阅页：月/季/年合计、搜索（名称 / 套餐 / 分类 / 备注）、列表 / 紧凑列表 / 卡片 / 紧凑卡片四种视图、筛选器（分类 / 状态 / 支付方式 / 币种多选）、按周期 / 买断分组等 8 种排序、选择订阅批量置顶 / 归档 / 删除、置顶 / 归档 / 删除的滑动操作
- 订阅详情：状态、当前单价、下次扣费、花费（按月分期的合计）、时间轴（扣费 / 调价 / 暂停 / 跳过 / 备注事件）、套餐与支付方式
- 拼车分摊：填总人数均摊或自定义自己的份额，统计只计入你的那份
- 货币：46 种币种、常用币种管理、实时汇率（open.er-api.com，离线用内置兜底表）、显示原始币种开关
- 扣费日历详情：月视图 + 全年视图，按天看扣费
- 小票：累计支付可以生成一张「订阅消费小票」图，保存或分享
- 提醒队列：按每个订阅的提前天数在扣费日的固定时刻提醒（提醒时刻可设 0-23 点整点），只排下一期，数据变化自动补差；第一笔订阅保存后引导开启通知
- iCloud 同步：订阅与图标镜像到 CloudKit 私有库，自动 / 立即同步、修复图标、以本机数据为准；需要在 Xcode 里给主 target 开启 iCloud 能力（容器 `iCloud.com.guofeng.saury`，entitlements 模板见 `Config/Saury.entitlements`）并在 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 加 `SAURY_ICLOUD`，未开启时页面显示「未配置能力」、所有云端操作安全降级
- 归档订阅 + 回收站（30 天保留期）、引导页三连、新功能页
- 导出 Markdown（末尾带 AI 分析提示词）/ JSON，导入 JSON / 通用 CSV，一键清空
- WidgetKit 小组件（回答「下一次扣费是什么」）、App Intents / 快捷指令、分享扩展接文字与链接
- StoreKit 2 打赏三档，一档一个真实的内购产品（`com.guofeng.saury.tip.instant` / `.tip.americano` / `.tip.coldbrew`，价格由 StoreKit 给）
- 主题色 8 选 1、浅色 / 深色 / 跟随系统、彩色卡片开关、快览文字模式、App 图标三态切换（自动 / 浅色 / 深色备用图标）、版本历史

## 还没有

- **iCloud 同步的默认构建**：代码已就位，但要真正跑起来需要给 App ID 开 iCloud 能力（见上），默认构建显示「未配置能力」；导出的 JSON 可以当手动备份。
- **自动发现订阅**：iOS 没有允许第三方 App 读取 App Store 订阅的公开 API，记录要自己添加。
- **实时汇率的历史回填**：折算统一用当前汇率，不按历史汇率重算过去的账。
- **通知上的快捷操作**：通知点开进 App 处理，锁屏按钮待加。

## 打开与构建

用 Xcode 26.3 或更新版本（当前用 Xcode 27.0 构建）打开 `Saury.xcodeproj`，选择 `Saury` scheme。最低部署版本为 iOS 17。

命令行模拟器构建：

```bash
xcodebuild -project Saury.xcodeproj \
  -scheme Saury \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

测试（统一入口，单模拟器）：

```bash
./scripts/test-ios.sh
```

## 发布前配置

1. 在 Apple Developer 创建 App Group `group.com.guofeng.saury`，并绑定主 App、分享扩展和 Widget。
2. 在 App Store Connect 创建三个一次性内购产品：`com.guofeng.saury.tip.instant`、`com.guofeng.saury.tip.americano`、`com.guofeng.saury.tip.coldbrew`（打赏三档，页面价格全部来自 StoreKit；没有配置时页面明说「内购暂不可用」）。
3. 分享扩展和 Widget 通过 App Group 交换快照与待添加条目，不需要服务器。
4. 将来开启 iCloud 时，同步容器使用 `iCloud.com.guofeng.saury`，并在 CloudKit Dashboard 建立生产环境 schema —— 在那之前不要宣称同步能力。

## 产品边界

iOS 没有允许第三方 App 读取所有 App Store 订阅的公开 API，所以「自动扫出你所有的订阅」不是期见的承诺：产品把添加订阅的成本压到最低（图标一键抓、金额币种周期三下点完），最后那一下确认始终由人来做。期见也不上传任何数据 —— 账单数字只留在你的设备上。
