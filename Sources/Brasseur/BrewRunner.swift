import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
    let cancelled: Bool

    var ok: Bool { status == 0 && !timedOut && !cancelled }
    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }

    /// Dernières lignes utiles pour expliquer un échec.
    var failureSummary: String {
        if cancelled { return tr("Opération arrêtée.") }
        if timedOut { return tr("Délai dépassé : brew ne répondait plus.") }
        let text = stderr.isEmpty ? stdoutString : stderr
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let errors = lines.filter { $0.hasPrefix("Error") || $0.hasPrefix("fatal") || $0.contains("Could not resolve") }
        return (errors.last ?? lines.last ?? tr("Code de sortie %d", Int(status)))
    }
}

/// Lance brew comme sous-processus et diffuse sa sortie ligne à ligne.
final class BrewRunner: @unchecked Sendable {
    let brewPath: String
    let prefix: String

    private let lock = NSLock()
    private var cancellable: [Process] = []
    private var cancelRequested = Set<ObjectIdentifier>()
    private var cancelEpoch = 0
    /// Appelé (sur un thread quelconque) quand une recherche Spotlight lancée par brew a dû être arrêtée.
    var onSpotlightStall: (@Sendable () -> Void)?

    /// Lectures en cours (info, outdated, search…), arrêtées quand Brasseur quitte.
    private var readers: [Process] = []

    init?() {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"]
        guard let brew = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        brewPath = brew
        prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent().path
        AskpassSession.cleanupLeftovers()
    }

    /// Mot de passe administrateur pour une commande brew.
    enum PasswordPolicy: Sendable {
        /// Jamais : sudo échoue sans fenêtre.
        case denied
        /// Fenêtre de secours décrivant l'opération, une seule fois.
        case prompt(operation: String)
        /// Déjà saisi et vérifié par l'utilisateur au moment du clic.
        case provided(String)
    }

    /// Priorité du processus brew et de tout ce qu'il lance (curl, hdiutil, sudo…).
    enum Priority: String, Sendable {
        /// Opération demandée par l'utilisateur : priorité réduite, sans ralentir.
        case utility
        /// Tâche de fond (vérifications, mises à jour automatiques) : cœurs économes, disque et réseau en dernier.
        case background
    }

    private func environment(askpass: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"   // Brasseur lance lui-même `brew update`
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_EMOJI"] = "1"
        // Un téléchargement à la fois : moins de charge, et pas de DMG monté deux fois en parallèle
        // (« hdiutil: attach failed - Resource busy »).
        env["HOMEBREW_DOWNLOAD_CONCURRENCY"] = "1"
        env.removeValue(forKey: "HOMEBREW_COLOR")
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // brew passe `sudo -A` quand SUDO_ASKPASS existe : le mot de passe est demandé par une boîte de dialogue macOS.
        // Avec /usr/bin/false, sudo échoue sans rien afficher.
        env["SUDO_ASKPASS"] = askpass
        return env
    }

