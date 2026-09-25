# Saury 项目工作规则

## 测试包保留

- iOS 打包产物统一放在 `/Users/guofeng/Code/solo/Saury/build`。
- 将 `.ipa` 和 `.xcarchive` 视为测试包；每次打包完成后，只保留最新的一份测试包。
- 历史测试包不要直接删除，移入 macOS 废纸篓 `/Users/guofeng/.Trash`。
- 按产物的实际 build 号和修改时间判断最新包；`DerivedData`、验证目录和导出配置文件不属于测试包，除非用户另行要求，不要随测试包清理。

## iOS Simulator 测试规则

日常开发验证默认只能使用一个 iOS Simulator。

所有 iOS 测试必须优先通过：

```
./scripts/test-ios.sh
```

执行。

禁止 Agent：

- 自行创建新的 Simulator
- 使用 `simctl create`
- 同时指定多个 `-destination`
- 默认开启 XCTest parallel testing
- 使用 `-parallel-testing-enabled YES`
- 自动增加 parallel worker
- 为了提高测试速度自行创建 simulator clone
- 修改测试脚本把 worker 数量提高

默认必须：

```
-parallel-testing-enabled NO
-maximum-parallel-testing-workers 1
```

如果现有测试 Simulator 不可用：

先列出已有：

```
xcrun simctl list devices available
```

复用已有设备。不能自行创建新设备。

只有用户明确要求并行测试时，才允许临时最多使用 2 个 worker。
并行测试结束后必须恢复默认单 Simulator 配置。

日常开发、修 bug、功能验证都使用 1 个。
