import AppKit
import SwiftUI

struct SearchView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var error: String?
    @State private var selection: String?
    @State private var details: PackageDetails?
    @State private var loadingDetails = false
    @State private var summaries: [String: CaskSummary] = [:]

    var body: some View {
        // HStack plutôt que HSplitView : NSSplitView réclamait plus de largeur que la fenêtre n'en a
        // au minimum, ce qui décalait la barre latérale et coupait la barre d'état.
        GeometryReader { geo in
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(tr("Chercher une app ou une formule"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                    if searching { ProgressView().controlSize(.small) }
                }
                .padding(12)
                Divider()
                Group {
                    if let error {
                        EmptyState(title: tr("Recherche impossible"), systemImage: "exclamationmark.triangle",
                                   message: error)
                    } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
                        EmptyState(title: tr("Rechercher dans Homebrew"), systemImage: "magnifyingglass",
                                   message: tr("Par nom ou par description, au moins deux caractères."))
                    } else if results.isEmpty && !searching {
                        EmptyState(title: tr("Aucun résultat pour « %@ »", query), systemImage: "magnifyingglass",
                                   message: tr("Vérifiez l'orthographe ou essayez un autre mot."))
                    } else {
                        List(results, selection: $selection) { r in
                            SearchRow(result: r, installed: model.isInstalled(r.kind, r.name),
                                      appPath: model.installedPackage(r.kind, r.name)?.appPaths.first,
                                      homepage: summaries[r.id]?.homepage,
                                      fallbackDesc: summaries[r.id]?.desc ?? "")
                                .tag(r.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: min(max(geo.size.width * 0.45, 280), 480))
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            Group {
                if let result = results.first(where: { $0.id == selection }) {
                    DetailPane(result: result, details: details, loading: loadingDetails,
                               summary: summaries[result.id])
                } else {
                    EmptyState(title: tr("Aucune sélection"), systemImage: "shippingbox",
                               message: tr("Choisissez un paquet pour voir ses détails."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; error = nil; searching = false; return }
            searching = true   // pendant la courte attente aussi : pas de « Aucun résultat » prématuré
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let r = await model.search(q)
            guard !Task.isCancelled else { return }
            searching = false
            switch r {
            case .success(let list): results = rank(list, for: q); error = nil
            case .failure(let e): results = []; error = e.localizedDescription
            }
            // Site (pour l'icône), description et besoin du mot de passe des premiers résultats :
            // un appel pour les apps, un pour les formules.
            let missing = results.filter { summaries[$0.id] == nil }.prefix(60)
            async let casks = model.summaries(.cask, missing.filter { $0.kind == .cask }.map(\.name))
            async let formulae = model.summaries(.formula, missing.filter { $0.kind == .formula }.map(\.name))
            let found = await casks.merging(await formulae) { $1 }
            guard !Task.isCancelled else { return }
            summaries.merge(found) { $1 }
        }
        .task(id: selection) {
            details = nil
            guard let result = results.first(where: { $0.id == selection }) else { return }
            loadingDetails = true
            let d = await model.details(result.kind, result.name)
            guard !Task.isCancelled else { return }
            details = d
            loadingDetails = false
        }
    }

    /// Par pertinence (nom exact, puis nom qui commence par la recherche, puis nom qui la contient,
    /// puis description seule), et par ordre alphabétique dans chaque groupe.
    private func rank(_ list: [SearchResult], for q: String) -> [SearchResult] {
        let lower = q.lowercased()
        func score(_ r: SearchResult) -> Int {
            let n = r.name.lowercased(), d = r.displayName.lowercased()
            if n == lower || d == lower { return 0 }
            if n.hasPrefix(lower) || d.hasPrefix(lower) { return 1 }
            if n.contains(lower) || d.contains(lower) { return 2 }
            return 3
        }
        func title(_ r: SearchResult) -> String { r.displayName.isEmpty ? r.name : r.displayName }
        return list.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa < sb }
            let order = title(a).localizedStandardCompare(title(b))
            return order != .orderedSame ? order == .orderedAscending : a.kind.rawValue < b.kind.rawValue
        }
    }
}

struct SearchRow: View {
    let result: SearchResult
    let installed: Bool
    var appPath: String?
    var homepage: String?
    /// Description venue de `brew info` quand la recherche par nom n'en donne pas.
    var fallbackDesc = ""

    var body: some View {
        let desc = result.desc.isEmpty ? fallbackDesc : result.desc
        HStack(spacing: 8) {
            PackageIcon(kind: result.kind, appPath: appPath, homepage: homepage, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(result.displayName.isEmpty ? result.name : result.displayName).fontWeight(.medium)
                    if !result.displayName.isEmpty { Text(result.name).font(.caption).foregroundStyle(.secondary) }
                    if installed { Chip(text: tr("installé"), color: .green) }
                }
                if !desc.isEmpty {
                    Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct DetailPane: View {
    @ObservedObject private var model = AppModel.shared
    let result: SearchResult
    let details: PackageDetails?
    let loading: Bool
    var summary: CaskSummary?

    var body: some View {
        let installed = model.isInstalled(result.kind, result.name)
        let installing = model.currentTask == AppModel.installLabel(result.name) || model.pendingTasks.contains(AppModel.installLabel(result.name))
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    PackageIcon(kind: result.kind,
                                appPath: model.installedPackage(result.kind, result.name)?.appPaths.first,
                                homepage: details?.homepage ?? summary?.homepage, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.displayName.isEmpty ? result.name : result.displayName).font(.title.weight(.semibold))
                        Text("\(result.kind.label) · \(result.name)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installed {
                        Label(tr("Installé"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(installing ? tr("En file…") : tr("Installer")) { model.install(result.kind, result.name, needsAdmin: details?.needsAdmin ?? summary?.needsAdmin ?? false) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(installing || !model.isOnline || details?.disabled == true)
                    }
                }
                Text(details?.desc ?? (result.desc.isEmpty ? summary?.desc ?? "" : result.desc))

                if loading {
                    ProgressView().controlSize(.small)
                } else if let d = details {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow { Text(tr("Version")).foregroundStyle(.secondary); Text(d.version).monospacedDigit().textSelection(.enabled) }
                        if let home = d.homepage, let url = URL(string: home) {
                            GridRow { Text(tr("Site")).foregroundStyle(.secondary); Link(home, destination: url) }
                        }
                        if !d.dependencies.isEmpty {
                            GridRow {
                                Text(tr("Dépendances")).foregroundStyle(.secondary)
                                Text(d.dependencies.joined(separator: ", ")).textSelection(.enabled)
                            }
                        }
                        GridRow {
                            Text(tr("Commande")).foregroundStyle(.secondary)
                            Text("brew install \(result.kind.flag) \(result.name)").font(.body.monospaced()).textSelection(.enabled)
                        }
                    }
                    if d.needsAdmin {
                        Chip(text: tr("admin"), color: .red, help: tr("Demande le mot de passe administrateur : jamais mis à jour automatiquement"))
                    }
                    if let lifecycle = d.lifecycle { LifecycleNotice(lifecycle: lifecycle) }
                    if let caveats = d.caveats, !caveats.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("À savoir")).font(.headline)
                            Text(caveats).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                } else {
                    Text(tr("Détails indisponibles (hors ligne ?).")).foregroundStyle(.secondary)
                }
                if !model.isOnline {
                    Label(tr("Hors ligne : installation impossible pour le moment."), systemImage: "wifi.slash")
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// État vide qui se replie sur plusieurs lignes quand la place manque
/// (ContentUnavailableView garde son texte sur une ligne et élargit la fenêtre).
struct EmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}
