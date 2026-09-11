import SwiftUI

/// Remote URLs never start a request. Only photos already on this phone are displayed.
struct LocalAvatar: View {
    private static let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    let url: URL?
    private var fallback = AnyView(Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary))
    private var mode: ContentMode = .fill
    init(_ url: URL?) { self.url = url }
    func placeholder<V: View>(@ViewBuilder _ content: () -> V) -> Self {
        var copy = self; copy.fallback = AnyView(content()); return copy
    }
    func resizable() -> Self { self }
    func scaledToFill() -> Self { var copy = self; copy.mode = .fill; return copy }
    func scaledToFit() -> Self { var copy = self; copy.mode = .fit; return copy }
    var body: some View {
        Group {
            if let image = Self.cachedImage(url) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: mode)
            } else { fallback }
        }
    }
    private static func cachedImage(_ originalURL: URL?) -> UIImage? {
        guard let originalURL else { return nil }
        let url: URL
        if originalURL.isFileURL {
            url = originalURL
        } else {
            // Read old thumbnails from this phone only; never fetch a remote URL.
            let name = LocalCardPhoto.hash(Data(originalURL.absoluteString.utf8))
            url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.onevcat.Kingfisher.ImageCache.default")
                .appendingPathComponent(name)
        }
        if let image = images.object(forKey: url as NSURL) { return image }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }
}
