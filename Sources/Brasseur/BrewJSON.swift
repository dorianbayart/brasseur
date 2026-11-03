import Foundation

// Décodage des sorties JSON de brew (`info --json=v2`, `outdated --json=v2`, `services list --json`).

struct InfoJSON: Decodable {
    let formulae: [FormulaJSON]?
    let casks: [CaskJSON]?
}

struct FormulaJSON: Decodable {
    struct Versions: Decodable { let stable: String? }
    struct Installed: Decodable {
        struct Dep: Decodable { let full_name: String }
        let version: String
        let installed_on_request: Bool?
        let runtime_dependencies: [Dep]?
    }
    let name: String
    let full_name: String?
    let desc: String?
    let homepage: String?
    let outdated: Bool?
    let pinned: Bool?
    let deprecated: Bool?
    let disabled: Bool?
    let deprecation_date: String?
    let deprecation_reason: String?
    let deprecation_replacement_formula: String?
    let deprecation_replacement_cask: String?
    let disable_date: String?
    let disable_reason: String?
    let disable_replacement_formula: String?
    let disable_replacement_cask: String?
    let caveats: String?
    let dependencies: [String]?
    let versions: Versions?
    let installed: [Installed]?
}

struct CaskJSON: Decodable {
    let token: String
    let name: [String]?
    let desc: String?
    let homepage: String?
    let installed: String?
    let version: String?
    let outdated: Bool?
    let auto_updates: Bool?
    let deprecated: Bool?
    let disabled: Bool?
    let deprecation_date: String?
    let deprecation_reason: String?
    let deprecation_replacement_formula: String?
    let deprecation_replacement_cask: String?
    let disable_date: String?
    let disable_reason: String?
    let disable_replacement_formula: String?
    let disable_replacement_cask: String?
    let caveats: String?
    let artifacts: [ArtifactJSON]?
}

/// Valeur JSON quelconque, pour lire les directives `uninstall` des casks.
enum JSONValue: Decodable {
    case string(String), array([JSONValue]), object([String: JSONValue]), other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .other }
    }

    var strings: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let a): return a.flatMap(\.strings)
        case .object(let o): return o.values.flatMap(\.strings)
        case .other: return []
        }
    }
}

/// Les artefacts d'un cask sont hétérogènes ; on n'en garde que ce qui nous sert.
struct ArtifactJSON: Decodable {
    var appTarget: String?
    /// brew passera par sudo : installeur .pkg, ou désinstallation (exécutée à chaque mise à jour)
    /// qui touche au système (services launchd, reçus pkgutil, extensions noyau, fichiers hors du dossier personnel).
    var needsAdmin = false

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Key.self) else { return }
        let keys = Set(c.allKeys.map(\.stringValue))
        if keys.contains("app") || keys.contains("suite"), let k = Key(stringValue: "target") {
            appTarget = try? c.decode(String.self, forKey: k)
        }
        needsAdmin = keys.contains("pkg") || keys.contains("installer")
        if keys.contains("uninstall"), let k = Key(stringValue: "uninstall"),
           let directives = try? c.decode([[String: JSONValue]].self, forKey: k) {
            let systemKeys: Set<String> = ["pkgutil", "kext", "launchctl", "script", "early_script"]
            for directive in directives {
                if !systemKeys.isDisjoint(with: directive.keys) { needsAdmin = true }
                if let deleted = directive["delete"]?.strings, deleted.contains(where: { $0.hasPrefix("/") }) {
                    needsAdmin = true
                }
            }
        }
    }
}

struct OutdatedJSON: Decodable {
    struct Item: Decodable {
        let name: String
        let current_version: String?
    }
    let formulae: [Item]?
    let casks: [Item]?
}

struct ServiceJSON: Decodable {
    let name: String
    let status: String?
    let user: String?
}

