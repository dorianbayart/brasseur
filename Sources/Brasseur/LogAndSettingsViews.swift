import AppKit
import SwiftUI

struct LogView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("Journal des commandes brew")).font(.headline)
                Spacer()
                Button(tr("Diagnostic (brew doctor)")) { model.doctor() }
                    .help(tr("Vérifie l'installation de Homebrew et liste les problèmes éventuels"))
                    .disabled(model.currentTask == tr("Diagnostic (brew doctor)"))
                Button(tr("Copier")) {
                    let text = model.log.map { "[\($0.date.formatted(date: .omitted, time: .standard))] \($0.text)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button(tr("Effacer")) { model.clearLog() }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.log) { line in
                            LogRow(line: line).id(line.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear { if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: model.log.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.date.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
            Text(line.kind == .section ? "▶ " + line.text : line.text)
                .foregroundStyle(color)
                .fontWeight(line.kind == .section ? .semibold : .regular)
                .textSelection(.enabled)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.top, line.kind == .section ? 8 : 0)
    }

    private var color: Color {
        switch line.kind {
        case .section: return .primary
        case .output: return .secondary
        case .info: return .blue
        case .success: return .green
        case .error: return .orange
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Form {
            Section(tr("Vérification")) {
                Toggle(tr("Rechercher les mises à jour automatiquement"), isOn: $model.autoCheck)
                Picker(tr("Fréquence"), selection: $model.checkIntervalHours) {
                    Text(tr("Toutes les heures")).tag(1.0)
                    Text(tr("Toutes les 3 heures")).tag(3.0)
                    Text(tr("Toutes les 6 heures")).tag(6.0)
                    Text(tr("Toutes les 12 heures")).tag(12.0)
                    Text(tr("Une fois par jour")).tag(24.0)
                }
                .disabled(!model.autoCheck)
                Toggle(tr("Notifier les nouvelles mises à jour"), isOn: $model.notifyNewUpdates)
            }
            Section(tr("Mise à jour")) {
                Toggle(tr("Mettre à jour automatiquement les paquets non utilisés"), isOn: $model.autoUpgrade)
                Text(tr("Après chaque vérification, et dès qu'un paquet n'est plus utilisé. Sont exclus : les paquets utilisés, ignorés, épinglés, et ceux qui demandent le mot de passe administrateur. Un échec n'est retenté qu'au bout de 6 h."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("Fermer puis relancer les apps ouvertes"), isOn: $model.quitAndRelaunch)
                Text(tr("Sinon, une app ouverte est laissée de côté par « Tout mettre à jour »."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("Redémarrer les services brew mis à jour"), isOn: $model.restartServices)
            }
            Section(tr("Application")) {
                Toggle(tr("Afficher l'icône dans le Dock"), isOn: $model.showInDock)
                Toggle(tr("Ouvrir la fenêtre au lancement"), isOn: $model.openWindowAtLaunch)
                Toggle(tr("Lancer à l'ouverture de session"), isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
            Section(tr("Paquets ignorés")) {
                if model.ignored.isEmpty {
                    Text(tr("Aucun. Clic droit sur un paquet pour l'exclure des mises à jour groupées."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.ignored.sorted(), id: \.self) { id in
                        HStack {
                            Text(id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id)
                            Spacer()
                            Button(tr("Retirer")) { model.clearIgnored(id) }.controlSize(.small)
                        }
                    }
                }
            }
            if let runner = model.runner {
                Section(tr("Homebrew")) {
                    LabeledContent("brew", value: runner.brewPath)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 480)
    }
}
