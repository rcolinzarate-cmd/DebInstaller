//
//  AppDelegate.swift
//  DebInstaller — mini-app para instalar .deb en jailbreak Dopamine sin Sileo/SSH.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: InstallerViewController())
        nav.navigationBar.prefersLargeTitles = true
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        return true
    }

    // Si el user abre un .deb desde Archivos → "Compartir con DebInstaller"
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if let nav = window?.rootViewController as? UINavigationController,
           let vc = nav.topViewController as? InstallerViewController {
            vc.handleIncomingDeb(url: url)
            return true
        }
        return false
    }
}