    /// - Parameters:
    ///   - cancellable: l'opération peut être interrompue par `cancelAll()`.
    ///   - onLine: reçoit chaque ligne de sortie (stdout et stderr), sur un thread quelconque.
    func run(_ args: [String],
             extraEnv: [String: String] = [:],
             timeout: TimeInterval? = nil,
             cancellable isCancellable: Bool = false,
             password: PasswordPolicy = .denied,
             priority: Priority = .utility,
             onLine: (@Sendable (String, Bool) -> Void)? = nil) async -> CommandResult {
        let session: AskpassSession
        switch password {
        case .denied: session = .denied()
        case .prompt(let operation): session = .dialog(operation: operation)
        case .provided(let secret): session = .provided(secret)
        }
        defer { session.finish() }
        let askpass = session.path
        return await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
            let process = Process()
            // taskpolicy remplace son propre processus par brew (même pid) et borne sa priorité
            // ainsi que celle de ses enfants.
            if FileManager.default.isExecutableFile(atPath: Self.taskpolicy) {
                process.executableURL = URL(fileURLWithPath: Self.taskpolicy)
                process.arguments = ["-c", priority.rawValue, brewPath] + args
            } else {
                process.executableURL = URL(fileURLWithPath: brewPath)
                process.arguments = args
            }
            process.environment = environment(askpass: askpass).merging(extraEnv) { $1 }
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let collector = OutputCollector(onLine: onLine)
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.append(data, isError: false) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.append(data, isError: true) }
            }

            process.terminationHandler = { [weak self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), isError: false)
                collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), isError: true)
                collector.flush()
                let wasCancelled = self?.unregister(proc) ?? false
                self?.unregisterReader(proc)
                continuation.resume(returning: CommandResult(
                    status: proc.terminationStatus, stdout: collector.stdout, stderr: collector.stderrText,
                    timedOut: collector.timedOut, cancelled: wasCancelled))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: CommandResult(status: -1, stdout: Data(),
                    stderr: tr("Impossible de lancer brew : %@", error.localizedDescription), timedOut: false, cancelled: false))
                return
            }
            if isCancellable { register(process) } else { registerReader(process) }
            watchSpotlight(of: process)
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    collector.markTimedOut()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }

    private static let taskpolicy = "/usr/sbin/taskpolicy"

    /// brew demande à Spotlight où est Xcode (`mdfind`) quand seuls les Command Line Tools sont installés.
    /// Un partage réseau qui ne répond plus bloque toutes les recherches Spotlight, donc brew avec elles.
    /// Au-delà de 10 s, on arrête ce `mdfind` : brew reçoit une réponse vide (« pas de Xcode ») et continue.
    private func watchSpotlight(of process: Process) {
        let root = process.processIdentifier
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        var firstSeen: [pid_t: Date] = [:]
        timer.schedule(deadline: .now() + 5, repeating: 3, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard process.isRunning else { timer.cancel(); return }
            let now = Date()
            var stalled = false
            for pid in ProcessScanner.descendants(of: root) where ProcessScanner.path(of: pid) == "/usr/bin/mdfind" {
                let seen = firstSeen[pid] ?? now
                firstSeen[pid] = seen
                if now.timeIntervalSince(seen) >= 10 { kill(pid, SIGKILL); stalled = true }
            }
            if stalled { self?.onSpotlightStall?() }
        }
        timer.resume()
    }

    /// Comme `run`, avec un nouvel essai quand l'image disque d'un cask n'a pas pu être montée :
    /// erreur passagère (image encore vérifiée par macOS, ou montée ailleurs au même moment).
    func runRetryingBusyImage(_ args: [String],
                              extraEnv: [String: String] = [:],
                              cancellable isCancellable: Bool = false,
                              password: PasswordPolicy = .denied,
                              priority: Priority = .utility,
                              onLine: (@Sendable (String, Bool) -> Void)? = nil) async -> CommandResult {
        let first = await run(args, extraEnv: extraEnv, cancellable: isCancellable,
                              password: password, priority: priority, onLine: onLine)
        guard !first.ok, !first.cancelled, !first.timedOut, Self.isBusyImageFailure(first) else { return first }
        onLine?(tr("Image disque occupée : nouvel essai dans 20 s…"), false)
        let epoch = currentCancelEpoch
        try? await Task.sleep(for: .seconds(20))
        guard epoch == currentCancelEpoch else { return first }   // « Arrêter » pendant l'attente
        return await run(args, extraEnv: extraEnv, cancellable: isCancellable,
                         password: password, priority: priority, onLine: onLine)
    }

    static func isBusyImageFailure(_ r: CommandResult) -> Bool {
        (r.stderr + "\n" + r.stdoutString).contains("hdiutil: attach failed")
    }

    private var currentCancelEpoch: Int { lock.lock(); defer { lock.unlock() }; return cancelEpoch }

    func cancelAll() {
        lock.lock()
        cancelEpoch += 1
        let procs = cancellable
        for p in procs { cancelRequested.insert(ObjectIdentifier(p)) }
        lock.unlock()
        for p in procs where p.isRunning { p.terminate() }
    }

    /// À la fermeture de Brasseur : les lectures n'ont plus de destinataire, on les arrête.
    /// Les mises à jour en cours, elles, vont à leur terme plutôt que de laisser un paquet à moitié installé.
    func terminateReads() {
        lock.lock()
        let procs = readers
        lock.unlock()
        for p in procs where p.isRunning { p.terminate() }
    }

    private func registerReader(_ p: Process) {
        lock.lock(); readers.append(p); lock.unlock()
    }

    private func unregisterReader(_ p: Process) {
        lock.lock(); readers.removeAll { $0 === p }; lock.unlock()
    }

    private func register(_ p: Process) {
        lock.lock(); cancellable.append(p); lock.unlock()
    }

    private func unregister(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        cancellable.removeAll { $0 === p }
        return cancelRequested.remove(ObjectIdentifier(p)) != nil
    }
}

/// Accumule la sortie d'un processus et la découpe en lignes (brew utilise aussi \r pour ses barres de progression).
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: (@Sendable (String, Bool) -> Void)?
    private(set) var stdout = Data()
    private var stderr = Data()
    private var pending: [Bool: Data] = [false: Data(), true: Data()]
    private(set) var timedOut = false

    init(onLine: (@Sendable (String, Bool) -> Void)?) { self.onLine = onLine }

    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return Self.clean(String(decoding: stderr, as: UTF8.self))
    }

    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        if isError { stderr.append(data) } else { stdout.append(data) }
        if onLine != nil {
            var buffer = pending[isError, default: Data()]
            buffer.append(data)
            while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer[buffer.startIndex..<idx]
                lines.append(String(decoding: lineData, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...idx)
            }
            pending[isError] = buffer
        }
        lock.unlock()
        emit(lines, isError: isError)
    }

    func flush() {
        lock.lock()
        let rest = pending.map { ($0.key, String(decoding: $0.value, as: UTF8.self)) }
        pending = [false: Data(), true: Data()]
        lock.unlock()
        for (isError, text) in rest where !text.isEmpty { emit([text], isError: isError) }
    }

    private func emit(_ lines: [String], isError: Bool) {
        guard let onLine else { return }
        for line in lines {
            let cleaned = Self.clean(line)
            if !cleaned.trimmingCharacters(in: .whitespaces).isEmpty { onLine(cleaned, isError) }
        }
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
    static func clean(_ s: String) -> String {
        ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}
