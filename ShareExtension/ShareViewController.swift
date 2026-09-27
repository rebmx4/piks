import UIKit

// «Поделиться → APIKS» (сборка №19, владелец 27.09.2026: «чтобы в окне
// «Поделиться» предлагали моё приложение»). Ролик или звук из «Фото»,
// «Файлов», мессенджеров копируется в общую папку группы приложений
// (group.com.piks.app, папка Inbox): файл и рядом описание <номер>.json.
// Само приложение iOS из окна «Поделиться» открыть не даёт. Открыли APIKS —
// страница забирает файлы (App/MediaInbox.swift): звук встаёт у полосы
// открытого проекта, видео — в конец ленты; без проекта видео открывает
// новый проект, а звук ждёт, пока проект откроют.
final class ShareViewController: UIViewController {

    static let group = "group.com.piks.app"
    private let card = UIView()
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.4)
        card.backgroundColor = UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        card.layer.cornerRadius = 18
        card.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = "Добавляю в APIKS…"
        label.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(card)
        card.addSubview(spinner)
        card.addSubview(label)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
            spinner.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            spinner.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
        ])
        collect()
    }

    private func collect() {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareViewController.group) else {
            finish("Не вышло: нет общей папки приложения", ok: false)
            return
        }
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let stamp = Date().timeIntervalSince1970
        let group = DispatchGroup()
        let lock = NSLock()
        var saved = 0
        for (n, p) in providers.enumerated() {
            let type: String
            if p.hasItemConformingToTypeIdentifier("public.movie") { type = "public.movie" }
            else if p.hasItemConformingToTypeIdentifier("public.audio") { type = "public.audio" }
            else { continue }
            group.enter()
            // Временный файл живёт только внутри обработчика — копируем сразу.
            // Общая папка на том же диске: копия большого ролика — мгновенный клон.
            p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                guard let url = url else { return }
                let video = type == "public.movie"
                let ext = url.pathExtension.isEmpty ? (video ? "mov" : "m4a") : url.pathExtension.lowercased()
                let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                let dst = inbox.appendingPathComponent(id + "." + ext)
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    let meta: [String: Any] = ["kind": video ? "video" : "audio", "name": url.lastPathComponent,
                                               "file": dst.lastPathComponent, "at": stamp, "n": n]
                    let data = try JSONSerialization.data(withJSONObject: meta)
                    try data.write(to: inbox.appendingPathComponent(id + ".json"))    // описание — последним
                    lock.lock(); saved += 1; lock.unlock()
                } catch {
                    try? FileManager.default.removeItem(at: dst)
                }
            }
        }
        group.notify(queue: .main) {
            if saved > 0 {
                self.finish("Добавлено в APIKS — откройте приложение", ok: true)
            } else {
                self.finish("Здесь нет видео или звука", ok: false)
            }
        }
    }

    private func finish(_ text: String, ok: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1.4 : 2.2)) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
