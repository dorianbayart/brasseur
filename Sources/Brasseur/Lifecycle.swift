import SwiftUI

/// Paquet déprécié ou désactivé par les mainteneurs de Homebrew : quand, pourquoi, et par quoi le remplacer.
struct Lifecycle: Sendable, Hashable {
    /// Désactivé : `brew install` le refuse. Sinon déprécié : encore installable, avec un avertissement.
    let disabled: Bool
    /// Date de la dépréciation, ou de la désactivation (passée ou prévue).
    let date: Date?
    /// Désactivation prévue d'un paquet seulement déprécié.
    let plannedDisableDate: Date?
    /// Code Homebrew (`unmaintained`…) ou texte libre écrit par les mainteneurs.
    let reason: String?
    /// Paquet conseillé à la place, au format `brew install` (« --formula python@3.13 »).
    let replacement: String?

    static func make(deprecated: Bool?, disabled: Bool?,
                     deprecationDate: String?, deprecationReason: String?,
                     deprecationFormula: String?, deprecationCask: String?,
                     disableDate: String?, disableReason: String?,
                     disableFormula: String?, disableCask: String?) -> Lifecycle? {
        let isDisabled = disabled ?? false
        guard isDisabled || deprecated == true else { return nil }
        if isDisabled {
            return Lifecycle(disabled: true, date: parse(disableDate), plannedDisableDate: nil,
                             reason: disableReason ?? deprecationReason,
                             replacement: replacement(disableFormula ?? deprecationFormula, disableCask ?? deprecationCask))
        }
        return Lifecycle(disabled: false, date: parse(deprecationDate), plannedDisableDate: parse(disableDate),
                         reason: deprecationReason,
                         replacement: replacement(deprecationFormula, deprecationCask))
    }

    private static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(text.prefix(10)))
    }

    private static func replacement(_ formula: String?, _ cask: String?) -> String? {
        if let formula, formula == cask { return formula }
        if let formula { return "--formula \(formula)" }
        if let cask { return "--cask \(cask)" }
        return nil
    }

    /// Titre court : « Désactivé dans Homebrew depuis le 15 octobre 2026 ».
    var title: String {
        let base = disabled ? tr("Désactivé dans Homebrew") : tr("Déprécié dans Homebrew")
        guard let date else { return base }
        if date > Date() { return base + " " + tr("à partir du %@", Self.format(date)) }
        return base + " " + tr("depuis le %@", Self.format(date))
    }

    /// Pourquoi, en clair. Les codes connus sont traduits ; un texte libre est repris tel quel.
    var reasonText: String? {
        guard let reason, !reason.isEmpty else { return nil }
        if let known = Self.reasons[reason] { return tr(known) }
        return reason.replacingOccurrences(of: "_", with: " ")
    }

    /// Ce que ça change pour l'utilisateur.
    var consequence: String {
        if disabled {
            return tr("Il ne peut plus être installé. Une copie déjà installée continue de fonctionner, mais ne reçoit plus de mises à jour.")
        }
        if let plannedDisableDate {
            return tr("Il s'installe encore, avec un avertissement, et sera désactivé le %@.", Self.format(plannedDisableDate))
        }
        return tr("Il s'installe encore, avec un avertissement, mais sera désactivé plus tard.")
    }

    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// Codes de Homebrew (deprecate_disable.rb) : formules puis casks.
    private static let reasons: [String: String] = [
        "does_not_build": "il ne se compile plus.",
        "no_license": "il n'a pas de licence.",
        "repo_archived": "le dépôt de ses développeurs a été archivé : le projet est à l'arrêt.",
        "repo_removed": "le dépôt de ses développeurs a été supprimé.",
        "unmaintained": "ses développeurs ne le maintiennent plus.",
        "unreachable": "son site de téléchargement n'est plus joignable de façon fiable.",
        "unsupported": "ses développeurs ne le prennent plus en charge.",
        "deprecated_upstream": "ses développeurs l'ont eux-mêmes abandonné (fin de vie).",
        "versioned_formula": "c'est une ancienne version, remplacée par une plus récente.",
        "checksum_mismatch": "le fichier source publié a été modifié après sa sortie.",
        "discontinued": "l'éditeur a arrêté l'app.",
        "moved_to_mas": "l'app n'est plus distribuée que sur le Mac App Store.",
        "no_longer_available": "l'éditeur ne la propose plus au téléchargement.",
        "no_longer_meets_criteria": "elle ne respecte plus les critères d'acceptation de Homebrew.",
        "fails_gatekeeper_check": "elle ne passe pas la vérification Gatekeeper de macOS.",
    ]
}

/// Encadré expliquant une dépréciation ou une désactivation.
struct LifecycleNotice: View {
    let lifecycle: Lifecycle

    var body: some View {
        let tint: Color = lifecycle.disabled ? .red : .orange
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: lifecycle.disabled ? "nosign" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(lifecycle.title).fontWeight(.semibold)
                if let reason = lifecycle.reasonText {
                    Text(tr("Raison : %@", reason))
                }
                Text(lifecycle.consequence).foregroundStyle(.secondary)
                if let replacement = lifecycle.replacement {
                    Text(tr("Homebrew conseille à la place : %@", "brew install \(replacement)"))
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.10)))
    }
}
