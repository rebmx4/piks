import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ViewController()
        self.window = window
        window.makeKeyAndVisible()
    }

    // apiks://share (сборка №20): приложение открыло окно «Поделиться» —
    // страница сразу забирает файлы (при холодном запуске она спросит сама).
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard URLContexts.contains(where: { $0.url.scheme == "apiks" }) else { return }
        (window?.rootViewController as? ViewController)?.nudgeInbox()
    }
}
