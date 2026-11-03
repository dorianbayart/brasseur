import AppKit
import SwiftUI

@main
struct BrasseurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // L'icône de la barre des menus (AppKit) ouvre la fenêtre avec l'action SwiftUI :
        // sans Dock ni fenêtre, il n'y a pas d'autre moyen fiable de la recréer.
        let _ = WindowOpener.action = openWindow
        Window("Brasseur", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .defaultLaunchBehavior(UserDefaults.standard.object(forKey: "openWindowAtLaunch") as? Bool == false ? .suppressed : .presented)
        .commands {
            CommandMenu("Brew") {
                Button(tr("Rechercher des mises à jour")) { model.checkForUpdates() }
                    .keyboardShortcut("r")
                Button(tr("Tout mettre à jour sauf les paquets utilisés")) { model.upgrade(.allExceptInUse) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(model.pendingCount == 0)
                Button(tr("Tout mettre à jour")) { model.upgrade(.all) }
                    .disabled(model.pendingCount == 0)
                Divider()
                Button(tr("Nettoyer (brew cleanup)")) { model.cleanup() }
                Button(tr("Supprimer les dépendances inutiles (brew autoremove)")) { model.autoremove() }
                Button(tr("Diagnostic (brew doctor)")) { model.doctor() }
                Divider()
                Button(tr("Arrêter les opérations")) { model.cancelAll() }
                    .keyboardShortcut(".")
                    .disabled(!model.isBusy)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Icône de la barre des menus (clic : menu, double-clic : fenêtre).
    @MainActor private var statusItem: StatusItemController?
    private var sigterm: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sans fenêtre, macOS peut fermer de lui-même une app jugée inactive (« automatic termination ») :
        // Brasseur doit rester dans la barre des menus.
        ProcessInfo.processInfo.disableAutomaticTermination(tr("Brasseur reste dans la barre des menus"))
        MainActor.assumeIsolated {
            AppModel.shared.start()
            statusItem = StatusItemController()
        }
        // `kill` / `pkill` : quitter proprement, pour arrêter aussi les lectures brew en cours.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source
        MainActor.assumeIsolated {
            // macOS restaure l'état précédent (parfois sans fenêtre) : on respecte le réglage.
            if AppModel.shared.openWindowAtLaunch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.showMainWindow() }
            }
        }
    }

    /// Clic sur l'icône du Dock sans fenêtre visible : on rouvre la fenêtre principale.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { Self.showMainWindow() } }
        return true
    }

    @MainActor static func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.title == "Brasseur" && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        if let open = WindowOpener.action {
            open(id: "main")
            return
        }
        // Fenêtre fermée : SwiftUI la propose dans le menu Fenêtre, on déclenche cette entrée.
        if let menu = NSApp.windowsMenu, let index = menu.items.firstIndex(where: { $0.title == "Brasseur" }) {
            menu.performActionForItem(at: index)
        }
    }

    /// Ouvre les réglages par leur entrée du menu de l'app (⌘,), comme le ferait SettingsLink.
    @MainActor static func showSettings() {
        NSApp.activate()
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        appMenu.performActionForItem(at: index)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.runner?.terminateReads() }
    }

    /// Fermer la fenêtre ne quitte pas : Brasseur reste dans la barre des menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Action SwiftUI d'ouverture de fenêtre, lue dans le corps de l'app pour servir au code AppKit.
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction?
}
