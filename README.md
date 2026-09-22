# 期见 · 续费决策助手

“先提醒，再决定要不要继续。”

期见是一款本地优先的 iOS 订阅到期提醒工具。它不会读取银行、邮件或其他 App 的订阅数据；用户可以手动添加，也可以通过截图 OCR、分享扩展和快捷指令快速建立记录。

## 已实现

- SwiftUI + SwiftData 本地数据模型
- 月度、年度、自定义周期、免费试用和单次到期
- 7 天 / 3 天 / 1 天 / 当天等分阶段本地通知
- 通知操作：已取消续费、继续订阅、明天提醒
- 1 月 31 日、闰年、时区和提醒时刻的日期计算
- 首页倒计时、月度支出、续费日历和决定历史
- 截图 OCR（Vision，设备端）
- 分享扩展、App Intents / 快捷指令
- WidgetKit 最近一次续费小组件
- JSON 数据导出、Apple 订阅管理入口、VoiceOver 语义标签
- StoreKit 2 终身买断入口（产品 ID：`com.guofeng.saury.lifetime`）

## 打开与构建

使用 Xcode 26.3 打开 `Saury.xcodeproj`，选择 `Saury` scheme。最低部署版本为 iOS 17。

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
xcodebuild test \
  -project Saury.xcodeproj \
  -scheme Saury \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:SauryTests
```

## 发布前配置

1. 在 Apple Developer 创建 App Group `group.com.guofeng.saury`，并绑定主 App、分享扩展和 Widget。
2. 在 App Store Connect 创建终身买断产品 `com.guofeng.saury.lifetime`。
3. 如果开启 iCloud，同步容器应使用 `iCloud.com.guofeng.saury`，并在 CloudKit Dashboard 建立生产环境 schema。
4. 分享扩展和 Widget 当前通过 App Group 交换本地快照，不需要服务器。

## 产品边界

iOS 没有允许第三方 App 读取所有 App Store 订阅的公开 API。因此“自动扫描全部订阅”不是也不应该是期见的承诺；产品以手动添加、OCR 和快捷输入为主。
