import AppKit
import Combine

/// Icône de la barre des menus : un clic ouvre le menu, un double-clic ouvre la fenêtre de Brasseur.
/// (MenuBarExtra de SwiftUI ne distingue pas le double-clic, d'où cette version AppKit.)
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var observation: AnyCancellable?
    private var pendingMenu: DispatchWorkItem?
    private var model: AppModel { AppModel.shared }

    override init() {
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        // objectWillChange précède la modification : la mise à jour se fait au tour suivant de la boucle.
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshButton() }
        }
        refreshButton()
    }

    private func refreshButton() {
        guard let button = item.button else { return }
        let count = model.pendingCount
        let busy = model.currentTask != nil
        let symbol: String
        if busy { symbol = "arrow.triangle.2.circlepath" }
        else if !model.isOnline && count == 0 { symbol = "wifi.slash" }
        else { symbol = count > 0 ? "mug.fill" : "mug" }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Brasseur")
        image?.isTemplate = true
        if button.image?.name() != symbol {
            image?.setName(symbol)
            button.image = image
        }
        let title = count > 0 ? "\(count)" : ""
        if button.title != title {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .baselineOffset: 0,
            ])
        }
        button.toolTip = count > 0
            ? trn(count, "%d mise à jour en attente", "%d mises à jour en attente")
            : tr("Tout est à jour")
    }

    // MARK: Clics

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight { pendingMenu?.cancel(); showMenu(); return }

        if (event?.clickCount ?? 1) >= 2 {
            // Double-clic : pas de menu, la fenêtre.
            pendingMenu?.cancel()
            pendingMenu = nil
            AppDelegate.showMainWindow()
            return
        }
        // Simple clic : le menu s'ouvre si aucun second clic ne suit (délai plafonné pour rester vif).
        pendingMenu?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showMenu() }
        pendingMenu = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(NSEvent.doubleClickInterval, 0.3), execute: work)
    }

    private func showMenu() {
        pendingMenu = nil
        item.menu = buildMenu()
        item.button?.performClick(nil)   // ouvre le menu attaché sous l'icône
        item.menu = nil                  // sinon le prochain clic ouvrirait le menu sans passer par clicked(_:)
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pending = model.pendingPackages

        menu.addItem(info(pending.isEmpty ? tr("Tout est à jour")
                          : trn(pending.count, "%d mise à jour en attente", "%d mises à jour en attente")))
        if let task = model.currentTask { menu.addItem(info(tr("En cours : %@", task))) }
        if !model.isOnline {
            menu.addItem(info(tr("Hors ligne : vérifications en pause")))
        } else if let error = model.lastCheckError {
            menu.addItem(info(tr("Dernière vérification en échec : %@", error)))
        } else if let date = model.lastCheck {
            menu.addItem(info(tr("Vérifié %@", relativeDate(date))))
        }

        if !pending.isEmpty {
            menu.addItem(.separator())
            for p in pending.prefix(15) {
                let id = p.id
                menu.addItem(action("\(p.name)  \(p.installedVersion) → \(p.latestVersion)" + suffix(p)) {
                    AppModel.shared.upgrade(.ids([id]))
                })
            }
            if pending.count > 15 { menu.addItem(info(tr("… et %d autres", pending.count - 15))) }
            menu.addItem(.separator())
            let free = pending.filter { !$0.inUse }.count
            let exceptInUse = action(tr("Tout mettre à jour sauf les paquets utilisés (%d)", free)) {
                AppModel.shared.upgrade(.allExceptInUse)
            }
            exceptInUse.isEnabled = free > 0
            menu.addItem(exceptInUse)
            menu.addItem(action(tr("Tout mettre à jour (%d)", pending.count)) { AppModel.shared.upgrade(.all) })
        }

        menu.addItem(.separator())
        menu.addItem(action(tr("Rechercher des mises à jour")) { AppModel.shared.checkForUpdates() })
        if model.isBusy {
            menu.addItem(action(tr("Arrêter les opérations")) { AppModel.shared.cancelAll() })
        }
        menu.addItem(.separator())
        menu.addItem(action(tr("Ouvrir Brasseur…")) { AppDelegate.showMainWindow() })
        menu.addItem(action(tr("Réglages…")) { AppDelegate.showSettings() })
        let quit = action(tr("Quitter Brasseur")) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }

    private func suffix(_ p: BrewPackage) -> String {
        if model.activeIDs.contains(p.id) { return "  · " + tr("en cours") }
        if model.queuedIDs.contains(p.id) { return "  · " + tr("en attente") }
        return p.inUse ? "  · " + tr("utilisé") : ""
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, handler: handler)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    @objc private func run() { MainActor.assumeIsolated { handler() } }
}
