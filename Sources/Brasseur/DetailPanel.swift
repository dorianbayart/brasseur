import AppKit
import SwiftUI

/// Panneau du bas : tout ce qu'il faut savoir d'un paquet installé, et les actions.
struct PackageDetailPanel: View {
    @ObservedObject private var model = AppModel.shared
    let package: BrewPackage
    @Binding var pending: PendingAction?
    let onUpgrade: (BrewPackage) -> Void
    let onClose: () -> Void
    @State private var details: PackageDetails?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PackageIcon(kind: package.kind, appPath: package.appPaths.first, homepage: package.homepage, size: 56)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(package.title).font(.title3.weight(.semibold))
                        if package.title != package.name {
                            Text(package.name).foregroundStyle(.secondary)
                        }
                        Text(package.kind.label).font(.caption).foregroundStyle(.secondary)
                        StatusBadges(package: package)
                    }
                    if !package.desc.isEmpty { Text(package.desc) }
                    if let lifecycle = details?.lifecycle { LifecycleNotice(lifecycle: lifecycle) }

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        row(tr("Version installée"), package.installedVersion, monospaced: true)
                        if package.outdated { row(tr("Disponible"), package.latestVersion, monospaced: true) }
                        row(tr("Taille"), package.size == nil ? tr("calcul…") : package.formattedSize)
                        if let location {
                            GridRow {
                                label(tr("Emplacement"))
                                HStack(spacing: 6) {
                                    Text(location).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location)])
                                    } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless)
                                    .help(tr("Afficher dans le Finder"))
                                }
                            }
                        }
                        if let home = package.homepage, let url = URL(string: home) {
                            GridRow { label(tr("Site")); Link(home, destination: url) }
                        }
                        if package.inUse { row(tr("Utilisé par"), package.usageDescription) }
                        let deps = details?.dependencies ?? []
                        if !deps.isEmpty { row(tr("Dépendances"), deps.joined(separator: ", ")) }
                    }
                    if let caveats = details?.caveats, !caveats.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr("À savoir")).font(.headline)
                            Text(caveats).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .trailing, spacing: 8) {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tr("Fermer"))
                if package.outdated {
                    UpgradeButton(package: package) { onUpgrade(package) }
                }
                if package.outdated || model.isIgnored(package) {
                    Button(model.isIgnored(package) ? tr("Ne plus ignorer") : tr("Ignorer")) {
                        model.setIgnored(package, !model.isIgnored(package))
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button(tr("Désinstaller…"), role: .destructive) {
                    pending = PendingAction(kind: .uninstall, package: package)
                }
                .controlSize(.small)
            }
            .frame(minWidth: 130, alignment: .trailing)
        }
        .padding(14)
        .background(.background.secondary)
        .task(id: package.id) {
            details = nil
            details = await model.details(package.kind, package.name)
        }
    }

    private var location: String? {
        if let app = package.appPaths.first { return app }
        guard let prefix = model.runner?.prefix else { return nil }
        let folder = package.kind == .formula ? "Cellar" : "Caskroom"
        return "\(prefix)/\(folder)/\(package.name)/\(package.installedVersion)"
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            label(title)
            Text(value)
                .font(monospaced ? .body.monospacedDigit() : .body)
                .textSelection(.enabled)
        }
    }
}
