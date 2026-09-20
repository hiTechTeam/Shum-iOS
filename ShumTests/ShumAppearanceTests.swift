import Foundation
import SwiftUI
import Testing
@testable import Shum

@Suite("System appearance")
@MainActor
struct ShumAppearanceTests {
    @Test("System Classic is the default, including existing manual theme preferences")
    func defaultFollowsSystem() throws {
        let name = "shum.tests.appearance.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("darkPink", forKey: "shum.appearance.theme")
        let store = ShumAppearanceStore(defaults: defaults)

        #expect(store.followsSystem)
        store.updateSystemColorScheme(.light)
        #expect(store.theme == .lightClassic)
        store.updateSystemColorScheme(.dark)
        #expect(store.theme == .classic)
    }

    @Test("Manual selection persists and profile reset restores system appearance")
    func manualSelectionAndReset() throws {
        let name = "shum.tests.appearance.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ShumAppearanceStore(defaults: defaults)
        store.select(.lightPink)
        store.updateSystemColorScheme(.dark)
        #expect(!store.followsSystem)
        #expect(store.theme == .lightPink)

        let restored = ShumAppearanceStore(defaults: defaults)
        #expect(!restored.followsSystem)
        #expect(restored.theme == .lightPink)
        restored.setFollowsSystem(true)
        restored.updateSystemColorScheme(.light)
        #expect(restored.theme == .lightClassic)
        restored.setFollowsSystem(false)
        #expect(restored.theme == .lightClassic)

        restored.select(.monochromeDark)
        restored.resetToClassic()
        let newProfile = ShumAppearanceStore(defaults: defaults)
        newProfile.updateSystemColorScheme(.light)
        #expect(newProfile.followsSystem)
        #expect(newProfile.theme == .lightClassic)
    }
}