enum BrewParser {
    static func packages(info: Data, outdated: Data?, services: Data?) throws -> [BrewPackage] {
        let decoder = JSONDecoder()
        let infoRoot = try decoder.decode(InfoJSON.self, from: info)
        let outdatedRoot = outdated.flatMap { try? decoder.decode(OutdatedJSON.self, from: $0) }
        let serviceList = services.flatMap { try? decoder.decode([ServiceJSON].self, from: $0) } ?? []

        var greedyFormulae: [String: String] = [:]
        for item in outdatedRoot?.formulae ?? [] { greedyFormulae[item.name] = item.current_version ?? "" }
        var greedyCasks: [String: String] = [:]
        for item in outdatedRoot?.casks ?? [] { greedyCasks[item.name] = item.current_version ?? "" }
        var servicesByName: [String: ServiceJSON] = [:]
        for s in serviceList { servicesByName[s.name] = s }

        var result: [BrewPackage] = []
        for f in infoRoot.formulae ?? [] {
            guard let installed = f.installed?.last else { continue }
            let latest = greedyFormulae[f.name] ?? f.versions?.stable ?? installed.version
            let isOutdated = (f.outdated ?? false) || greedyFormulae[f.name] != nil
            let service = servicesByName[f.name]
            result.append(BrewPackage(
                kind: .formula, name: f.name, displayName: "", desc: f.desc ?? "",
                homepage: f.homepage, installedVersion: installed.version, latestVersion: latest,
                outdated: isOutdated, greedyOnly: false, pinned: f.pinned ?? false,
                onRequest: f.installed?.contains { $0.installed_on_request == true } ?? true,
                autoUpdates: false, needsAdmin: false, deprecated: (f.deprecated ?? false) || (f.disabled ?? false),
                appPaths: [], serviceStatus: service?.status, serviceUser: service?.user,
                runtimeDeps: installed.runtime_dependencies?.map(\.full_name) ?? []))
        }
        for c in infoRoot.casks ?? [] {
            guard let installed = c.installed else { continue }
            let normalOutdated = c.outdated ?? false
            let greedyLatest = greedyCasks[c.token]
            let artifacts = c.artifacts ?? []
            result.append(BrewPackage(
                kind: .cask, name: c.token, displayName: c.name?.first ?? "", desc: c.desc ?? "",
                homepage: c.homepage, installedVersion: installed,
                latestVersion: greedyLatest ?? c.version ?? installed,
                outdated: normalOutdated || greedyLatest != nil,
                greedyOnly: !normalOutdated && greedyLatest != nil,
                pinned: false, onRequest: true, autoUpdates: c.auto_updates ?? false,
                needsAdmin: artifacts.contains { $0.needsAdmin },
                deprecated: (c.deprecated ?? false) || (c.disabled ?? false),
                appPaths: artifacts.compactMap(\.appTarget), serviceStatus: nil, serviceUser: nil))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func details(_ data: Data, kind: PackageKind) -> PackageDetails? {
        guard let root = try? JSONDecoder().decode(InfoJSON.self, from: data) else { return nil }
        switch kind {
        case .formula:
            guard let f = root.formulae?.first else { return nil }
            return PackageDetails(kind: .formula, name: f.name, displayName: "", desc: f.desc ?? "",
                                  version: f.versions?.stable ?? "?", homepage: f.homepage, caveats: f.caveats,
                                  dependencies: f.dependencies ?? [], deprecated: f.deprecated ?? false,
                                  disabled: f.disabled ?? false, autoUpdates: false,
                                  lifecycle: Lifecycle.make(
                                      deprecated: f.deprecated, disabled: f.disabled,
                                      deprecationDate: f.deprecation_date, deprecationReason: f.deprecation_reason,
                                      deprecationFormula: f.deprecation_replacement_formula,
                                      deprecationCask: f.deprecation_replacement_cask,
                                      disableDate: f.disable_date, disableReason: f.disable_reason,
                                      disableFormula: f.disable_replacement_formula,
                                      disableCask: f.disable_replacement_cask))
        case .cask:
            guard let c = root.casks?.first else { return nil }
            return PackageDetails(kind: .cask, name: c.token, displayName: c.name?.first ?? "", desc: c.desc ?? "",
                                  version: c.version ?? "?", homepage: c.homepage, caveats: c.caveats,
                                  dependencies: [], deprecated: c.deprecated ?? false,
                                  disabled: c.disabled ?? false, autoUpdates: c.auto_updates ?? false,
                                  needsAdmin: (c.artifacts ?? []).contains { $0.needsAdmin },
                                  lifecycle: Lifecycle.make(
                                      deprecated: c.deprecated, disabled: c.disabled,
                                      deprecationDate: c.deprecation_date, deprecationReason: c.deprecation_reason,
                                      deprecationFormula: c.deprecation_replacement_formula,
                                      deprecationCask: c.deprecation_replacement_cask,
                                      disableDate: c.disable_date, disableReason: c.disable_reason,
                                      disableFormula: c.disable_replacement_formula,
                                      disableCask: c.disable_replacement_cask))
        }
    }

    static func summaries(_ data: Data) -> [String: CaskSummary] {
        guard let root = try? JSONDecoder().decode(InfoJSON.self, from: data) else { return [:] }
        var result: [String: CaskSummary] = [:]
        for f in root.formulae ?? [] {
            result[BrewPackage.makeID(.formula, f.name)] = CaskSummary(homepage: f.homepage, needsAdmin: false,
                                                                       desc: f.desc ?? "")
        }
        for c in root.casks ?? [] {
            result[BrewPackage.makeID(.cask, c.token)] = CaskSummary(
                homepage: c.homepage, needsAdmin: (c.artifacts ?? []).contains { $0.needsAdmin }, desc: c.desc ?? "")
        }
        return result
    }

    /// Analyse la sortie texte de `brew search --desc` :
    ///   ==> Formulae
    ///   htop: Improved top (interactive process viewer)
    ///   ==> Casks
    ///   arc: (Arc) Chromium based browser
    /// - Parameter defaultKind: type des lignes sans titre « ==> Formulae / Casks »
    ///   (hors terminal, `brew search --formula` n'en affiche pas).
    static func searchResults(_ output: String, defaultKind: PackageKind? = nil) -> [SearchResult] {
        var kind: PackageKind? = defaultKind
        var results: [SearchResult] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") {
                kind = line.contains("Cask") ? .cask : (line.contains("Formula") || line.contains("Formulae") ? .formula : nil)
                continue
            }
            guard let kind, !line.isEmpty else { continue }
            let name: String
            var rest: String
            if let colon = line.range(of: ": ") {
                name = String(line[..<colon.lowerBound])
                rest = String(line[colon.upperBound...])
            } else {
                name = line.hasSuffix(":") ? String(line.dropLast()) : line
                rest = ""
            }
            guard !name.contains(" ") else { continue }
            var display = ""
            if kind == .cask, rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
                display = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            }
            results.append(SearchResult(kind: kind, name: name, displayName: display, desc: rest))
        }
        return results
    }
}
