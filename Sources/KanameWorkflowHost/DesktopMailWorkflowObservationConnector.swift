import CryptoKit
import Foundation
import KanameConnectivity
import KanameLocalCore
import KanameProtocol
import SwiftProtobuf

public protocol DesktopWorkflowConnectorObservationTransport: Sendable {
    func beginWorkflowConnectorObservation(
        _ request: Kaname_V1_BeginWorkflowConnectorObservationRequest,
        timeout: TimeInterval
    ) async throws -> Kaname_V1_BeginWorkflowConnectorObservationResponse

    func settleWorkflowConnectorObservation(
        _ request: Kaname_V1_SettleWorkflowConnectorObservationRequest,
        timeout: TimeInterval
    ) async throws -> Kaname_V1_SettleWorkflowConnectorObservationResponse
}

extension LocalCoreRunner: DesktopWorkflowConnectorObservationTransport {}

public enum DesktopMailWorkflowObservationError: Error, Equatable, Sendable {
    case invalidScope
    case malformedAuthorityResponse
    case connectorMismatch
    case resultOutOfBounds
    case providerReadFailed
}

public struct DesktopMailWorkflowObservationScope: Equatable, Sendable {
    public let runID: String
    public let runTokenID: String
    public let observationID: String
    public let accountBindingID: String
    public let bindingID: String
    public let connectorVersion: String
    public let installationDigest: String
    public let accountID: String
    public let conversationID: String
    public let selectedHeaders: [String]

    public init(
        runID: String,
        runTokenID: String,
        observationID: String,
        accountBindingID: String,
        bindingID: String,
        connectorVersion: String,
        installationDigest: String,
        accountID: String,
        conversationID: String,
        selectedHeaders: [String]
    ) {
        self.runID = runID
        self.runTokenID = runTokenID
        self.observationID = observationID
        self.accountBindingID = accountBindingID
        self.bindingID = bindingID
        self.connectorVersion = connectorVersion
        self.installationDigest = installationDigest
        self.accountID = accountID
        self.conversationID = conversationID
        self.selectedHeaders = selectedHeaders
    }
}

/// Migrates the existing mail adapter behind the durable WFP observation
/// boundary. This type has no mutation, draft, send, attachment, or body-read
/// method, and it never resolves credentials itself; an installation-private
/// adapter supplies an already bounded, non-interactive metadata read.
public struct DesktopMailWorkflowObservationConnector: Sendable {
    public static let connectorClass = "kaname.mail"
    public static let operation = "read.metadata"
    public static let maximumResultBytes = 32 * 1_024

    private let transport: any DesktopWorkflowConnectorObservationTransport
    private let adapter: any MailProviderMetadataAdapter

    public init(
        transport: any DesktopWorkflowConnectorObservationTransport,
        adapter: any MailProviderMetadataAdapter
    ) {
        self.transport = transport
        self.adapter = adapter
    }

