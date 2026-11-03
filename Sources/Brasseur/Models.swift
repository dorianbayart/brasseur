import Foundation

enum PackageKind: String, Hashable, Sendable {
    case formula, cask

    var label: String { self == .formula ? tr("Formule") : "Cask" }
    var flag: String { self == .formula ? "--formula" : "--cask" }
}

/// Un paquet installé, tel que brew le décrit, enrichi de son état d'utilisation.
struct BrewPackage: Identifiable, Hashable, Sendable {
    var id: String { Self.makeID(kind, name) }
    static func makeID(_ kind: PackageKind, _ name: String) -> String { "\(kind.rawValue):\(name)" }

    let kind: PackageKind
    let name: String
    let displayName: String
    let desc: String
    let homepage: String?
    let installedVersion: String
    var latestVersion: String
    var outdated: Bool
    /// En retard seulement si l'on inclut les casks qui se mettent à jour seuls (`--greedy`).
    var greedyOnly: Bool
    let pinned: Bool
    /// Formule installée à la main (pas seulement comme dépendance).
    let onRequest: Bool
    let autoUpdates: Bool
    /// brew demandera le mot de passe administrateur (installeur .pkg, désinstallation système,
    /// ou échec déjà constaté faute de mot de passe).
    var needsAdmin: Bool
    let deprecated: Bool
    /// Chemins des .app installés par le cask (ex. /Applications/Firefox.app).
    let appPaths: [String]
    var serviceStatus: String?
    var serviceUser: String?
    /// Dépendances d'exécution d'une formule (noms complets).
    var runtimeDeps: [String] = []
    /// Exécutables en cours d'exécution qui appartiennent à ce paquet.
    var runningProcesses: [String] = []
    /// Taille sur disque (nil tant qu'elle n'est pas calculée, ou inconnue pour un installeur .pkg).
    var size: Int64? = nil

    var sizeForSort: Int64 { size ?? -1 }
    var kindLabel: String { kind.label }

    var serviceRunning: Bool { serviceStatus == "started" }
    var inUse: Bool { !runningProcesses.isEmpty || serviceRunning }
    var title: String { displayName.isEmpty ? name : displayName }

    var usageDescription: String {
        var parts: [String] = []
        if serviceRunning { parts.append(tr("service brew démarré")) }
        if !runningProcesses.isEmpty { parts.append(tr("en cours : %@", runningProcesses.joined(separator: ", "))) }
        return parts.joined(separator: " · ")
    }
}

struct SearchResult: Identifiable, Hashable, Sendable {
    var id: String { BrewPackage.makeID(kind, name) }
    let kind: PackageKind
    let name: String
    let displayName: String
    let desc: String
}

struct PackageDetails: Sendable {
    let kind: PackageKind
    let name: String
    let displayName: String
    let desc: String
    let version: String
    let homepage: String?
    let caveats: String?
    let dependencies: [String]
    let deprecated: Bool
    let disabled: Bool
    let autoUpdates: Bool
    var needsAdmin = false
    var lifecycle: Lifecycle? = nil
}

/// Ce qu'il faut savoir d'un paquet trouvé par la recherche, pour l'afficher (icône, description) et l'installer.
struct CaskSummary: Sendable {
    let homepage: String?
    let needsAdmin: Bool
    var desc = ""
}

struct LogLine: Identifiable, Sendable {
    enum Kind: Sendable { case section, output, info, success, error }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
}
