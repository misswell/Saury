# 期见 · 到期决策助手

“先提醒，再决定怎么处理。”

期见是一款本地优先的过期物品管理 App：冰箱里的牛奶、药盒上的效期、护照的换发日、订阅的续费日，扫一下包装就能记下来。它不读取银行、邮件或其他 App 的数据，也不上传任何东西 —— 照片、识别结果和记录全部留在设备上。

## 已实现

- SwiftUI + SwiftData 本地数据模型，12 个分类（食品、药品、保健品、护肤品、化妆品、日用品、证件、订阅、保修、滤芯耗材、宠物用品、其他）
- 输入以扫描为主：包装 OCR（Vision，设备端）、连续扫描（摄像头会话常驻，一件接一件）、从相册识别，条码在同一次扫描里一起认
- 条码商品模板：同一个条码第二次只需填日期和数量；同条码 + 同效期 + 同批次认成同一批，数量并进去而不是多出一条记录
- 位置、数量与单位、批次号、生产日期 / 开封日期 / 保质期天数、价格、备注都是可选项；最少只要名称和有效期
- 搜索、按分类 / 位置 / 紧急度 / 有无图片筛选、6 种排序，行左滑直接处理并带撤销
- 分阶段提醒队列：提前若干天到当天逐个提醒，普通提醒占 56 个位置、留 6 个给「稍后提醒」，只排未来 120 天以内，处理完一件会补下一件
- 通知上的处理动作：吃完 / 用完 / 丢弃 / 续期 / 取消 / 稍后提醒 / 归档，按分类给该给的那几个，和 App 里完全一致
- 1 月 31 日、闰年、时区、提醒时刻的日期计算
- 今天 / 物品 / 日历 / 统计四页；活动记录会留下每一次扫描当时那张原图，点开能自己看清那行喷码
- 图片：原图和缩略图落在 `Application Support/Saury/Images`，数据库里只存文件名；列表读缩略图，详情读全尺寸
- 分享扩展接文字 / 链接 / 图片：图片先落 App Group 暂存，回到期见直接进识别；外部输入走 FIFO 队列，连续分享不会互相顶掉
- App Intents / 快捷指令、WidgetKit 小组件（回答「下一件要处理的是什么」）
- JSON 备份 V2（`schemaVersion`：物品 / 历史 / 商品模板 / 位置清单）与幂等导入；只写 `version` 的中途版和订阅时代的老导出也读得动
- SwiftData 版本化迁移：V1（旧的续费记录）→ V2 → V3
- StoreKit 2 终身买断入口（产品 ID：`com.guofeng.saury.lifetime`）
- VoiceOver 语义标签

## 还没有

- **备份里的图片**：JSON 只带图片的文件名，不带图本身。换设备恢复之后物品和历史都在，但会说明「这张照片不在这台设备上了」。
- **iCloud 同步**：没有实现，所以也不在产品文案里出现；数据目前只在单台设备上。
- **商品库查询**：条码只用来认「这台设备上扫过的东西」，不查网络商品资料，所以扫完仍要确认名称和日期。
- **家庭共享 / 多设备协作**：未开始。
- **手动给物品配照片**：图片只能随扫描进来，编辑页还不能单独选一张当主图。

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

测试：

```bash
xcodebuild -project Saury.xcodeproj \
  -scheme Saury \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:SauryTests test
```

## 发布前配置

1. 在 Apple Developer 创建 App Group `group.com.guofeng.saury`，并绑定主 App、分享扩展和 Widget。
2. 在 App Store Connect 创建终身买断产品 `com.guofeng.saury.lifetime`。
3. 分享扩展和 Widget 通过 App Group 交换本地快照和待识别图片，不需要服务器。
4. 将来开启 iCloud 时，同步容器使用 `iCloud.com.guofeng.saury`，并在 CloudKit Dashboard 建立生产环境 schema —— 在那之前不要宣称同步能力。

## 产品边界

iOS 没有允许第三方 App 读取所有 App Store 订阅的公开 API，也没有哪个 API 能替你看清包装盒上那行喷码。因此「自动扫出你所有会过期的东西」不是期见的承诺：产品以扫描、OCR 和快捷输入降低记录成本，最后那一下确认始终由人来做。期见也不打算变成库存 ERP —— 批次、品牌、价格、照片都是可选项。
