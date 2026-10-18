import UIKit

@MainActor
private final class AppUpdateBanner: UIView {
    var onUpdate: (() -> Void)?
    var onDismiss: (() -> Void)?

    init(version: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.10, alpha: 0.98)
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.28, alpha: 1).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)

        let title = UILabel()
        title.text = NSLocalizedString("Доступно обновление", comment: "New public App Store version")
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .white
        title.numberOfLines = 2
        title.accessibilityIdentifier = "app-update-title"
        let detail = UILabel()
        detail.text = String(format: NSLocalizedString("Версия %@", comment: "Published version"), version)
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .lightGray
        let labels = UIStackView(arrangedSubviews: [title, detail])
        labels.axis = .vertical
        labels.spacing = 3

        var config = UIButton.Configuration.filled()
        config.title = NSLocalizedString("Обновить", comment: "Open APIKS in App Store")
        config.baseBackgroundColor = UIColor(red: 205 / 255, green: 183 / 255, blue: 122 / 255, alpha: 1)
        config.baseForegroundColor = .black
        config.cornerStyle = .medium
        let update = UIButton(configuration: config)
        update.accessibilityIdentifier = "app-update-open"
        update.setContentHuggingPriority(.required, for: .horizontal)
        update.setContentCompressionResistancePriority(.required, for: .horizontal)
        update.addTarget(self, action: #selector(openStore), for: .touchUpInside)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .lightGray
        close.accessibilityIdentifier = "app-update-dismiss"
        close.accessibilityLabel = NSLocalizedString("Закрыть уведомление", comment: "Dismiss update notice")
        close.addTarget(self, action: #selector(dismissNotice), for: .touchUpInside)
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true
        close.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let row = UIStackView(arrangedSubviews: [labels, update, close])
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openStore() { onUpdate?() }
    @objc private func dismissNotice() { onDismiss?() }
}

@MainActor
final class AppUpdatePresenter: NSObject {
    private weak var host: UIViewController?
    private let checker: AppUpdateChecker
    private let openStore: (URL) -> Void
    private var banner: AppUpdateBanner?
    private var shownVersion: String?
    private var refreshTask: Task<Void, Never>?

    init(host: UIViewController, checker: AppUpdateChecker? = nil,
         openStore: ((URL) -> Void)? = nil) {
        self.host = host
        self.checker = checker ?? AppUpdateChecker()
        self.openStore = openStore ?? { UIApplication.shared.open($0) }
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        refreshTask?.cancel()
    }

    @objc private func becameActive() {
        Task { [weak self] in await self?.refresh() }
    }

    func refresh() async {
        if let task = refreshTask { await task.value; return }
        let task = Task { [weak self] in
            guard let self = self else { return }
            let update = await self.checker.check()
            self.display(update)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func display(_ update: AppUpdate?) {
        guard shownVersion != update?.version else { return }
        let previous = banner
        banner = nil; shownVersion = nil
        if let previous = previous {
            UIView.animate(withDuration: 0.15, animations: { previous.alpha = 0 }) { _ in
                previous.removeFromSuperview()
            }
        }
        guard let update = update, let host = host else { return }
        let notice = AppUpdateBanner(version: update.version)
        notice.onUpdate = { [weak self] in self?.openStore(AppUpdate.storeURL) }
        notice.onDismiss = { [weak self] in
            self?.checker.dismiss(update)
            self?.display(nil)
        }
        notice.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 6),
            notice.leadingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            notice.trailingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        banner = notice; shownVersion = update.version
        host.view.layoutIfNeeded()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        notice.alpha = 0
        notice.transform = CGAffineTransform(translationX: 0, y: -notice.bounds.height - host.view.safeAreaInsets.top - 12)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            notice.alpha = 1; notice.transform = .identity
        }
    }
}
