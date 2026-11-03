import AppKit
import SwiftUI

/// Demande de confirmation avant une action sensible sur un paquet.
struct PendingAction: Identifiable {
    enum Kind { case upgradeInUse, uninstall }
    let id = UUID()
    let kind: Kind
    let package: BrewPackage
}

struct UpdatesView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, apps, formulae
        var id: Self { self }
        var label: String {
            switch self {
            case .all: return tr("Tout")
            case .apps: return tr("Apps")
            case .formulae: return tr("Formules")
            }
        }
    }

    @ObservedObject private var model = AppModel.shared
    @State private var selection = Set<String>()
    @State private var pending: PendingAction?
    @State private var filter: Filter = .all

    var body: some View {
        let outdated = model.outdatedPackages
        let rows = sorted(outdated.filter { p in
            switch filter {
            case .all: return true
            case .apps: return p.kind == .cask
            case .formulae: return p.kind == .formula
            }
        })
        let bulk = model.pendingPackages
        let free = bulk.filter { !$0.inUse }
        let inUse = bulk.count - free.count

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(outdated.isEmpty ? tr("Tout est à jour")
                         : trn(outdated.count, "%d mise à jour disponible", "%d mises à jour disponibles"))
                        .font(.title2.weight(.semibold))
                    Text(summary(outdated: outdated.count, bulk: bulk.count, inUse: inUse))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !selection.isEmpty {
                    Button(tr("Mettre à jour la sélection (%d)", selection.count)) {
                        model.upgrade(.ids(selection))
                        selection.removeAll()
                    }
                }
                Button(tr("Tout sauf utilisés (%d)", free.count)) { model.upgrade(.allExceptInUse) }
                    .disabled(free.isEmpty)
                    .help(tr("Met à jour tout ce qui n'est pas en cours d'utilisation"))
                Button(tr("Tout mettre à jour (%d)", bulk.count)) { model.upgrade(.all) }
                    .buttonStyle(.borderedProminent)
                    .disabled(bulk.isEmpty)
                    .help(model.quitAndRelaunch ? tr("Les apps ouvertes sont fermées puis relancées") : tr("Les apps ouvertes sont laissées de côté"))
            }
            .padding(16)

            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Toggle(tr("Mise à jour automatique"), isOn: $model.autoUpgrade)
                    .toggleStyle(.checkbox)
                    .help(tr("Met à jour seul ce qui n'est pas utilisé (ni ignoré, ni épinglé, ni soumis au mot de passe administrateur)"))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 8)

            if !model.loaded {
                ProgressView(tr("Lecture des paquets…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if outdated.isEmpty {
                ContentUnavailableView(tr("Rien à mettre à jour"), systemImage: "checkmark.seal",
                                       description: Text(tr("Les vérifications se font automatiquement en arrière-plan.")))
            } else {
                Table(rows, selection: $selection) {
                    TableColumn(tr("Nom")) { p in NameCell(package: p) }
                        .width(min: 160, ideal: 200)
                    TableColumn(tr("Installée")) { p in Text(p.installedVersion).monospacedDigit().foregroundStyle(.secondary) }
                        .width(min: 55, ideal: 80)
                    TableColumn(tr("Disponible")) { p in Text(p.latestVersion).monospacedDigit().fontWeight(.medium) }
                        .width(min: 55, ideal: 80)
                    TableColumn(tr("Taille")) { p in Text(p.formattedSize).monospacedDigit().foregroundStyle(.secondary) }
                        .width(min: 50, ideal: 70)
                    TableColumn(tr("État")) { p in StatusBadges(package: p) }
                        .width(min: 100, ideal: 150)
                    TableColumn("") { p in UpgradeButton(package: p) { requestUpgrade(p) } }
                    .width(120)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    PackageMenu(ids: ids, pending: $pending, onUpgrade: requestUpgrade)
                } primaryAction: { ids in
                    if ids.count == 1, let p = model.packages.first(where: { $0.id == ids.first }) { requestUpgrade(p) }
                }
                if selection.count == 1, let p = model.packages.first(where: { $0.id == selection.first }) {
                    Divider()
                    PackageDetailPanel(package: p, pending: $pending, onUpgrade: requestUpgrade,
                                       onClose: { selection.removeAll() })
                        .frame(height: 230)
                }
            }
        }
        .modifier(PackageConfirmations(pending: $pending))
    }

    /// Les apps d'abord, puis les formules installées à la main, puis les dépendances.
    private func sorted(_ list: [BrewPackage]) -> [BrewPackage] {
        func rank(_ p: BrewPackage) -> Int { p.kind == .cask ? 0 : (p.onRequest ? 1 : 2) }
        return list.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func summary(outdated: Int, bulk: Int, inUse: Int) -> String {
        var parts: [String] = []
        if inUse > 0 { parts.append(tr("%d en cours d'utilisation", inUse)) }
        let excluded = outdated - bulk
        if excluded > 0 { parts.append(trn(excluded, "%d ignoré ou épinglé", "%d ignorés ou épinglés")) }
        return parts.isEmpty ? tr("Aucun paquet en cours d'utilisation.") : parts.joined(separator: " · ")
    }

    private func requestUpgrade(_ p: BrewPackage) {
        if p.inUse { pending = PendingAction(kind: .upgradeInUse, package: p) }
        else { model.upgrade(.ids([p.id])) }
    }
}