    public func observe(
        _ scope: DesktopMailWorkflowObservationScope,
        startedAtUnixMillis: Int64,
        requestID: String
    ) async throws -> Kaname_V1_SettleWorkflowConnectorObservationResponse {
        let normalizedHeaders = try Self.normalizedHeaders(scope.selectedHeaders)
        guard Self.validIdentifier(scope.runID), Self.validIdentifier(scope.runTokenID),
              Self.validIdentifier(scope.observationID), Self.validIdentifier(scope.accountBindingID),
              Self.validIdentifier(scope.bindingID), Self.validIdentifier(scope.connectorVersion),
              Self.validOpaqueValue(scope.accountID), Self.validOpaqueValue(scope.conversationID),
              Self.validDigest(scope.installationDigest), Self.validIdentifier(requestID),
              startedAtUnixMillis >= 0 else {
            throw DesktopMailWorkflowObservationError.invalidScope
        }
        let fields = Self.observedFields(headers: normalizedHeaders)
        let requestValue = try Self.valueReference(
            id: Self.derivedValueID(kind: "request", observationID: scope.observationID),
            json: [
                "selectedHeaders": normalizedHeaders,
            ]
        )
        var registration = Kaname_V1_WorkflowConnectorObservationRegistration()
        registration.connectorClass = Self.connectorClass
        registration.accountBindingID = scope.accountBindingID
        registration.bindingID = scope.bindingID
        registration.connectorVersion = scope.connectorVersion
        registration.installationDigest = scope.installationDigest
        registration.allowedOperations = [Self.operation]
        registration.allowedFields = fields
        registration.maximumResultBytes = UInt64(Self.maximumResultBytes)
        registration.registrationDigest = try Self.registrationDigest(registration)

        var intent = Kaname_V1_WorkflowConnectorObservationIntent()
        intent.runID = scope.runID
        intent.runTokenID = scope.runTokenID
        intent.observationID = scope.observationID
        intent.connectorClass = Self.connectorClass
        intent.accountBindingID = scope.accountBindingID
        intent.operation = Self.operation
        intent.targetFingerprint = Self.targetFingerprint(
            providerID: adapter.identity.id,
            accountID: scope.accountID,
            conversationID: scope.conversationID
        )
        intent.idempotencyKey = scope.observationID
        intent.requestedFields = fields
        intent.request = requestValue

        var begin = Kaname_V1_BeginWorkflowConnectorObservationRequest()
        begin.schemaVersion = Self.schemaVersion
        begin.requestID = requestID
        begin.intent = intent
        begin.registration = registration
        begin.startedAtUnixMillis = startedAtUnixMillis
        let admission = try await transport.beginWorkflowConnectorObservation(begin, timeout: 15)
        guard admission.schemaVersion.major == Self.schemaVersion.major,
              admission.requestID == requestID, admission.hasStarted,
              admission.started.hasIntent,
              admission.started.intent == intent,
              admission.started.hasRegistration,
              admission.started.registration == registration,
              admission.started.intentDigest == Self.sha256(try intent.serializedData()),
              admission.started.deadlineUnixMillis >= startedAtUnixMillis,
              admission.storePosition > 0 else {
            throw DesktopMailWorkflowObservationError.malformedAuthorityResponse
        }
        if admission.status != "started" {
            guard admission.status == "succeeded" else {
                throw DesktopMailWorkflowObservationError.malformedAuthorityResponse
            }
            guard admission.hasSettlement else {
                throw DesktopMailWorkflowObservationError.malformedAuthorityResponse
            }
            var response = Kaname_V1_SettleWorkflowConnectorObservationResponse()
            response.schemaVersion = Self.schemaVersion
            response.requestID = "\(requestID):terminal"
            response.settlement = admission.settlement
            response.duplicate = true
            response.status = admission.status
            response.storePosition = admission.storePosition
            return response
        }

        let started = ContinuousClock.now
        do {
            let metadata = try await adapter.conversationMetadata(
                accountID: scope.accountID,
                conversationID: scope.conversationID,
                selectedHeaders: normalizedHeaders
            )
            guard metadata.id == scope.conversationID,
                  metadata.account.localID == scope.accountID,
                  metadata.account.providerID == adapter.identity.id,
                  metadata.messages.allSatisfy({
                      $0.conversationID == scope.conversationID
                          && Set($0.headers.keys).isSubset(of: Set(normalizedHeaders))
                  }) else {
                throw DesktopMailWorkflowObservationError.connectorMismatch
            }
            let output = try Self.metadataValue(
                metadata,
                observationID: scope.observationID,
                targetFingerprint: intent.targetFingerprint
            )
            guard output.byteCount <= Self.maximumResultBytes else {
                throw DesktopMailWorkflowObservationError.resultOutOfBounds
            }
            var receipt = Kaname_V1_WorkflowConnectorObservationReceipt()
            receipt.receiptID = "observation-receipt:\(Self.sha256(scope.observationID + ":" + output.sha256))"
            receipt.evidenceDigest = output.sha256
            receipt.observedFields = fields
            receipt.itemCount = UInt32(metadata.messages.count)
            receipt.resultByteCount = UInt64(output.byteCount)

            var settlement = Kaname_V1_WorkflowConnectorObservationSettled()
            settlement.runID = scope.runID
            settlement.runTokenID = scope.runTokenID
            settlement.observationID = scope.observationID
            settlement.intentDigest = admission.started.intentDigest
            settlement.outcome = .succeeded
            settlement.output = output
            settlement.receipt = receipt
            settlement.elapsedMilliseconds = Self.elapsedMilliseconds(since: started)
            settlement.idempotencyKey = scope.observationID
            return try await settle(
                settlement,
                settledAtUnixMillis: startedAtUnixMillis
                    + Int64(clamping: settlement.elapsedMilliseconds),
                requestID: "\(requestID):settle"
            )
        } catch {
            let failure = try Self.failureSettlement(
                scope: scope,
                intentDigest: admission.started.intentDigest,
                elapsedMilliseconds: Self.elapsedMilliseconds(since: started)
            )
            _ = try? await settle(
                failure,
                settledAtUnixMillis: startedAtUnixMillis
                    + Int64(clamping: failure.elapsedMilliseconds),
                requestID: "\(requestID):failed"
            )
            if let error = error as? DesktopMailWorkflowObservationError {
                throw error
            }
            throw DesktopMailWorkflowObservationError.providerReadFailed
        }
    }

