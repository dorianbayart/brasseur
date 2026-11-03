import Foundation

/// `Brasseur --selftest` : lit l'état réel de brew sans interface et affiche un résumé, puis quitte.
enum SelfTest {
    static func run() {
        guard let runner = BrewRunner() else { print("brew introuvable"); exit(1) }
        if CommandLine.arguments.contains("--askpass-test") { askpassTest(); exit(0) }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            async let info = runner.run(["info", "--json=v2", "--installed"], timeout: 180)
            async let outdated = runner.run(["outdated", "--json=v2", "--greedy"], timeout: 180)
            async let services = runner.run(["services", "list", "--json"], timeout: 60)
            async let search = runner.run(["search", "--desc", "chromium"], timeout: 60)
            let (i, o, s, q) = await (info, outdated, services, search)
            do {
                var list = try BrewParser.packages(info: i.stdout, outdated: o.stdout, services: s.ok ? s.stdout : nil)
                let usage = ProcessScanner.usage(for: list, prefix: runner.prefix)
                for idx in list.indices { list[idx].runningProcesses = usage[list[idx].id] ?? [] }
                let outdatedList = list.filter(\.outdated)
                print("brew: \(runner.brewPath)")
                print("installés: \(list.filter { $0.kind == .formula }.count) formules, \(list.filter { $0.kind == .cask }.count) casks")
                print("en retard: \(outdatedList.filter { !$0.greedyOnly }.count) (+\(outdatedList.filter(\.greedyOnly).count) greedy)")
                print("utilisés:")
                for p in list where p.inUse { print("  \(p.id)  \(p.usageDescription)") }
                let auto = outdatedList.filter { !$0.pinned && !$0.inUse && !$0.needsAdmin }
                let running = list.filter { $0.kind == .formula && $0.inUse }
                print("auto-éligibles: \(auto.count)  protégés du nettoyage: \(Set(running.map(\.name) + running.flatMap(\.runtimeDeps)).sorted())")
                print("admin: " + list.filter(\.needsAdmin).map(\.name).joined(separator: ", "))
                print("exemples:")
                for p in outdatedList.prefix(5) { print("  \(p.id) \(p.installedVersion) -> \(p.latestVersion) greedyOnly=\(p.greedyOnly) apps=\(p.appPaths)") }
                let results = BrewParser.searchResults(q.stdoutString)
                print("recherche 'chromium': \(results.count) résultats, ex. \(results.prefix(3).map { "\($0.id) [\($0.displayName)] \($0.desc)" })")
                let counter = LineCounter()
                let dry = await runner.run(["upgrade", "--dry-run", "--formula", "btop"], timeout: 120) { line, _ in counter.add(line) }
                print("dry-run upgrade btop: status=\(dry.status) lignes reçues en direct=\(counter.lines.count) ex. \(counter.lines.prefix(3))")
            } catch {
                print("ERREUR d'analyse : \(error)")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}

final class LineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [String] = []
    func add(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
}

extension SelfTest {
    /// Vérifie le tube du mot de passe et la fenêtre de secours sans lancer sudo ni afficher de fenêtre.
    static func askpassTest() {
        func runScript(_ path: String) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let session = AskpassSession.provided("s3cr3t 'quote\"")
        for i in 1...3 {
            let (status, output) = runScript(session.path)
            print("lecture \(i): status=\(status) ok=\(output == "s3cr3t 'quote\"\n")")
        }
        let start = Date()
        let dir = URL(fileURLWithPath: session.path).deletingLastPathComponent()
        session.finish()
        print("fermeture en \(Int(Date().timeIntervalSince(start) * 1000)) ms, dossier effacé=\(!FileManager.default.fileExists(atPath: dir.path))")

        let dialog = AskpassSession.dialog(operation: "Test")
        let ddir = URL(fileURLWithPath: dialog.path).deletingLastPathComponent()
        FileManager.default.createFile(atPath: ddir.appendingPathComponent("cancelled").path, contents: nil)
        let (status, output) = runScript(dialog.path)
        print("après annulation : status=\(status) sortie vide=\(output.isEmpty) (aucune fenêtre)")
        dialog.finish()
        print("dossier de secours effacé=\(!FileManager.default.fileExists(atPath: ddir.path))")
    }
}
