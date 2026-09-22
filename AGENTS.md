# Saury 项目工作规则

## 测试包保留

- iOS 打包产物统一放在 `/Users/guofeng/Code/solo/Saury/build`。
- 将 `.ipa` 和 `.xcarchive` 视为测试包；每次打包完成后，只保留最新的一份测试包。
- 历史测试包不要直接删除，移入 macOS 废纸篓 `/Users/guofeng/.Trash`。
- 按产物的实际 build 号和修改时间判断最新包；`DerivedData`、验证目录和导出配置文件不属于测试包，除非用户另行要求，不要随测试包清理。
