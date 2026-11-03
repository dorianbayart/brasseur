import AppKit
import SwiftUI

/// Icônes des paquets : l'icône du .app pour une app installée, sinon celle du site du projet
/// (téléchargée directement depuis ce site), sinon un pictogramme.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    @Published private(set) var siteIcons: [String: NSImage] = [:]
    private var appIcons: [String: NSImage] = [:]
    private var attempted = Set<String>()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 32 << 20)
        return URLSession(configuration: config)
    }()

    func appIcon(_ path: String) -> NSImage? {
        if let cached = appIcons[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        appIcons[path] = image
        return image
    }

    /// Les icônes de site peuvent faire 512 px ou plus : on n'en garde qu'une version 128 px en mémoire.
    private static func thumbnail(_ image: NSImage, side: CGFloat = 128) -> NSImage {
        guard image.size.width > side || image.size.height > side,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: NSSize(width: side, height: side))
        small.addRepresentation(rep)
        return small
    }

    static func host(of homepage: String?) -> String? {
        guard let homepage, let url = URL(string: homepage), let host = url.host else { return nil }
        return host
    }

    /// Charge l'icône du site (apple-touch-icon puis favicon.ico) ; un échec n'est pas retenté.
    func loadSiteIcon(host: String) async {
        guard siteIcons[host] == nil, !attempted.contains(host), AppModel.shared.isOnline else { return }
        attempted.insert(host)
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            guard let url = URL(string: "https://\(host)\(path)") else { continue }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.isValid, image.size.width >= 16 else { continue }
            siteIcons[host] = Self.thumbnail(image)
            return
        }
    }
}

struct PackageIcon: View {
    @ObservedObject private var store = IconStore.shared
    let kind: PackageKind
    var appPath: String?
    var homepage: String?
    var size: CGFloat = 24

    var body: some View {
        let host = kind == .cask ? IconStore.host(of: homepage) : nil
        Group {
            if let appPath, let image = store.appIcon(appPath) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if let host, let image = store.siteIcons[host] {
                Image(nsImage: image).resizable().interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                Image(systemName: kind == .cask ? "macwindow" : "terminal")
                    .resizable().scaledToFit()
                    .padding(size * 0.15)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .help(kind.label)
        .task(id: host) {
            if let host, appPath.flatMap({ store.appIcon($0) }) == nil { await store.loadSiteIcon(host: host) }
        }
    }
}

extension BrewPackage {
    var icon: PackageIcon { PackageIcon(kind: kind, appPath: appPaths.first, homepage: homepage) }

    var formattedSize: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