    private func settle(
        _ settlement: Kaname_V1_WorkflowConnectorObservationSettled,
        settledAtUnixMillis: Int64,
        requestID: String
    ) async throws -> Kaname_V1_SettleWorkflowConnectorObservationResponse {
        var request = Kaname_V1_SettleWorkflowConnectorObservationRequest()
        request.schemaVersion = Self.schemaVersion
        request.requestID = requestID
        request.settlement = settlement
        request.settledAtUnixMillis = settledAtUnixMillis
        let response = try await transport.settleWorkflowConnectorObservation(request, timeout: 15)
        let expectedStatus = settlement.outcome == .succeeded ? "succeeded" : "failed"
        guard response.requestID == requestID, response.status == expectedStatus,
              response.hasSettlement, response.settlement == settlement else {
            throw DesktopMailWorkflowObservationError.malformedAuthorityResponse
        }
        return response
    }

    private static func failureSettlement(
        scope: DesktopMailWorkflowObservationScope,
        intentDigest: String,
        elapsedMilliseconds: UInt64
    ) throws -> Kaname_V1_WorkflowConnectorObservationSettled {
        var settlement = Kaname_V1_WorkflowConnectorObservationSettled()
        settlement.runID = scope.runID
        settlement.runTokenID = scope.runTokenID
        settlement.observationID = scope.observationID
        settlement.intentDigest = intentDigest
        settlement.outcome = .failed
        settlement.errorCode = "connector.read.failed"
        settlement.error = try valueReference(
            id: derivedValueID(kind: "error", observationID: scope.observationID),
            json: ["code": "connector.read.failed"]
        )
        settlement.elapsedMilliseconds = elapsedMilliseconds
        settlement.idempotencyKey = scope.observationID
        return settlement
    }

    private static func metadataValue(
        _ metadata: MailConversationMetadataSnapshot,
        observationID: String,
        targetFingerprint: String
    ) throws -> Kaname_V1_WorkflowValueReference {
        let messages: [[String: Any]] = metadata.messages.map { message in
            [
                "headers": message.headers,
                "idFingerprint": sha256(message.id),
                "labels": message.resourceIDs,
            ]
        }
        return try valueReference(
            id: derivedValueID(kind: "output", observationID: observationID),
            json: [
                "cursorFingerprint": metadata.cursor.map(sha256) ?? "",
                "messages": messages,
                "targetFingerprint": targetFingerprint,
            ]
        )
    }

    private static func valueReference(
        id: String,
        json: Any
    ) throws -> Kaname_V1_WorkflowValueReference {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        guard data.count <= maximumResultBytes, validIdentifier(id) else {
            throw DesktopMailWorkflowObservationError.resultOutOfBounds
        }
        var value = Kaname_V1_WorkflowValueReference()
        value.valueID = id
        value.contentType = "application/json"
        value.byteCount = UInt64(data.count)
        value.sha256 = sha256(data)
        value.inlineCanonicalJson = data
        return value
    }

    private static func registrationDigest(
        _ registration: Kaname_V1_WorkflowConnectorObservationRegistration
    ) throws -> String {
        var canonical = registration
        canonical.registrationDigest = ""
        return sha256(try canonical.serializedData())
    }

    private static func targetFingerprint(
        providerID: String,
        accountID: String,
        conversationID: String
    ) -> String {
        sha256("kaname.mail.metadata.v1\u{0}\(providerID)\u{0}\(accountID)\u{0}\(conversationID)")
    }

    private static func normalizedHeaders(_ values: [String]) throws -> [String] {
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var seen: Set<String> = []
        let normalized = trimmed.sorted(by: stableHeaderOrder).filter {
            seen.insert($0.lowercased()).inserted
        }
        guard !normalized.isEmpty, normalized.count <= 32,
              normalized.allSatisfy({ header in
                  header.range(
                      of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression
                  ) != nil
              }) else {
            throw DesktopMailWorkflowObservationError.invalidScope
        }
        return normalized
    }

    private static func stableHeaderOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.lowercased()
        let right = rhs.lowercased()
        return left == right ? lhs < rhs : left < right
    }

    private static func derivedValueID(kind: String, observationID: String) -> String {
        "observation-\(kind):\(sha256(observationID))"
    }

    private static func observedFields(headers: [String]) -> [String] {
        (["labels", "metadata"] + headers.map { "headers.\($0.lowercased())" }).sorted()
    }

    private static func elapsedMilliseconds(since instant: ContinuousClock.Instant) -> UInt64 {
        let duration = instant.duration(to: .now)
        let components = duration.components
        let milliseconds = components.seconds.saturatingMultiply(1_000)
            + components.attoseconds / 1_000_000_000_000_000
        return UInt64(clamping: max(milliseconds, 0))
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 58, 95].contains($0)
            }
    }

    private static func validOpaqueValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func sha256(_ value: String) -> String { sha256(Data(value.utf8)) }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let schemaVersion: Kaname_V1_SchemaVersion = {
        var value = Kaname_V1_SchemaVersion()
        value.major = 1
        return value
    }()
}

private extension Int64 {
    func saturatingMultiply(_ other: Int64) -> Int64 {
        let (result, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self >= 0) == (other >= 0) ? .max : .min) : result
    }
}
