import UIKit
import UniformTypeIdentifiers

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var browser: BrowserViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let browser = BrowserViewController(forOpening: [.pdf])
        self.browser = browser

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window

        // Launched by tapping a PDF in Files / another app's share sheet.
        if let url = options.urlContexts.first?.url {
            browser.openDocument(at: url)
            return
        }

        // Otherwise pick up exactly where we left off (FR-5) — no browser detour.
        if let url = LastDocument.resolve() {
            browser.openDocument(at: url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        browser?.openDocument(at: url)
    }
}
