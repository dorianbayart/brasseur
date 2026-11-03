import SwiftUI

enum SidebarItem: String, Hashable {
    case updates, installed, search, log
}

struct MainView: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage("section") private var storedSection: String = SidebarItem.updates.rawValue
    private var section: Binding<SidebarItem?> {
        Binding(get: { SidebarItem(rawValue: storedSection) ?? .updates },
                set: { storedSection = ($0 ?? .updates).rawValue })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: section) {
                Label(tr("Mises à jour"), systemImage: "arrow.down.circle")
                    .badge(model.pendingCount)
                    .tag(SidebarItem.updates)
                Label(tr("Installés"), systemImage: "shippingbox")
                    .badge(model.packages.count)
                    .tag(SidebarItem.installed)
                Label(tr("Rechercher"), systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                Label(tr("Journal"), systemImage: "text.alignleft")
                    .tag(SidebarItem.log)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.lastOperationError {
                    Banner(text: error, style: .error,
                           onOpen: section.wrappedValue == .log ? nil : { storedSection = SidebarItem.log.rawValue },
                           onClose: { model.lastOperationError = nil })
                }
                if let error = model.loadError {
                    Banner(text: error, style: .error,
                           onOpen: section.wrappedValue == .log ? nil : { storedSection = SidebarItem.log.rawValue },
                           onClose: nil)
                }
                Group {
                    switch section.wrappedValue ?? .updates {
                    case .updates: UpdatesView()
                    case .installed: InstalledView()
                    case .search: SearchView()
                    case .log: LogView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(showLog: { storedSection = SidebarItem.log.rawValue })
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.checkForUpdates()
                } label: {
                    Label(tr("Rechercher des mises à jour"), systemImage: "arrow.clockwise")
                }
                .help(tr("brew update, puis relecture des paquets (⌘R)"))
                .disabled(!model.isOnline)
                SettingsLink {
                    Label(tr("Réglages"), systemImage: "gearshape")
                }
                .help(tr("Réglages de Brasseur (⌘,)"))
            }
        }
    }
}

struct Banner: View {
    enum Style { case error, info }
    let text: String
    let style: Style
    /// Ouvre le journal (clic sur le bandeau ou sur « Voir le journal »).
    var onOpen: (() -> Void)?
    let onClose: (() -> Void)?

    private var tint: Color { style == .error ? .orange : .blue }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: style == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(tint)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            if let onOpen {
                Button(tr("Voir le journal"), action: onOpen).buttonStyle(.link)
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tr("Fermer"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { onOpen?() }
        .help(onOpen == nil ? "" : tr("Cliquer pour ouvrir le journal"))
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }
}

/// Date relative dans la langue de l'app (« il y a 2 minutes » / « 2 minutes ago »).
func relativeDate(_ date: Date) -> String {
    date.formatted(Date.RelativeFormatStyle(presentation: .named).locale(L10n.locale))
}

struct StatusBar: View {
    @ObservedObject private var model = AppModel.shared
    let showLog: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let task = model.currentTask {
                ProgressView().controlSize(.small)
                Button(task, action: showLog).buttonStyle(.link).lineLimit(1)
                if !model.pendingTasks.isEmpty {
                    Text(tr("+ %d en attente", model.pendingTasks.count)).foregroundStyle(.secondary)
                }
                Button(tr("Arrêter")) { model.cancelAll() }.controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text(tr("Prêt")).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.isOnline {
                Label(tr("Hors ligne"), systemImage: "wifi.slash").foregroundStyle(.orange)
            } else if let error = model.lastCheckError {
                Label(tr("Vérification en échec"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).help(error)
            }
            if let date = model.lastCheck {
                Text(tr("Vérifié %@", relativeDate(date))).foregroundStyle(.secondary)
            } else {
                Text(tr("Jamais vérifié")).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

/// Petites pastilles d'état d'un paquet.
struct StatusBadges: View {
    @ObservedObject private var model = AppModel.shared
    let package: BrewPackage

    var body: some View {
        HStack(spacing: 4) {
            if model.activeIDs.contains(package.id) { Chip(text: tr("en cours"), color: .blue, help: tr("Mise à jour en cours")) }
            else if model.queuedIDs.contains(package.id) { Chip(text: tr("en attente"), color: .blue, help: tr("Dans la file des mises à jour")) }
            if package.inUse { Chip(text: tr("utilisé"), color: .orange, help: package.usageDescription) }
            if package.serviceRunning { Chip(text: tr("service"), color: .purple, help: tr("Service brew démarré")) }
            if package.needsAdmin { Chip(text: tr("admin"), color: .red, help: tr("Demande le mot de passe administrateur : jamais mis à jour automatiquement")) }
            if package.pinned { Chip(text: tr("épinglé"), color: .gray, help: tr("Épinglé avec brew pin : jamais mis à jour")) }
            if model.isIgnored(package) { Chip(text: tr("ignoré"), color: .gray, help: tr("Exclu des mises à jour groupées")) }
            if package.kind == .formula && !package.onRequest { Chip(text: tr("dépendance"), color: .secondary, help: tr("Installé comme dépendance d'un autre paquet")) }
            if package.deprecated { Chip(text: tr("obsolète"), color: .red, help: tr("Déprécié ou désactivé dans Homebrew")) }
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var help: String = ""

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
            .help(help)
    }
}

