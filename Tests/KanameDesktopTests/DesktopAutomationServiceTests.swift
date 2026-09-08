import Foundation
import Testing
import KanameConnectivity
@testable import KanameWorkflowHost

struct DesktopAutomationServiceTests {
    @Test("core unavailability is surfaced in the durable service health record")
    func unavailableCoreIsVisible() async throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-automation-health")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = KanameDesktopEnvironment(
            channel: .candidate, applicationSupportDirectory: root
        )
        let result = await DesktopAutomationService(environment: environment, runner: nil).runOnce()
        #expect(result == .unavailable)
        let healthURL = environment.runtimeDirectory.appendingPathComponent("automation-service-health.json")
        let data = try Data(contentsOf: healthURL)
        let health = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(health["state"] as? String == "unavailable")
    }
}
