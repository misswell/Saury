import UIKit

private struct ShareDraft: Codable {
    let name: String
    let amountMinorUnits: Int?
    let currencyCode: String
    let renewalDate: Date?
    let cycle: String?
    let source: String
}

final class ShareViewController: UIViewController {
    private let textView = UITextView()
    private let addButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        title = "添加到期提醒"
        textView.font = .preferredFont(forTextStyle: .body)
        textView.layer.cornerRadius = 14
        textView.backgroundColor = .secondarySystemBackground
        textView.text = extractedText()
        textView.translatesAutoresizingMaskIntoConstraints = false
        addButton.setTitle("发送到期见", for: .normal)
        addButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        addButton.addTarget(self, action: #selector(saveDraft), for: .touchUpInside)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        view.addSubview(addButton)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            textView.heightAnchor.constraint(equalToConstant: 160),
            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            addButton.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 18),
            addButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    private func extractedText() -> String {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            if let providers = item.attachments {
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier("public.plain-text") {
                        provider.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { [weak self] item, _ in
                            DispatchQueue.main.async { self?.textView.text = (item as? String) ?? "" }
                        }
                        return "正在读取分享内容…"
                    }
                }
            }
        }
        return ""
    }

    @objc private func saveDraft() {
        let lines = textView.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let name = lines.first ?? "来自分享的订阅"
        let draft = ShareDraft(name: name, amountMinorUnits: nil, currencyCode: "CNY", renewalDate: Calendar.current.date(byAdding: .month, value: 1, to: Date()), cycle: "monthly", source: "分享扩展")
        if let data = try? JSONEncoder().encode(draft), let defaults = UserDefaults(suiteName: "group.com.guofeng.saury") {
            defaults.set(data, forKey: "qijian.externalRenewalDraft")
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
