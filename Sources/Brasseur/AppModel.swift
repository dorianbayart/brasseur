import AppKit
import Combine
import Foundation
import Network
import ServiceManagement
import UserNotifications

/// État de l'application et toutes les opérations brew.
/// Les opérations qui modifient brew passent par une file : une seule à la fois, dans l'ordre demandé.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let runner: BrewRunner?

    @Published private(set) var packages: [BrewPackage] = []
    @Published private(set) var loaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var isOnline = true
    @Published private(set) var currentTask: String?
    @Published private(set) var pendingTasks: [String] = []
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastCheckError: String?
    @Published var lastOperationError: String?
    /// Paquets en cours de mise à jour, et ceux qui attendent leur tour dans la file.
    @Published private(set) var activeIDs = Set<String>()
    @Published private(set) var queuedIDs = Set<String>()

    // MARK: Réglages (persistés)

    @Published var checkIntervalHours: Double { didSet { defaults.set(checkIntervalHours, forKey: Keys.interval) } }
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: Keys.autoCheck) } }
    @Published var restartServices: Bool { didSet { defaults.set(restartServices, forKey: Keys.restartServices) } }
    @Published var autoUpgrade: Bool {
        didSet { defaults.set(autoUpgrade, forKey: Keys.autoUpgrade); if autoUpgrade { maybeAutoUpgrade() } }
    }
    @Published var quitAndRelaunch: Bool { didSet { defaults.set(quitAndRelaunch, forKey: Keys.quitRelaunch) } }
    @Published var notifyNewUpdates: Bool {
        didSet {
            defaults.set(notifyNewUpdates, forKey: Keys.notify)
            if notifyNewUpdates { requestNotificationPermission() }
        }
    }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: Keys.dock); applyDockPolicy() } }
    @Published var openWindowAtLaunch: Bool { didSet { defaults.set(openWindowAtLaunch, forKey: Keys.openAtLaunch) } }
    @Published private(set) var ignored: Set<String> {
        didSet { defaults.set(Array(ignored), forKey: Keys.ignored); updateBadge() }
    }

    static let checkLabel = tr("Recherche de mises à jour (brew update)")
    static func installLabel(_ name: String) -> String { tr("Installation de %@", name) }

    /// Texte de la demande de mot de passe : quelle(s) app(s), et de quelle version vers laquelle.
    static func upgradeDescription(_ p: BrewPackage) -> String {
        tr("Mise à jour de %@", p.title) + "\n" + "\(p.installedVersion) → \(p.latestVersion)"
    }

    static func upgradeDescription(_ list: [BrewPackage]) -> String {
        list.count == 1 ? upgradeDescription(list[0]) : tr("Mise à jour de %@", list.map(\.title).joined(separator: ", "))
    }

    private enum Keys {
        static let interval = "checkIntervalHours", autoCheck = "autoCheck", learnedAdmin = "learnedAdmin"
        static let restartServices = "restartServices", quitRelaunch = "quitAndRelaunch", notify = "notifyNewUpdates"
        static let autoUpgrade = "autoUpgrade", lastCleanup = "lastCleanup"
        static let dock = "showInDock", openAtLaunch = "openWindowAtLaunch", ignored = "ignored", lastCheck = "lastCheck"
    }

    private let defaults = UserDefaults.standard
    private var queueTail: Task<Void, Never>?
    private var generation = 0
    private var lastAttempt: Date?
    private var lastAttemptFailed = false
    private var checkQueued = false
    private var lastAutoRun: Date?
    private var lastSpotlightWarning: Date?
    /// Casks qui ont échoué faute de mot de passe : traités comme « admin » ensuite.
    private var learnedAdmin: Set<String> {
        didSet { defaults.set(Array(learnedAdmin), forKey: Keys.learnedAdmin) }
    }
    /// Échecs récents de la mise à jour automatique : on ne réessaie pas avant 6 h.
    private var autoFailures: [String: Date] = [:]
    private var started = false
    private var pathMonitor: NWPathMonitor?
    private var timers: [Timer] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        runner = BrewRunner()
        runner?.onSpotlightStall = { Task { @MainActor in AppModel.shared.spotlightStalled() } }
        defaults.register(defaults: [
            Keys.interval: 3.0, Keys.autoCheck: true, Keys.restartServices: true,
            Keys.quitRelaunch: true, Keys.notify: false, Keys.autoUpgrade: true, Keys.dock: true, Keys.openAtLaunch: true,
        ])
        learnedAdmin = Set(defaults.stringArray(forKey: Keys.learnedAdmin) ?? [])
        checkIntervalHours = defaults.double(forKey: Keys.interval)
        autoCheck = defaults.bool(forKey: Keys.autoCheck)
        restartServices = defaults.bool(forKey: Keys.restartServices)
        autoUpgrade = defaults.bool(forKey: Keys.autoUpgrade)
        quitAndRelaunch = defaults.bool(forKey: Keys.quitRelaunch)
        notifyNewUpdates = defaults.bool(forKey: Keys.notify)
        showInDock = defaults.bool(forKey: Keys.dock)
        openWindowAtLaunch = defaults.bool(forKey: Keys.openAtLaunch)
        ignored = Set(defaults.stringArray(forKey: Keys.ignored) ?? [])
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
    }

    // MARK: Données dérivées

    var outdatedPackages: [BrewPackage] {
        packages.filter(\.outdated)
    }

    /// Paquets concernés par les mises à jour groupées (ni ignorés, ni épinglés).
    var pendingPackages: [BrewPackage] {
        outdatedPackages.filter { !ignored.contains($0.id) && !$0.pinned }
    }

    var pendingCount: Int { pendingPackages.count }

    /// Ce que la mise à jour automatique peut traiter sans risque : rien d'utilisé,
    /// rien qui demande le mot de passe administrateur, rien qui a échoué récemment.
    var autoEligiblePackages: [BrewPackage] {
        let now = Date()
        return pendingPackages.filter { p in
            guard !p.inUse, !p.needsAdmin else { return false }
            if let failed = autoFailures[p.id], now.timeIntervalSince(failed) < 6 * 3600 { return false }
            return true
        }
    }
    var isBusy: Bool { currentTask != nil || !pendingTasks.isEmpty }

    func isIgnored(_ p: BrewPackage) -> Bool { ignored.contains(p.id) }
    func installedPackage(_ kind: PackageKind, _ name: String) -> BrewPackage? {
        packages.first { $0.kind == kind && $0.name == name }
    }

    func isInstalled(_ kind: PackageKind, _ name: String) -> Bool {
        packages.contains { $0.kind == kind && $0.name == name }
    }

    // MARK: Démarrage et planification

    func start() {
        guard !started else { return }
        started = true
        applyDockPolicy()
        guard runner != nil else {
            loadError = tr("Homebrew est introuvable (ni /opt/homebrew/bin/brew ni /usr/local/bin/brew).")
            return
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "brasseur.network"))
        pathMonitor = monitor

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))   // laisser le réseau revenir après la veille
                self?.scheduleTick()
            }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshUsage() }
            })
        }

        // Tolérance large : macOS regroupe ces réveils avec d'autres, moins de sorties de veille du processeur.
        let tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleTick()
                self?.maybeAutoCleanup()
            }
        }
        tick.tolerance = 20
        let usage = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUsage() }
        }
        usage.tolerance = 5
        timers += [tick, usage]

        // Chargement immédiat depuis l'état local de brew, puis vérification réseau si elle est due.
        enqueue(tr("Lecture des paquets installés")) { await self.reload() }
        scheduleTick()
    }

    private func networkChanged(online: Bool) {
        guard online != isOnline else { return }
        let cameBack = online && !isOnline
        isOnline = online
        appendLog(online ? .info : .error, online ? tr("Réseau disponible.") : tr("Réseau indisponible : vérifications en pause."))
        if cameBack {
            Task {
                try? await Task.sleep(for: .seconds(5))
                self.scheduleTick()
            }
        }
    }

    /// Lance `brew update` quand c'est dû : intervalle normal, ou 15 min après un échec.
    func scheduleTick() {
        guard autoCheck, runner != nil, isOnline, !checkQueued else { return }
        let interval = max(checkIntervalHours, 0.25) * 3600
        let due: Date
        if lastAttemptFailed, let lastAttempt {
            due = lastAttempt.addingTimeInterval(min(interval, 15 * 60))
        } else {
            due = (lastCheck ?? .distantPast).addingTimeInterval(interval)
        }
        if Date() >= due { checkForUpdates(automatic: true) }
        maybeAutoUpgrade()
    }

    /// brew cleanup tous les 7 jours, en tâche de fond, quand rien d'autre ne tourne.
    func maybeAutoCleanup() {
        guard runner != nil, loaded, !isBusy else { return }
        if let last = defaults.object(forKey: Keys.lastCleanup) as? Date,
           Date().timeIntervalSince(last) < 7 * 24 * 3600 { return }
        // Noté avant de lancer : un échec n'est retenté que la semaine suivante.
        defaults.set(Date(), forKey: Keys.lastCleanup)
        cleanup(automatic: true)
    }

    /// Les formules qui tournent, et leurs dépendances, gardent leur ancienne version sur disque
    /// (upgrade et cleanup ne les suppriment pas).
    private func inUseCleanupProtection() -> [String: String] {
        let running = packages.filter { $0.kind == .formula && $0.inUse }
        let protected = Set(running.map(\.name) + running.flatMap(\.runtimeDeps))
        return protected.isEmpty ? [:] : ["HOMEBREW_NO_CLEANUP_FORMULAE": protected.sorted().joined(separator: ",")]
    }

    /// Spotlight bloqué (souvent un partage réseau injoignable) : brew a été débloqué, on prévient
    /// une fois par heure au plus.
    func spotlightStalled() {
        if let lastSpotlightWarning, Date().timeIntervalSince(lastSpotlightWarning) < 3600 { return }
        lastSpotlightWarning = Date()
        let mounts = ProcessScanner.networkMounts()
        let message = mounts.isEmpty
            ? tr("Spotlight ne répond pas : brew a continué sans l'attendre.")
            : tr("Spotlight ne répond pas, sans doute à cause d'un partage réseau injoignable (%@) : brew a continué sans l'attendre. Démontez le partage bloqué pour que Spotlight et le Finder répondent à nouveau.", mounts.joined(separator: ", "))
        fail(message)
    }

    /// Lance la mise à jour automatique quand la file est libre et qu'il y a de quoi faire.
    func maybeAutoUpgrade() {
        guard autoUpgrade, runner != nil, loaded, isOnline, !isBusy else { return }
        if let lastAutoRun, Date().timeIntervalSince(lastAutoRun) < 120 { return }
        guard !autoEligiblePackages.isEmpty else { return }
        lastAutoRun = Date()
        upgrade(.automatic)
    }

    func checkForUpdates(automatic: Bool = false) {
        guard !checkQueued else { return }
        checkQueued = true
        enqueue(Self.checkLabel) {
            await self.performCheck(automatic: automatic)
            self.checkQueued = false
        }
    }

    private func performCheck(automatic: Bool) async {
        guard let runner else { return }
        lastAttempt = Date()
        let before = Set(pendingPackages.map(\.id))
        if !isOnline {
            lastAttemptFailed = true
            lastCheckError = tr("Hors ligne")
            appendLog(.error, tr("Pas de réseau : brew update reporté."))
        } else {
            let result = await runner.run(["update"], timeout: 300, cancellable: true,
                                         priority: automatic ? .background : .utility, onLine: logSink)
            if result.ok {
                lastAttemptFailed = false
                lastCheckError = nil
                lastCheck = Date()
                defaults.set(lastCheck, forKey: Keys.lastCheck)
            } else {
                lastAttemptFailed = true
                lastCheckError = result.failureSummary
                appendLog(.error, tr("brew update a échoué : %@. Nouvel essai dans 15 min.", result.failureSummary))
            }
        }
        await reload(priority: automatic ? .background : .utility)
        if automatic, notifyNewUpdates {
            let fresh = pendingPackages.filter { !before.contains($0.id) }
            if !fresh.isEmpty { notify(fresh) }
        }
    }

    // MARK: Chargement

    func reload(priority: BrewRunner.Priority = .utility) async {
        guard let runner else { return }
        async let info = runner.run(["info", "--json=v2", "--installed"], timeout: 180, priority: priority)
        async let outdated = runner.run(["outdated", "--json=v2", "--greedy"], timeout: 180, priority: priority)
        async let services = runner.run(["services", "list", "--json"], timeout: 60, priority: priority)
        let (i, o, s) = await (info, outdated, services)
        guard i.ok else {
            loadError = tr("Impossible de lire les paquets : %@", i.failureSummary)
            appendLog(.error, loadError!)
            return
        }
        let infoData = i.stdout
        let outdatedData = o.ok || !o.stdout.isEmpty ? o.stdout : nil
        let servicesData = s.ok ? s.stdout : nil
        let parsed = await Task.detached {
            Result { try BrewParser.packages(info: infoData, outdated: outdatedData, services: servicesData) }
        }.value
        switch parsed {
        case .success(var list):
            let usage = ProcessScanner.usage(for: list, prefix: runner.prefix)
            let previous = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for idx in list.indices {
                list[idx].runningProcesses = usage[list[idx].id] ?? []
                if learnedAdmin.contains(list[idx].id) { list[idx].needsAdmin = true }
                // Taille déjà connue pour la même version : on la garde.
                if let old = previous[list[idx].id], old.installedVersion == list[idx].installedVersion {
                    list[idx].size = old.size
                }
            }
            packages = list
            computeMissingSizes()
            loaded = true
            loadError = nil
            updateBadge()
        case .failure(let error):
            loadError = tr("Réponse de brew illisible : %@", error.localizedDescription)
            appendLog(.error, loadError!)
        }
    }

    // MARK: Tailles sur disque

    private var sizeTask: Task<Void, Never>?

    /// Calcule en arrière-plan les tailles manquantes et les publie par petits lots.
    private func computeMissingSizes() {
        guard let runner else { return }
        let cellar = runner.prefix + "/Cellar/"
        let caskroom = runner.prefix + "/Caskroom/"
        let todo: [(String, [String])] = packages.filter { $0.size == nil }.compactMap { p in
            // Formule : tout son dossier Cellar. Cask : ses .app, sinon son dossier Caskroom (outils en ligne de commande).
            let paths = p.kind == .formula ? [cellar + p.name] : (p.appPaths.isEmpty ? [caskroom + p.name] : p.appPaths)
            return paths.isEmpty ? nil : (p.id, paths)
        }
        guard !todo.isEmpty else { return }
        sizeTask?.cancel()
        sizeTask = Task.detached(priority: .background) {
            var batch: [String: Int64] = [:]
            for (id, paths) in todo {
                if Task.isCancelled { return }
                batch[id] = paths.reduce(0) { $0 + Self.diskSize($1) }
                if batch.count >= 15 {
                    let done = batch; batch = [:]
                    await MainActor.run { AppModel.shared.applySizes(done) }
                }
            }
            let done = batch
            await MainActor.run { AppModel.shared.applySizes(done) }
        }
    }

    private func applySizes(_ sizes: [String: Int64]) {
        guard !sizes.isEmpty else { return }
        var list = packages
        for idx in list.indices { if let s = sizes[list[idx].id] { list[idx].size = s } }
        packages = list
    }

    nonisolated static func diskSize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                              options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    func refreshUsage() {
        guard let runner, !packages.isEmpty else { return }
        let usage = ProcessScanner.usage(for: packages, prefix: runner.prefix)
        var changed = false
        var list = packages
        for idx in list.indices {
            let now = usage[list[idx].id] ?? []
            if list[idx].runningProcesses != now { list[idx].runningProcesses = now; changed = true }
        }
        if changed { packages = list }
    }

    // MARK: Mises à jour

    enum UpgradeSelection {
        case ids(Set<String>)
        case all
        case allExceptInUse
        case automatic
    }

    func upgrade(_ selection: UpgradeSelection, label: String? = nil) {
        Task { @MainActor in await self.requestUpgrade(selection, label: label) }
    }

    /// Demande le mot de passe tout de suite si des apps « admin » sont concernées, puis met en file.
    private func requestUpgrade(_ selection: UpgradeSelection, label: String?) async {
        var excluded = Set<String>()
        var adminPassword: String?
        if case .automatic = selection {} else {
            let list = resolve(selection)
            let admins = list.filter { $0.kind == .cask && $0.needsAdmin }
            if !admins.isEmpty {
                switch await AdminPasswordPrompt.ask(operations: admins.map { Self.upgradeDescription($0) },
                                                     allowSkip: admins.count < list.count) {
                case .password(let secret): adminPassword = secret
                case .skip: excluded = Set(admins.map(\.id))
                case .cancel: return
                }
            }
        }
        let title: String
        switch selection {
        case .ids(let ids):
            let names = packages.filter { ids.contains($0.id) }.map(\.name)
            title = label ?? (names.count == 1 ? tr("Mise à jour de %@", names[0]) : tr("Mise à jour de %d paquets", names.count))
        case .all: title = label ?? tr("Mise à jour de tout")
        case .allExceptInUse: title = label ?? tr("Mise à jour de tout sauf les paquets utilisés")
        case .automatic: title = label ?? tr("Mise à jour automatique des paquets non utilisés")
        }
        let expected = Set(resolve(selection).map(\.id)).subtracting(excluded)
        guard !expected.isEmpty else { return }
        queuedIDs.formUnion(expected)
        enqueue(title) {
            await self.performUpgrade(selection, expected: expected, excluded: excluded, adminPassword: adminPassword)
        }
    }

    private func resolve(_ selection: UpgradeSelection) -> [BrewPackage] {
        switch selection {
        case .ids(let ids): return outdatedPackages.filter { ids.contains($0.id) && !$0.pinned }
        case .all: return pendingPackages
        case .allExceptInUse: return pendingPackages.filter { !$0.inUse }
        case .automatic: return autoEligiblePackages
        }
    }

    private func performUpgrade(_ selection: UpgradeSelection, expected: Set<String>,
                                excluded: Set<String> = [], adminPassword: String? = nil) async {
        queuedIDs.subtract(expected)
        guard let runner else { return }
        guard isOnline else {
            if case .automatic = selection { return }
            fail(tr("Pas de réseau : impossible de télécharger les mises à jour."))
            return
        }
        refreshUsage()
        let list = resolve(selection).filter { !excluded.contains($0.id) }
        let isAutomatic: Bool
        if case .automatic = selection { isAutomatic = true } else { isAutomatic = false }
        let protectInUse: Bool
        switch selection {
        case .allExceptInUse, .automatic: protectInUse = true
        default: protectInUse = false
        }
        if protectInUse {
            let skipped = pendingPackages.filter(\.inUse)
            if !skipped.isEmpty {
                appendLog(.info, tr("Laissés de côté car utilisés : %@", skipped.map(\.name).joined(separator: ", ")))
            }
        }
        if isAutomatic {
            let admin = pendingPackages.filter { $0.needsAdmin && !$0.inUse }
            if !admin.isEmpty {
                appendLog(.info, tr("Laissés de côté car ils demandent le mot de passe administrateur : %@",
                                   admin.map(\.name).joined(separator: ", ")))
            }
        }
        guard !list.isEmpty else {
            appendLog(.info, tr("Rien à mettre à jour."))
            return
        }
        activeIDs.formUnion(list.map(\.id))
        defer { activeIDs.subtract(list.map(\.id)) }

        let gen = generation
        var failures: [String] = []
        var formulae = list.filter { $0.kind == .formula }
        var casks = list.filter { $0.kind == .cask }

        // Fermer proprement les apps ouvertes pour les relancer après, plutôt que de laisser brew les tuer.
        var relaunch: [URL] = []
        for cask in casks where cask.inUse {
            let apps = runningApps(for: cask)
            guard !apps.isEmpty else { continue }
            if !quitAndRelaunch {
                appendLog(.info, tr("%@ est ouvert : mise à jour reportée (option « fermer et relancer » désactivée).", cask.title))
                casks.removeAll { $0.id == cask.id }
                continue
            }
            appendLog(.info, tr("Fermeture de %@…", cask.title))
            if await quit(apps) {
                relaunch.append(contentsOf: apps.compactMap(\.bundleURL))
            } else {
                appendLog(.error, tr("%@ ne s'est pas fermé (fenêtre de confirmation ?) : mise à jour annulée pour ce paquet.", cask.title))
                failures.append(cask.name)
                casks.removeAll { $0.id == cask.id }
            }
        }

        if !formulae.isEmpty {
            var env = inUseCleanupProtection()
            // Ne pas embarquer des paquets utilisés via la mise à jour de leurs dépendances.
            if protectInUse { env["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1" }
            let r = await runner.run(["upgrade", "--formula", "--yes"] + formulae.map(\.name),
                                     extraEnv: env, cancellable: true,
                                     password: isAutomatic ? .denied : .prompt(operation: Self.upgradeDescription(formulae)),
                                     priority: isAutomatic ? .background : .utility,
                                     onLine: logSink)
            if !r.ok { failures.append(contentsOf: formulae.map(\.name)); appendLog(.error, r.failureSummary) }
            if r.cancelled { formulae = [] }
        }
        if !casks.isEmpty, gen == generation {
            // --greedy : les apps qui se mettent à jour seules sont traitées comme les autres.
            let args = ["upgrade", "--cask", "--yes", "--greedy"]
            if isAutomatic {
                // Une par une et sans dialogue de mot de passe : un cask qui réclame sudo échoue en silence
                // et n'est plus proposé à la mise à jour automatique.
                for cask in casks where gen == generation {
                    let r = await runner.runRetryingBusyImage(args + [cask.name], cancellable: true, password: .denied,
                                                              priority: .background, onLine: logSink)
                    guard !r.ok else { continue }
                    failures.append(cask.name)
                    let text = (r.stderr + r.stdoutString).lowercased()
                    if text.contains("sudo") || text.contains("password") || text.contains("askpass") {
                        learnedAdmin.insert(cask.id)
                        appendLog(.info, tr("%@ demande le mot de passe administrateur : il ne sera plus mis à jour automatiquement.", cask.name))
                    } else {
                        appendLog(.error, r.failureSummary)
                    }
                }
            } else {
                // Les apps « admin » avec le mot de passe saisi au moment du clic, une par une.
                for cask in casks where cask.needsAdmin && gen == generation {
                    guard let adminPassword else {
                        appendLog(.info, tr("%@ demande le mot de passe administrateur : non mis à jour.", cask.name))
                        failures.append(cask.name)
                        continue
                    }
                    let r = await runner.runRetryingBusyImage(args + [cask.name], cancellable: true,
                                                              password: .provided(adminPassword), onLine: logSink)
                    if !r.ok { failures.append(cask.name); appendLog(.error, r.failureSummary) }
                }
                let others = casks.filter { !$0.needsAdmin }
                if !others.isEmpty, gen == generation {
                    let r = await runner.runRetryingBusyImage(args + others.map(\.name), cancellable: true,
                                                              password: .prompt(operation: Self.upgradeDescription(others)),
                                                              onLine: logSink)
                    if !r.ok { failures.append(contentsOf: others.map(\.name)); appendLog(.error, r.failureSummary) }
                }
            }
        }

        for url in relaunch {
            appendLog(.info, tr("Relance de %@…", url.deletingPathExtension().lastPathComponent))
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }

        if restartServices {
            for f in formulae where f.serviceRunning {
                if let user = f.serviceUser, user != NSUserName() {
                    appendLog(.info, tr("Service %@ lancé par %@ : à redémarrer à la main (sudo brew services restart %@).", f.name, user, f.name))
                    continue
                }
                let r = await runner.run(["services", "restart", f.name], timeout: 120, onLine: logSink)
                if !r.ok { appendLog(.error, tr("Redémarrage du service %@ : %@", f.name, r.failureSummary)) }
            }
        }

        await reload()
        let stillOutdated = Set(outdatedPackages.map(\.name))
        let failedNames = Set(failures).intersection(stillOutdated)
        let succeeded = list.filter { !stillOutdated.contains($0.name) }
        if isAutomatic {
            for p in list where failedNames.contains(p.name) { autoFailures[p.id] = Date() }
            if notifyNewUpdates, !succeeded.isEmpty { notifyAutoUpgrade(succeeded, failed: failedNames.count) }
        }
        if failedNames.isEmpty {
            appendLog(.success, tr("Terminé : %d paquet(s) traité(s).", list.count))
        } else if isAutomatic {
            appendLog(.error, tr("Mise à jour automatique en échec pour : %@. Nouvel essai dans 6 h.", failedNames.sorted().joined(separator: ", ")))
        } else {
            fail(tr("Échec pour : %@. Détails dans le journal.", failedNames.sorted().joined(separator: ", ")))
        }
    }


    func runningApps(for p: BrewPackage) -> [NSRunningApplication] {
        guard !p.appPaths.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let path = app.bundleURL?.path else { return false }
            return p.appPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    private func quit(_ apps: [NSRunningApplication]) async -> Bool {
        for app in apps { app.terminate() }
        for _ in 0..<60 {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return apps.allSatisfy(\.isTerminated)
    }

    // MARK: Installer / désinstaller / entretien

    func install(_ kind: PackageKind, _ name: String, needsAdmin: Bool = false) {
        Task { @MainActor in
            var policy = BrewRunner.PasswordPolicy.prompt(operation: tr("Installation de %@", name))
            if needsAdmin {
                switch await AdminPasswordPrompt.ask(operations: [tr("Installation de %@", name)], allowSkip: false) {
                case .password(let secret): policy = .provided(secret)
                case .skip, .cancel: return
                }
            }
            self.enqueueInstall(kind, name, policy: policy)
        }
    }

    private func enqueueInstall(_ kind: PackageKind, _ name: String, policy: BrewRunner.PasswordPolicy) {
        enqueue(Self.installLabel(name)) {
            guard let runner = self.runner else { return }
            guard self.isOnline else { self.fail(tr("Pas de réseau : installation impossible.")); return }
            let r = await runner.runRetryingBusyImage(["install", kind.flag, "--yes", name], cancellable: true,
                                                      password: policy, onLine: self.logSink)
            await self.reload()
            if r.ok { self.appendLog(.success, tr("%@ est installé.", name)) }
            else { self.fail(tr("Installation de %@ : %@", name, r.failureSummary)) }
        }
    }

    func uninstall(_ p: BrewPackage, zap: Bool = false) {
        Task { @MainActor in
            var policy = BrewRunner.PasswordPolicy.prompt(operation: tr("Désinstallation de %@", p.title))
            if p.needsAdmin {
                switch await AdminPasswordPrompt.ask(operations: [tr("Désinstallation de %@", p.title)], allowSkip: false) {
                case .password(let secret): policy = .provided(secret)
                case .skip, .cancel: return
                }
            }
            self.enqueueUninstall(p, zap: zap, policy: policy)
        }
    }

    private func enqueueUninstall(_ p: BrewPackage, zap: Bool, policy: BrewRunner.PasswordPolicy) {
        enqueue(tr("Désinstallation de %@", p.name)) {
            guard let runner = self.runner else { return }
            var args = ["uninstall", p.kind.flag]
            if zap && p.kind == .cask { args.append("--zap") }
            let r = await runner.run(args + [p.name], cancellable: true,
                                     password: policy, onLine: self.logSink)
            await self.reload()
            if r.ok { self.appendLog(.success, tr("%@ est désinstallé.", p.name)) }
            else { self.fail(tr("Désinstallation de %@ : %@", p.name, r.failureSummary)) }
        }
    }

    /// - Parameter automatic: nettoyage hebdomadaire, en tâche de fond et sans jamais demander de mot de passe.
    func cleanup(automatic: Bool = false) {
        enqueue(automatic ? tr("Nettoyage hebdomadaire (brew cleanup)") : tr("Nettoyage (brew cleanup)")) {
            guard let runner = self.runner else { return }
            self.refreshUsage()
            let r = await runner.run(["cleanup"], extraEnv: self.inUseCleanupProtection(), cancellable: true,
                                     password: automatic ? .denied : .prompt(operation: tr("Nettoyage (brew cleanup)")),
                                     priority: automatic ? .background : .utility, onLine: self.logSink)
            let freed = r.stdoutString.split(separator: "\n").last { $0.contains("freed approximately") }
            self.appendLog(r.ok ? .success : .error, r.ok ? (freed.map(String.init) ?? tr("Nettoyage terminé.")) : r.failureSummary)
            if r.ok, !automatic { self.defaults.set(Date(), forKey: Keys.lastCleanup) }
            // Les anciennes versions des formules ont pu disparaître : leurs tailles sont recalculées.
            if r.ok {
                self.packages = self.packages.map { p in
                    var p = p
                    if p.kind == .formula { p.size = nil }
                    return p
                }
                self.computeMissingSizes()
            }
        }
    }

    /// brew doctor : vérification de l'installation Homebrew. Le résultat s'affiche dans le journal.
    func doctor() {
        UserDefaults.standard.set(SidebarItem.log.rawValue, forKey: "section")
        enqueue(tr("Diagnostic (brew doctor)")) {
            guard let runner = self.runner else { return }
            let r = await runner.run(["doctor"], timeout: 300, cancellable: true, onLine: self.logSink)
            if r.cancelled { return }
            let text = r.stderr + "\n" + r.stdoutString
            let warnings = text.split(separator: "\n").filter { $0.hasPrefix("Warning:") }.count
            if r.status == 0 {
                self.appendLog(.success, tr("brew doctor : aucun problème détecté."))
            } else if warnings > 0 {
                self.appendLog(.error, trn(warnings, "brew doctor : %d avertissement, détails ci-dessus.",
                                           "brew doctor : %d avertissements, détails ci-dessus."))
            } else {
                self.appendLog(.error, tr("brew doctor : %@", r.failureSummary))
            }
        }
    }

    func autoremove() {
        enqueue(tr("Suppression des dépendances inutiles (brew autoremove)")) {
            guard let runner = self.runner else { return }
            let r = await runner.run(["autoremove"], cancellable: true,
                                     password: .prompt(operation: tr("Suppression des dépendances inutiles (brew autoremove)")), onLine: self.logSink)
            await self.reload()
            self.appendLog(r.ok ? .success : .error, r.ok ? tr("Dépendances inutiles supprimées.") : r.failureSummary)
        }
    }

    func setIgnored(_ p: BrewPackage, _ value: Bool) {
        if value { ignored.insert(p.id) } else { ignored.remove(p.id) }
    }

    func clearIgnored(_ id: String) { ignored.remove(id) }

    // MARK: Recherche (lecture seule, hors file)

    func search(_ query: String) async -> Result<[SearchResult], Error> {
        guard let runner else { return .success([]) }
        // `--desc` cherche dans le nom et la description des casks, mais seulement dans la description
        // des formules : une recherche par nom de formule en parallèle.
        async let byName = runner.run(["search", "--formula", query], timeout: 60)
        async let byDesc = runner.run(["search", "--desc", query], timeout: 60)
        let (n, d) = await (byName, byDesc)
        var seen = Set<String>()
        var results: [SearchResult] = []
        // Les résultats par description d'abord : ils portent la description.
        for r in BrewParser.searchResults(d.stdoutString) + BrewParser.searchResults(n.stdoutString, defaultKind: .formula)
        where seen.insert(r.id).inserted {
            results.append(r)
        }
        if !results.isEmpty || n.ok || d.ok { return .success(results) }
        // brew sort en erreur quand rien ne correspond.
        let stderr = n.stderr + d.stderr
        if stderr.contains("No formulae or casks found") || stderr.contains("No formula") { return .success([]) }
        return .failure(NSError(domain: "Brasseur", code: Int(n.status),
                                userInfo: [NSLocalizedDescriptionKey: n.failureSummary]))
    }

    /// Site, description et besoin du mot de passe de paquets trouvés, en un seul appel (lecture seule).
    /// Clés : identifiants des paquets (`BrewPackage.makeID`).
    func summaries(_ kind: PackageKind, _ names: [String]) async -> [String: CaskSummary] {
        guard let runner, !names.isEmpty else { return [:] }
        let r = await runner.run(["info", "--json=v2", kind.flag] + names, timeout: 60)
        return BrewParser.summaries(r.stdout)
    }

    func details(_ kind: PackageKind, _ name: String) async -> PackageDetails? {
        guard let runner else { return nil }
        let r = await runner.run(["info", "--json=v2", kind.flag, name], timeout: 60)
        guard r.ok else { return nil }
        return BrewParser.details(r.stdout, kind: kind)
    }

    // MARK: File d'opérations

    private func enqueue(_ label: String, _ operation: @escaping @MainActor () async -> Void) {
        pendingTasks.append(label)
        let previous = queueTail
        let gen = generation
        queueTail = Task { @MainActor in
            await previous?.value
            if let idx = self.pendingTasks.firstIndex(of: label) { self.pendingTasks.remove(at: idx) }
            guard gen == self.generation else {
                if label == Self.checkLabel { self.checkQueued = false }
                return
            }
            self.currentTask = label
            self.appendLog(.section, label)
            await operation()
            self.currentTask = nil
            if self.pendingTasks.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    self.maybeAutoUpgrade()
                }
            }
        }
    }

    /// Arrête l'opération en cours et vide la file.
    func cancelAll() {
        generation += 1
        runner?.cancelAll()
        queuedIDs.removeAll()
        appendLog(.error, tr("Opérations arrêtées à la demande."))
    }

    // MARK: Journal

    private var logSink: @Sendable (String, Bool) -> Void {
        { [weak self] line, isError in
            Task { @MainActor in self?.appendLog(isError && line.hasPrefix("Error") ? .error : .output, line) }
        }
    }

    func appendLog(_ kind: LogLine.Kind, _ text: String) {
        log.append(LogLine(kind: kind, text: text))
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    func clearLog() { log.removeAll() }

    private func fail(_ message: String) {
        lastOperationError = message
        appendLog(.error, message)
    }

    // MARK: Dock, badge, notifications, ouverture de session

    private func updateBadge() {
        let count = pendingCount
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func applyDockPolicy() {
        NSApp?.setActivationPolicy(showInDock ? .regular : .accessory)
        updateBadge()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                fail(tr("Ouverture à la connexion : %@", error.localizedDescription))
            }
            objectWillChange.send()
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    private func notifyAutoUpgrade(_ done: [BrewPackage], failed: Int) {
        let content = UNMutableNotificationContent()
        content.title = trn(done.count, "%d paquet mis à jour", "%d paquets mis à jour")
        content.body = done.prefix(6).map(\.name).joined(separator: ", ")
            + (done.count > 6 ? "…" : "") + (failed > 0 ? "\n" + tr("%d en échec, voir le journal.", failed) : "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func notify(_ fresh: [BrewPackage]) {
        let content = UNMutableNotificationContent()
        content.title = trn(fresh.count, "%d nouvelle mise à jour", "%d nouvelles mises à jour")
        content.body = fresh.prefix(6).map { "\($0.name) \($0.installedVersion) → \($0.latestVersion)" }
            .joined(separator: "\n") + (fresh.count > 6 ? "\n…" : "")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
