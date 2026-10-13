import SwiftUI
import os

#if DEBUG
/// 探针的快门。
///
/// 命令行没有辅助功能权限，合成不了真实点击，所以验证只能靠「调那些控件背后的同一批方法
/// + 把当帧画面对账」。后者就要求快门拍的确实是用户此刻看到的那一张 —— 这台机器上
/// `simctl io screenshot` 落后 0.4～1 秒，赶不上「旧结果还挂着」这种只有一秒的状态，
/// 所以直接从窗口里画。
///
/// 挑窗口这一段是踩过坑才写成这样的：键盘上面那条字段工具栏 windowLevel 更高、
/// 却只占一小条，拿它的 bounds 画整屏会得到一张白图。判定一律走真条件，
/// 这里只管「等到那帧了没有」。
enum ProbeShutter {
    /// 写盘位置：App 自己的 tmp 目录。外面用 `simctl get_app_container … data` 找到它再拷走。
    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("saury-probe", isDirectory: true)
    }

    /// 等 `settle` 秒让 SwiftUI 画完，然后按一次快门。返回一句「拍到的是什么窗口」或失败原因。
    @MainActor
    static func capture(_ step: String, settle: TimeInterval = 0.8) async -> String {
        try? await Task.sleep(for: .seconds(settle))
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else {
            return "📸 \(step)：没有可用的 UIWindowScene，这一张没拍到"
        }
        let screen = scene.coordinateSpace.bounds
        let visible = scene.windows.filter { $0.isHidden == false && $0.alpha > 0.01 }
        let fullBore = visible.filter {
            $0.frame.width >= screen.width * 0.5 && $0.frame.height >= screen.height * 0.5
        }
        guard let window = fullBore.first(where: { $0.isKeyWindow })
                ?? fullBore.max(by: { $0.windowLevel < $1.windowLevel }) else {
            return "📸 \(step)：没有铺满屏的窗口（共 \(visible.count) 张），这一张没拍到"
        }
        let image = UIGraphicsImageRenderer(bounds: screen).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = directory.appendingPathComponent("\(step).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try image.pngData()?.write(to: url, options: .atomic)
        } catch {
            return "📸 \(step) 写盘失败：\(error.localizedDescription)"
        }
        return "📸 \(step) 取自 \(type(of: window)) level=\(window.windowLevel.rawValue)"
    }
}
#endif