struct InstalledView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, formulae, casks, inUse
        var id: Self { self }
        var label: String {
            switch self {
            case .all: return tr("Tous")
            case .formulae: return tr("Formules")
            case .casks: return "Casks"
            case .inUse: return tr("Utilisés")
            }
        }
    }

    @ObservedObject private var model = AppModel.shared
    @State private var filter: Filter = .all
    @State private var hideDependencies = true
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var pending: PendingAction?
    @State private var sortOrder = [KeyPathComparator(\BrewPackage.name, comparator: .localizedStandard)]

    var body: some View {
        let rows = model.packages.filter(matches).sorted(using: sortOrder)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                Toggle(tr("Masquer les dépendances"), isOn: $hideDependencies).toggleStyle(.checkbox)
                Spacer()
                Text(trn(rows.count, "%d paquet", "%d paquets")).foregroundStyle(.secondary)
            }
            .padding(12)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(tr("Nom"), value: \.name, comparator: .localizedStandard) { p in NameCell(package: p) }
                    .width(min: 160, ideal: 240)
                TableColumn(tr("Type"), value: \.kindLabel) { p in Text(p.kind.label).foregroundStyle(.secondary) }
                    .width(min: 45, ideal: 60)
                TableColumn(tr("Version")) { p in
                    HStack(spacing: 4) {
                        Text(p.installedVersion).monospacedDigit()
                        if p.outdated {
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                            Text(p.latestVersion).monospacedDigit().foregroundStyle(.blue)
                        }
                    }
                }
                .width(min: 80, ideal: 120)
                TableColumn(tr("Taille"), value: \.sizeForSort) { p in
                    Text(p.formattedSize).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 70)
                TableColumn(tr("État")) { p in StatusBadges(package: p) }
                    .width(min: 90, ideal: 150)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                PackageMenu(ids: ids, pending: $pending, onUpgrade: requestUpgrade)
            }
            if selection.count == 1, let p = model.packages.first(where: { $0.id == selection.first }) {
                Divider()
                PackageDetailPanel(package: p, pending: $pending, onUpgrade: requestUpgrade,
                                   onClose: { selection.removeAll() })
                    .frame(height: 230)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: tr("Filtrer les paquets installés"))
        .onAppear {
            // Option de lancement pour les tests : -selectPackage cask:nom (jamais enregistrée).
            if let id = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["selectPackage"] as? String {
                selection = [id]
            }
        }
        .modifier(PackageConfirmations(pending: $pending))
    }

    private func matches(_ p: BrewPackage) -> Bool {
        switch filter {
        case .all: break
        case .formulae: if p.kind != .formula { return false }
        case .casks: if p.kind != .cask { return false }
        case .inUse: if !p.inUse { return false }
        }
        if hideDependencies, p.kind == .formula, !p.onRequest, query.isEmpty, filter != .inUse { return false }
        if query.isEmpty { return true }
        return p.name.localizedCaseInsensitiveContains(query)
            || p.displayName.localizedCaseInsensitiveContains(query)
            || p.desc.localizedCaseInsensitiveContains(query)
    }

    private func requestUpgrade(_ p: BrewPackage) {
        if p.inUse { pending = PendingAction(kind: .upgradeInUse, package: p) }
        else { model.upgrade(.ids([p.id])) }
    }
}

/// Bouton « Mettre à jour » qui suit l'état du paquet dans la file.
struct UpgradeButton: View {
    @ObservedObject private var model = AppModel.shared
    let package: BrewPackage
    let action: () -> Void

