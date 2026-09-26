// Copyright © 2026 Liu-bits. All rights reserved.

import UIKit

/// Scene delegate creating and owning the app window.
///
/// Apps built with the iOS 27 SDK must adopt the scene based life cycle,
/// otherwise they do not launch at all. See
/// https://developer.apple.com/documentation/technotes/tn3187-migrating-to-the-uikit-scene-life-cycle
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = TerminalViewController()
        window.makeKeyAndVisible()

        self.window = window
    }
}
