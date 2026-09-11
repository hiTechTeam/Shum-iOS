import Foundation
@MainActor enum ProfileCache {
    static func clear() { ProfileImageStorage.delete() }
}
