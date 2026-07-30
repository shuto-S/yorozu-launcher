import AppKit

@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()

    private let cache: NSCache<NSString, NSImage>

    private init() {
        cache = NSCache()
        cache.countLimit = 128
    }

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