    var body: some View {
        if model.activeIDs.contains(package.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("En cours…")).foregroundStyle(.secondary)
            }
        } else if model.queuedIDs.contains(package.id) {
            Label(tr("En attente…"), systemImage: "clock")
                .foregroundStyle(.secondary)
        } else {
            Button(tr("Mettre à jour"), action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(package.pinned)
        }
    }
}

struct NameCell: View {
    let package: BrewPackage

    var body: some View {
        HStack(spacing: 8) {
            package.icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(package.title).fontWeight(.medium)
                    if !package.displayName.isEmpty && package.displayName != package.name {
                        Text(package.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !package.desc.isEmpty {
                    Text(package.desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help(package.desc)
    }
}

/// Menu contextuel commun aux listes de paquets.
struct PackageMenu: View {
    @ObservedObject private var model = AppModel.shared
    let ids: Set<String>
    @Binding var pending: PendingAction?
    let onUpgrade: (BrewPackage) -> Void

    var body: some View {
        let selected = model.packages.filter { ids.contains($0.id) }
        if selected.count == 1, let p = selected.first {
            if p.outdated {
                Button(tr("Mettre à jour %@", p.name)) { onUpgrade(p) }.disabled(p.pinned)
            }
            if p.outdated || model.isIgnored(p) {
                Button(model.isIgnored(p) ? tr("Ne plus ignorer") : tr("Ignorer dans les mises à jour groupées")) {
                    model.setIgnored(p, !model.isIgnored(p))
                }
            }
            Divider()
            if let home = p.homepage, let url = URL(string: home) {
                Button(tr("Ouvrir la page du projet")) { NSWorkspace.shared.open(url) }
            }
            if let app = p.appPaths.first {
                Button(tr("Afficher dans le Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app)])
                }
            }
            Button(tr("Copier la commande brew upgrade")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew upgrade \(p.kind.flag) \(p.name)", forType: .string)
            }
            Divider()
            Button(tr("Désinstaller %@…", p.name), role: .destructive) {
                pending = PendingAction(kind: .uninstall, package: p)
            }
        } else if selected.count > 1 {
            let upgradable = selected.filter { $0.outdated && !$0.pinned }
            Button(tr("Mettre à jour %d paquets", upgradable.count)) {
                model.upgrade(.ids(Set(upgradable.map(\.id))))
            }
            .disabled(upgradable.isEmpty)
            Button(tr("Ignorer dans les mises à jour groupées")) {
                for p in selected { model.setIgnored(p, true) }
            }
            Button(tr("Ne plus ignorer")) {
                for p in selected { model.setIgnored(p, false) }
            }
        }
    }
}

struct PackageConfirmations: ViewModifier {
    @ObservedObject private var model = AppModel.shared
    @Binding var pending: PendingAction?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                presenting: pending) { action in
                switch action.kind {
                case .upgradeInUse:
                    let hasApp = !model.runningApps(for: action.package).isEmpty
                    if hasApp {
                        Button(tr("Fermer, mettre à jour et relancer")) { model.upgrade(.ids([action.package.id])) }
                    } else {
                        Button(action.package.serviceRunning && model.restartServices
                               ? tr("Mettre à jour et redémarrer le service") : tr("Mettre à jour quand même")) {
                            model.upgrade(.ids([action.package.id]))
                        }
                    }
                    Button(tr("Annuler"), role: .cancel) {}
                case .uninstall:
                    Button(tr("Désinstaller"), role: .destructive) { model.uninstall(action.package) }
                    if action.package.kind == .cask {
                        Button(tr("Désinstaller et effacer ses données (--zap)"), role: .destructive) {
                            model.uninstall(action.package, zap: true)
                        }
                    }
                    Button(tr("Annuler"), role: .cancel) {}
                }
            } message: { action in
                switch action.kind {
                case .upgradeInUse:
                    Text(tr("%@ est en cours d'utilisation (%@).", action.package.title, action.package.usageDescription))
                case .uninstall:
                    Text("brew uninstall \(action.package.kind.flag) \(action.package.name)")
                }
            }
    }

    private var title: String {
        guard let pending else { return "" }
        switch pending.kind {
        case .upgradeInUse: return tr("Mettre à jour %@ ?", pending.package.title)
        case .uninstall: return tr("Désinstaller %@ ?", pending.package.title)
        }
    }
}
