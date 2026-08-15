import Foundation
import Kingfisher

@MainActor
enum ProfileCache {
    static func clear() {
        ProfileImageStorage.delete()
        URLCache.shared.removeAllCachedResponses()
        ImageCache.default.clearMemoryCache()
        ImageCache.default.clearDiskCache()
    }
}
