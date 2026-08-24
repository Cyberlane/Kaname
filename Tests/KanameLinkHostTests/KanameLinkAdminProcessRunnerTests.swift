import Foundation
import Testing
@testable import KanameLinkHost

@Suite(.serialized)
struct KanameLinkAdminProcessRunnerTests {
    @Test
    func returnsOneBoundedJSONDocumentFromFixedExecutableAndArguments() async throws {
        let runner = try shellRunner(
            #"printf '%s' '{"schemaVersion":1,"requestID":"request-1","ok":true,"result":{}}'"#
        )
        let response = try await runner.execute(snapshotRequest())
        let object = try #require(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["requestID"] as? String == "request-1")
        #expect(object["ok"] as? Bool == true)
    }

    @Test
    func rejectsRequestBeforeLaunchWhenEncodedInputExceedsLimit() async throws {
        let configuration = try KanameLinkProcessRunnerConfiguration(maximumInputBytes: 1)
        let runner = try shellRunner("exit 99", configuration: configuration)

        do {
            _ = try await runner.execute(snapshotRequest())
            Issue.record("Expected bounded input rejection")
        } catch let error as KanameLinkProcessRunnerError {
            guard case let .requestTooLarge(actual, limit) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(actual > limit)
            #expect(limit == 1)
        }
    }

    @Test
    func rejectsOversizedStandardOutput() async throws {
        let configuration = try KanameLinkProcessRunnerConfiguration(maximumOutputBytes: 16)
        let runner = try shellRunner(
            "printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'",
            configuration: configuration
        )

        await #expect(throws: KanameLinkProcessRunnerError.standardOutputTooLarge(limit: 16)) {
            try await runner.execute(snapshotRequest())
        }
    }

    @Test
    func rejectsOversizedStandardErrorEvenOnZeroExit() async throws {
        let configuration = try KanameLinkProcessRunnerConfiguration(maximumErrorBytes: 8)
        let runner = try shellRunner(
            "printf 'too-much-stderr' >&2; printf '{}'",
            configuration: configuration
        )

        await #expect(throws: KanameLinkProcessRunnerError.standardErrorTooLarge(limit: 8)) {
            try await runner.execute(snapshotRequest())
        }
    }

    @Test
    func terminatesProcessAtStrictDeadline() async throws {
        let configuration = try KanameLinkProcessRunnerConfiguration(timeout: 0.05)
        let runner = try shellRunner("/bin/sleep 2", configuration: configuration)

        await #expect(throws: KanameLinkProcessRunnerError.timedOut(milliseconds: 50)) {
            try await runner.execute(snapshotRequest())
        }
    }

    @Test
    func reportsBoundedErrorForNonZeroExit() async throws {
        let runner = try shellRunner("printf 'bounded failure' >&2; exit 7")

        await #expect(
            throws: KanameLinkProcessRunnerError.nonZeroExit(
                status: 7,
                standardError: "bounded failure"
            )
        ) {
            try await runner.execute(snapshotRequest())
        }
    }

    @Test
    func leavesTypedJSONValidationToTheOperationSpecificService() async throws {
        let runner = try shellRunner("printf 'not-json'")

        let response = try await runner.execute(snapshotRequest())
        #expect(String(decoding: response, as: UTF8.self) == "not-json")
    }

    private func snapshotRequest() throws -> KanameLinkAdminRequest {
        try KanameLinkAdminRequest.hostSnapshot(requestID: "request-1")
    }

    private func shellRunner(
        _ command: String,
        configuration: KanameLinkProcessRunnerConfiguration = .standard
    ) throws -> KanameLinkAdminProcessRunner {
        try KanameLinkAdminProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            configuration: configuration
        )
    }
}
