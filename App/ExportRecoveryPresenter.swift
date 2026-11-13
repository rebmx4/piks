import UIKit

// Visible after a WebContent crash only. Rendering/saving stays owned by the
// store; neither reloading the page nor dismissing this card starts a new job.
final class ExportRecoveryPresenter {
    private weak var host: UIViewController?
    private let store: ExportOperationStore
    private var token: String?
    private var card: UIView?
    private let label = UILabel()
    private let save = UIButton(type: .system)

    init(host: UIViewController, store: ExportOperationStore) {
        self.host = host; self.store = store
        store.onChange = { [weak self] value in
            DispatchQueue.main.async {
                guard self?.token == value.token else { return }
                self?.refresh()
            }
        }
    }

    func restore(_ token: String?) {
        guard let token = token else { return }
        self.token = token; refresh()
    }

    private func refresh() {
        guard let token = token, let status = store.status(token), let host = host else { return }
        if card == nil { makeCard(host) }
        switch status.phase {
        case .exporting: label.text = "Экспорт продолжается после восстановления редактора."
        case .saving: label.text = "Видео готово. Сохранение в галерею…"
        case .saved: label.text = "Видео сохранено в галерею."
        case .fileReady: label.text = "Видео готово. Его можно сохранить в галерею."
        case .failed: label.text = status.reason ?? "Не удалось завершить экспорт."
        case .cancelled: label.text = "Экспорт отменён."
        }
        save.isHidden = status.phase == .exporting || status.phase == .saving || status.phase == .saved || status.file == nil
        host.view.bringSubviewToFront(card!)
    }

    private func makeCard(_ host: UIViewController) {
        let card = UIView(); card.backgroundColor = UIColor(white: 0.12, alpha: 0.98)
        card.layer.cornerRadius = 14; card.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white; label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        save.setTitle("Сохранить в галерею", for: .normal)
        save.addAction(UIAction { [weak self] _ in
            guard let self = self, let token = self.token, let file = self.store.status(token)?.file else { return }
            self.store.save(token, file: file, write: NativeExporter.saveToPhotos) { _, _ in }
        }, for: .touchUpInside)
        let close = UIButton(type: .system); close.setTitle("Закрыть", for: .normal)
        close.addAction(UIAction { [weak self] _ in
            self?.token = nil; self?.card?.removeFromSuperview(); self?.card = nil
        }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [save, close]); buttons.spacing = 12
        let stack = UIStackView(arrangedSubviews: [label, buttons]); stack.axis = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(stack); host.view.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            card.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        self.card = card
    }
}
