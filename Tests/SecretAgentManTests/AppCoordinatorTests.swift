import Foundation
@testable import SecretAgentMan
import Testing

@MainActor
struct AppCoordinatorTests {
    @Test
    func activeSidebarPanelPersistsAndRestores() throws {
        let suiteName = "AppCoordinatorTests.sidebar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let coordinator = AppCoordinator(loadStateFromDisk: false, userDefaults: defaults)
        #expect(coordinator.activeSidebarPanel == nil)

        coordinator.activeSidebarPanel = .plans
        #expect(defaults.string(forKey: UserDefaultsKeys.activeSidebarPanel) == SidebarPanel.plans.rawValue)

        let restored = AppCoordinator(loadStateFromDisk: false, userDefaults: defaults)
        #expect(restored.activeSidebarPanel == .plans)

        restored.activeSidebarPanel = nil
        #expect(defaults.string(forKey: UserDefaultsKeys.activeSidebarPanel) == nil)
    }
}
