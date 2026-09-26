// Copyright © 2026 Liu-bits. All rights reserved.

import UIKit

/// Minimal app entry point. The window is owned by the scene, see SceneDelegate.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Installs the one component that touches the network. It is set here
        // rather than created inside the shell so tests and the local check
        // runner stay offline (they inject a stub, or nothing at all).
        ManifestTransportFactory.shared = URLSessionTransport()
        return true
    }
}
