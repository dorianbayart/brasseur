import AppKit
import Darwin
import Foundation

/// Ce que `sudo -A` appelle pour obtenir le mot de passe administrateur (variable SUDO_ASKPASS).
/// brew ne transmet à sudo que cette variable : tout le contexte doit tenir dans le programme désigné.
final class AskpassSession: @unchecked Sendable {
    /// Valeur à donner à SUDO_ASKPASS.
    let path: String
    private let directory: URL?
    private let fifoPath: String?
    private let lock = NSLock()
    private var stopped = false
    private let writerDone = DispatchSemaphore(value: 0)

    private init(path: String, directory: URL?, fifoPath: String?) {
        self.path = path
        self.directory = directory
        self.fifoPath = fifoPath
    }

    static var baseDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Brasseur", isDirectory: true)
    }

    /// Aucun mot de passe : sudo échoue tout de suite, sans fenêtre.
    static func denied() -> AskpassSession {
        AskpassSession(path: "/usr/bin/false", directory: nil, fifoPath: nil)
    }

    /// Mot de passe déjà saisi et vérifié : il est servi à sudo par un tube nommé, jamais écrit sur disque.
    static func provided(_ password: String) -> AskpassSession {
        guard let dir = makeDirectory() else { return denied() }
        let fifo = dir.appendingPathComponent("pipe").path
        guard mkfifo(fifo, 0o600) == 0 else { return denied() }
        let script = dir.appendingPathComponent("askpass.sh")
        guard writeScript("#!/bin/sh\nexec /bin/cat \(shellQuoted(fifo))\n", to: script) else { return denied() }
        let session = AskpassSession(path: script.path, directory: dir, fifoPath: fifo)
        session.startWriter(password: password)
        return session
    }

    /// Fenêtre de secours, pour un paquet dont on ne savait pas qu'il demanderait le mot de passe.
    /// Elle décrit l'opération ; après une annulation, elle ne se rouvre plus pendant cette opération.
    static func dialog(operation: String) -> AskpassSession {
        guard let dir = makeDirectory() else { return denied() }
        let marker = dir.appendingPathComponent("cancelled").path
        let message = operation + "\n\n" + tr("brew a besoin du mot de passe administrateur pour continuer. Annulez si vous ne souhaitez pas faire cette opération.")
        let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns")
        let icon = iconPath.map { "with icon (POSIX file \(appleScriptQuoted($0)))" } ?? "with icon caution"
        let cancel = appleScriptQuoted(tr("Annuler"))
        let script = """
        #!/bin/sh
        # Généré par Brasseur pour sudo -A, supprimé à la fin de l'opération.
        [ -f \(shellQuoted(marker)) ] && exit 1
        /usr/bin/osascript - <<'BRASSEUR_EOF' && exit 0
        set r to display dialog \(appleScriptQuoted(message)) default answer "" with hidden answer with title "Brasseur" \(icon) buttons {\(cancel), "OK"} default button "OK" cancel button \(cancel)
        text returned of r
        BRASSEUR_EOF
        : > \(shellQuoted(marker))
        exit 1

        """
        let file = dir.appendingPathComponent("askpass.sh")
        guard writeScript(script, to: file) else { return denied() }
        return AskpassSession(path: file.path, directory: dir, fifoPath: nil)
    }

    /// À appeler quand la commande brew est terminée : arrête le tube et efface les fichiers.
    func finish() {
        if let fifoPath {
            lock.lock(); stopped = true; lock.unlock()
            // Ouvrir le tube en lecture débloque l'écrivain s'il attend un lecteur.
            let fd = open(fifoPath, O_RDONLY | O_NONBLOCK)
            _ = writerDone.wait(timeout: .now() + 2)
            if fd >= 0 { close(fd) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func startWriter(password: String) {
        guard let fifoPath else { return }
        let bytes = Array((password + "\n").utf8)
        let thread = Thread { [self] in
            defer { writerDone.signal() }
            // Chaque appel de sudo lit le tube une fois : on resert le mot de passe à chaque lecteur.
            while true {
                let fd = open(fifoPath, O_WRONLY)
                if fd < 0 { return }
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                if isStopped { close(fd); return }
                _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                close(fd)
            }
        }
        thread.start()
    }

    private static func makeDirectory() -> URL? {
        guard let base = baseDirectory else { return nil }
        let dir = base.appendingPathComponent("askpass-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return dir
        } catch {
            return nil
        }
    }

    private static func writeScript(_ script: String, to url: URL) -> Bool {
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Efface ce qui serait resté d'une session précédente (plantage, ancienne version).
    static func cleanupLeftovers() {
        guard let base = baseDirectory else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix("askpass") {
            try? fm.removeItem(at: base.appendingPathComponent(name))
        }
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Demande du mot de passe au moment où l'utilisateur lance l'opération, et vérification immédiate.
@MainActor
enum AdminPasswordPrompt {
    enum Choice {
        case password(String)
        /// Continuer sans les paquets qui demandent le mot de passe.
        case skip
        case cancel
    }

    /// - Parameters:
    ///   - operations: ce qui sera fait, une ligne par app (« Mise à jour de Tunnelblick » + versions).
    ///   - allowSkip: propose de continuer sans ces apps (mise à jour groupée).
    static func ask(operations: [String], allowSkip: Bool) async -> Choice {
        var wrongPassword = false
        while true {
            let alert = NSAlert()
            alert.messageText = tr("Mot de passe administrateur")
            var info = operations.joined(separator: "\n\n")
            info += "\n\n" + tr("brew a besoin du mot de passe administrateur pour cette opération. Il est vérifié tout de suite, puis oublié à la fin de l'opération.")
            if wrongPassword { info += "\n\n" + tr("Mot de passe incorrect, réessayez.") }
            alert.informativeText = info
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = tr("Mot de passe de %@", NSUserName())
            alert.accessoryView = field
            alert.addButton(withTitle: tr("Continuer"))
            if allowSkip { alert.addButton(withTitle: tr("Continuer sans ces apps")) }
            let cancelButton = alert.addButton(withTitle: tr("Annuler"))
            cancelButton.keyEquivalent = "\u{1b}"
            alert.window.initialFirstResponder = field
            NSApp.activate()

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                let password = field.stringValue
                if !password.isEmpty, await validate(password) { return .password(password) }
                wrongPassword = true
            case .alertSecondButtonReturn where allowSkip:
                return .skip
            default:
                return .cancel
            }
        }
    }

    /// Vérifie le mot de passe auprès de sudo sans rien modifier (lance /usr/bin/true).
    nonisolated static func validate(_ password: String) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-S", "-k", "-p", "", "/usr/bin/true"]
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "SUDO_ASKPASS")
            process.environment = env
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            input.fileHandleForWriting.write(Data((password + "\n").utf8))
            try? input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate(); return false }
            return process.terminationStatus == 0
        }.value
    }
}
