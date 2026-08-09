import Foundation
import CryptoKit
import KanameLocalCore
import KanameMobileSync
import KanameProtocol

private struct Report: Encodable {
    let fixtureID: String
    let repetitions: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let failures: Int
    let mobileContractPassed: Bool

    enum CodingKeys: String, CodingKey {
        case fixtureID = "fixture_id"
        case repetitions
        case p50Milliseconds = "p50_milliseconds"
        case p95Milliseconds = "p95_milliseconds"
        case p99Milliseconds = "p99_milliseconds"
        case failures
        case mobileContractPassed = "mobile_contract_passed"
    }
}

@main
private enum KanameLocalCoreXPCMeasure {
    static func main() async {
        guard let machService = value(after: "--mach-service"),
              let requirement = value(after: "--service-requirement") else {
            FileHandle.standardError.write(Data("usage: KanameLocalCoreXPCMeasure --mach-service <name> --service-requirement <requirement>\n".utf8))
            exit(64)
        }
        let repetitions = Int(value(after: "--repetitions") ?? "25") ?? 25
        let runner = LocalCoreRunner(machService: machService, serviceRequirement: requirement)
        var samples: [Double] = []
        var failures = 0
        for _ in 0..<max(1, repetitions) {
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try await runner.runScenario("F-01")
            } catch {
                failures += 1
            }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        samples.sort()
        let mobileContractPassed: Bool
        if #available(macOS 14.0, *) {
            do {
                try await validateMobileContract(runner: runner)
                mobileContractPassed = true
            } catch {
                mobileContractPassed = false
                failures += 1
            }
        } else {
            mobileContractPassed = false
            failures += 1
        }
        let percentile: (Double) -> Double = { percent in
            samples[(Int((Double(samples.count) * percent).rounded(.up)) - 1).clamped(to: 0...(samples.count - 1))]
        }
        let report = Report(
            fixtureID: "F-01",
            repetitions: samples.count,
            p50Milliseconds: percentile(0.50),
            p95Milliseconds: percentile(0.95),
            p99Milliseconds: percentile(0.99),
            failures: failures,
            mobileContractPassed: mobileContractPassed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    @available(macOS 14.0, *)
    private static func validateMobileContract(runner: LocalCoreRunner) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let suffix = UUID().uuidString.lowercased()
        let phoneDeviceID = "iphone-fixture-\(suffix)"
        let phoneKeyID = "iphone-key-\(suffix)"
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let identity = try MobileSyncCipher.publicIdentity(
            deviceID: phoneDeviceID,
            keyID: phoneKeyID,
            displayName: "Signed XPC fixture",
            platform: "ios",
            keyGeneration: 1,
            publicKey: phoneKey.publicKey,
            createdAtUnixMillis: now,
            expiresAtUnixMillis: now + 86_400_000
        )
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        var challenge = Kaname_V1_DeviceEnrollmentChallenge()
        challenge.schemaVersion = version
        challenge.enrollmentID = "enrollment-\(suffix)"
        challenge.proposedDevice = identity
        challenge.macNonce = Data(repeating: 0x4d, count: 32)
        challenge.confirmationDigest = Data(repeating: 0x43, count: 32)
        challenge.expiresAtUnixMillis = now + 60_000
        let proposed = try await runner.proposeMobileDevice(challenge)
        guard proposed.state == .pending else { throw LocalCoreRunnerError.malformedAppendReport }

        var decision = Kaname_V1_DeviceEnrollmentDecision()
        decision.enrollmentID = challenge.enrollmentID
        decision.state = .active
        decision.macDeviceID = "mac-authority"
        decision.transcriptDigest = Data(repeating: 0x54, count: 32)
        decision.decidedAtUnixMillis = now
        let decided = try await runner.decideMobileDevice(decision)
        guard decided.state == .active else { throw LocalCoreRunnerError.malformedAppendReport }

        var header = Kaname_V1_SyncAuthenticatedHeader()
        header.schemaVersion = version
        header.envelopeID = "envelope-\(suffix)"
        header.senderDeviceID = phoneDeviceID
        header.senderKeyID = phoneKeyID
        header.recipientDeviceID = "mac-authority"
        header.recipientKeyID = "mac-key-1"
        header.senderSequence = 1
        header.sentAtUnixMillis = now
        header.expiresAtUnixMillis = now + 60_000
        header.payloadKind = "queue.enqueue"
        header.contentType = "application/x-protobuf"
        let plaintext = Data("signed-xpc-mobile-fixture".utf8)
        let envelope = try MobileSyncCipher.seal(
            plaintext,
            header: header,
            senderPrivateKey: phoneKey,
            recipientPublicKey: macKey.publicKey,
            nowUnixMillis: now
        )
        let opened = try MobileSyncCipher.open(
            envelope,
            recipientPrivateKey: macKey,
            senderPublicKey: phoneKey.publicKey,
            expectedRecipientDeviceID: "mac-authority",
            expectedRecipientKeyID: "mac-key-1",
            nowUnixMillis: now
        )
        guard opened.plaintext == plaintext else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        let receipt = try await runner.recordAuthenticatedMobileSync(envelope)
        guard receipt.state == .decrypted else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
    }

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
