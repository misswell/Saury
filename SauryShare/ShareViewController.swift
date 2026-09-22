import UIKit
import UniformTypeIdentifiers

/// 分享扩展（方案 §57）：文字、链接、图片都接。
///
/// 这个 target 只能带自己那份代码，所以队列的 JSON 在这里手写了一份，形状必须和主 App 的
/// `ExternalDraft` + `ExternalPayload` 对齐：`id` 是 uuid 字符串，`createdAt` 是 reference
/// date 的秒数，`payload` 是 `{"kind":"image","value":…}`。
/// 追加队列走原始 JSON：认不出的条目原样留着，绝不因为这边解不开就抹掉别人排的队。
final class ShareViewController: UIViewController {
    private static let suiteName = "group.com.guofeng.saury"
    private static let queueKey = "qijian.externalDrafts"

    private let preview = UIImageView()
    private let textView = UITextView()
    private let addButton = UIButton(type: .system)
    private let hint = UILabel()

    private var sharedImage: UIImage?
    private var isLink = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        title = "记一条到期提醒"

        preview.contentMode = .scaleAspectFit
        preview.isHidden = true
        preview.layer.cornerRadius = 14
        preview.clipsToBounds = true

        textView.font = .preferredFont(forTextStyle: .body)
        textView.layer.cornerRadius = 14
        textView.backgroundColor = .secondarySystemBackground
        textView.text = "正在读取分享内容…"

        addButton.setTitle("存进「期见」", for: .normal)
        addButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        addButton.addTarget(self, action: #selector(saveDraft), for: .touchUpInside)

        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [preview, textView, addButton, hint])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            preview.heightAnchor.constraint(equalToConstant: 200),
            textView.heightAnchor.constraint(equalToConstant: 160),
            addButton.heightAnchor.constraint(equalToConstant: 50)
        ])

        loadAttachment()
    }

    // MARK: - 读取分享内容

    private func loadAttachment() {
        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? []).flatMap { $0.attachments ?? [] }
        // 图片优先：一张包装照片比它附带的任何文字都有用。
        if let photo = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            load(photo, as: UTType.image.identifier)
            return
        }
        if let link = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            isLink = true
            load(link, as: UTType.url.identifier)
            return
        }
        if let text = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            load(text, as: UTType.plainText.identifier)
            return
        }
        showUnavailable("这次分享的内容里没有可用的文字、链接或图片。")
    }

    private func load(_ provider: NSItemProvider, as typeIdentifier: String) {
        provider.loadItem(forTypeIdentifier: typeIdentifier) { [weak self] item, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let image = Self.image(from: item) {
                    self.showImage(image)
                    return
                }
                if let text = Self.text(from: item), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.textView.text = text
                    self.hint.text = self.isLink ? "链接会记在「来源」里，名字先取域名。" : "第一行会当作物品名字。"
                    return
                }
                self.showUnavailable(error == nil
                    ? "这次分享的内容里没有可用的文字、链接或图片。"
                    : "分享内容没读出来：\(error?.localizedDescription ?? "未知原因")")
            }
        }
    }

    private func showImage(_ image: UIImage) {
        sharedImage = image
        preview.image = image
        preview.isHidden = false
        textView.isHidden = true
        hint.text = "「期见」会识别包装上的日期，认完再确认，不会直接存。"
    }

    private func showUnavailable(_ message: String) {
        sharedImage = nil
        preview.isHidden = true
        textView.isHidden = false
        textView.text = ""
        hint.text = message
    }

    /// 同一段内容可能以 UIImage / Data / 文件 URL 三种样子递过来，来源不同而已。
    private static func image(from item: Any?) -> UIImage? {
        if let image = item as? UIImage { return image }
        if let data = item as? Data { return UIImage(data: data) }
        if let url = item as? URL { return UIImage(contentsOfFile: url.path) }
        if let url = item as? NSURL, let path = url.path { return UIImage(contentsOfFile: path) }
        return nil
    }

    private static func text(from item: Any?) -> String? {
        if let text = item as? String { return text }
        if let url = item as? URL { return url.absoluteString }
        if let url = item as? NSURL { return url.absoluteString }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    // MARK: - 存下这一条

    @objc private func saveDraft() {
        if let image = sharedImage {
            guard let fileName = writePendingImage(image),
                  append(payload: ["kind": "image", "value": fileName]) else {
                hint.text = "共享目录用不了，这张图没能带过去。"
                return
            }
        } else {
            let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  append(payload: ["kind": isLink ? "url" : "text", "value": text]) else {
                hint.text = "没有可保存的内容。"
                return
            }
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func writePendingImage(_ image: UIImage) -> String? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.suiteName),
              let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let directory = base.appendingPathComponent("Pending", isDirectory: true)
        let fileName = "\(UUID().uuidString).jpg"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    private func append(payload: [String: Any]) -> Bool {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else { return false }
        var drafts: [[String: Any]] = []
        if let data = defaults.data(forKey: Self.queueKey) {
            guard let object = try? JSONSerialization.jsonObject(with: data), let existing = object as? [[String: Any]] else {
                return false
            }
            drafts = existing
        }
        drafts.append([
            "id": UUID().uuidString,
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "source": "分享扩展",
            "payload": payload
        ])
        guard let data = try? JSONSerialization.data(withJSONObject: drafts) else { return false }
        defaults.set(data, forKey: Self.queueKey)
        return true
    }
}
