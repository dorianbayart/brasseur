import Darwin
import Foundation

/// Repère les paquets brew en cours d'utilisation à partir des chemins réels des exécutables lancés.
enum ProcessScanner {
    static func executablePaths() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        let ownPID = getpid()
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var paths = Set<String>()
        for pid in pids.prefix(Int(found)) where pid > 0 && pid != ownPID {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                paths.insert(String(cString: buffer))
            }
        }
        return Array(paths)
    }

    /// Chemin de l'exécutable d'un processus.
    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Enfants, petits-enfants… d'un processus.
    static func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [root]
        while let pid = queue.popLast(), result.count < 256 {
            var children = [pid_t](repeating: 0, count: 64)
            let n = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            guard n > 0 else { continue }
            for child in children.prefix(Int(n)) where child > 0 {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// Partages réseau montés (lu sans interroger les serveurs : MNT_NOWAIT ne bloque jamais).
    static func networkMounts() -> [String] {
        let network: Set<String> = ["nfs", "smbfs", "afpfs", "webdav", "macfuse", "osxfuse", "fusefs", "cifs", "ftp"]
        var buffer: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buffer, MNT_NOWAIT)   // tampon géré par le système
        guard n > 0, let buffer else { return [] }
        let home = NSHomeDirectory()
        return UnsafeBufferPointer(start: buffer, count: Int(n)).compactMap { s in
            var st = s
            let type = withUnsafeBytes(of: &st.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard network.contains(type) || type.hasPrefix("fuse") else { return nil }
            let path = withUnsafeBytes(of: &st.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
    }

    /// Ce qui tourne depuis un paquet : ses exécutables, et à part les extensions (.appex) que macOS
    /// lance lui-même (widgets, Quick Look, Finder Sync…), qui ne signifient pas que l'app est ouverte.
    struct Usage: Equatable, Sendable {
        var processes: [String] = []
        var extensions: [String] = []
    }

    /// Associe chaque identifiant de paquet à ce qui tourne depuis ses fichiers.
    static func usage(for packages: [BrewPackage], prefix: String) -> [String: Usage] {
        let cellar = prefix + "/Cellar/"
        let caskroom = prefix + "/Caskroom/"
        var appOwner: [String: String] = [:]
        for p in packages where p.kind == .cask {
            for path in p.appPaths { appOwner[path] = p.id }
        }

        var processes: [String: Set<String>] = [:]
        var extensions: [String: Set<String>] = [:]
        for path in executablePaths() {
            var owner: String?
            if path.hasPrefix(cellar) {
                let name = path.dropFirst(cellar.count).split(separator: "/").first.map(String.init)
                owner = name.map { BrewPackage.makeID(.formula, $0) }
            } else if path.hasPrefix(caskroom) {
                let name = path.dropFirst(caskroom.count).split(separator: "/").first.map(String.init)
                owner = name.map { BrewPackage.makeID(.cask, $0) }
            } else if let range = path.range(of: ".app/") {
                // /Applications/Foo.app/Contents/... → /Applications/Foo.app
                let bundle = String(path[..<range.lowerBound]) + ".app"
                owner = appOwner[bundle]
            }
            guard let owner else { continue }
            // …/PlugIns/WidgetsExtension.appex/Contents/MacOS/WidgetsExtension → WidgetsExtension
            if let appex = path.split(separator: "/").first(where: { $0.hasSuffix(".appex") }) {
                extensions[owner, default: []].insert(String(appex.dropLast(".appex".count)))
            } else {
                processes[owner, default: []].insert((path as NSString).lastPathComponent)
            }
        }
        var result: [String: Usage] = [:]
        for id in Set(processes.keys).union(extensions.keys) {
            result[id] = Usage(processes: (processes[id] ?? []).sorted(), extensions: (extensions[id] ?? []).sorted())
        }
        return result
    }
}
