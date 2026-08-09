import Foundation
import KanameProtocol

public struct HTTPMobileSyncTransport: MobileSyncTransport {
    private let client: MobileRelayHTTPClient

    public init(
        baseURL: URL,
        bearerToken: String,
        session: URLSession = .shared
    ) throws {
        self.client = try MobileRelayHTTPClient(
            baseURL: baseURL,
            bearerToken: bearerToken,
            session: session
        )
    }

    public func send(
        envelopeWire: Data,
        nowUnixMillis _: Int64
    ) async throws -> MobileRelaySendReceipt {
        let route = try MobileRelayEnvelopeRouting.route(envelopeWire)
        let request = SendEnvelopeRequest(
            envelopeID: route.envelopeID,
            senderDeviceID: route.senderDeviceID,
            recipientDeviceID: route.recipientDeviceID,
            senderSequence: route.senderSequence,
            payloadKind: route.payloadKind,
            envelopeWireBase64: envelopeWire.base64EncodedString()
        )
        let response: SendEnvelopeResponse = try await client.request(
            path: "/v1/envelopes",
            method: "POST",
            body: request
        )
        return MobileRelaySendReceipt(
            deliveryID: response.deliveryID,
            relayPosition: response.relayPosition,
            duplicate: response.duplicate,
            recordedAtUnixMillis: response.recordedAtUnixMillis
        )
    }

    public func pull(
        recipientDeviceID: String,
        afterPosition: UInt64,
        limit: Int
    ) async throws -> MobileRelayPage {
        guard MobileSyncIdentifier.isValid(recipientDeviceID) else {
            throw MobileSyncTransportError.recipientMismatch
        }
        guard limit > 0, limit <= LocalCiphertextRelay.maximumPageSize else {
            throw MobileSyncTransportError.invalidPageSize
        }
        let response: PullDeliveriesResponse = try await client.request(
            path: "/v1/deliveries",
            query: [
                URLQueryItem(name: "recipient", value: recipientDeviceID),
                URLQueryItem(name: "after", value: String(afterPosition)),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
        let deliveries = try response.deliveries.map { delivery in
            guard let wire = Data(base64Encoded: delivery.envelopeWireBase64),
                  delivery.recipientDeviceID == recipientDeviceID else {
                throw MobileSyncTransportError.invalidResponse
            }
            return MobileRelayDelivery(
                deliveryID: delivery.deliveryID,
                relayPosition: delivery.relayPosition,
                recipientDeviceID: delivery.recipientDeviceID,
                envelopeWire: wire
            )
        }
        return MobileRelayPage(
            deliveries: deliveries,
            nextPosition: response.nextPosition,
            hasMore: response.hasMore
        )
    }

    public func acknowledge(
        deliveryID: String,
        recipientDeviceID: String
    ) async throws {
        guard MobileSyncIdentifier.isValid(deliveryID),
              MobileSyncIdentifier.isValid(recipientDeviceID) else {
            throw MobileSyncTransportError.recipientMismatch
        }
        try await client.requestWithoutResponse(
            path: "/v1/deliveries/\(deliveryID)/ack",
            method: "POST",
            body: AcknowledgeDeliveryRequest(recipientDeviceID: recipientDeviceID)
        )
    }
}

public struct MobileRelayEnrollmentRecord: Equatable, Sendable {
    public let enrollmentID: String
    public let deviceID: String
    public let challengeWire: Data
    public let receiptWire: Data?
    public let state: String
    public let createdAtUnixMillis: Int64
    public let updatedAtUnixMillis: Int64
}

public struct MobileEnrollmentRelayClient: Sendable {
    private let client: MobileRelayHTTPClient

    public init(
        baseURL: URL,
        bearerToken: String,
        session: URLSession = .shared
    ) throws {
        self.client = try MobileRelayHTTPClient(
            baseURL: baseURL,
            bearerToken: bearerToken,
            session: session
        )
    }

    public func createEnrollment(_ proposal: MobileEnrollmentProposal) async throws {
        try await client.requestWithoutResponse(
            path: "/v1/enrollments",
            method: "POST",
            body: CreateEnrollmentRequest(
                enrollmentID: proposal.challenge.enrollmentID,
                deviceID: proposal.challenge.proposedDevice.deviceID,
                challengeWireBase64: try proposal.challenge.serializedData().base64EncodedString()
            )
        )
    }

    public func enrollment(enrollmentID: String) async throws -> MobileRelayEnrollmentRecord {
        guard MobileSyncIdentifier.isValid(enrollmentID) else {
            throw MobileSyncTransportError.invalidConfiguration
        }
        let response: EnrollmentResponse = try await client.request(
            path: "/v1/enrollments/\(enrollmentID)"
        )
        guard let challenge = Data(base64Encoded: response.challengeWireBase64) else {
            throw MobileSyncTransportError.invalidResponse
        }
        let receipt: Data?
        if let receiptWireBase64 = response.receiptWireBase64 {
            guard let decoded = Data(base64Encoded: receiptWireBase64) else {
                throw MobileSyncTransportError.invalidResponse
            }
            receipt = decoded
        } else {
            receipt = nil
        }
        return MobileRelayEnrollmentRecord(
            enrollmentID: response.enrollmentID,
            deviceID: response.deviceID,
            challengeWire: challenge,
            receiptWire: receipt,
            state: response.state,
            createdAtUnixMillis: response.createdAtUnixMillis,
            updatedAtUnixMillis: response.updatedAtUnixMillis
        )
    }

    public func recordEnrollmentReceipt(
        _ receipt: Kaname_V1_DeviceEnrollmentReceipt
    ) async throws {
        guard MobileSyncIdentifier.isValid(receipt.enrollmentID) else {
            throw MobileSyncTransportError.invalidConfiguration
        }
        try await client.requestWithoutResponse(
            path: "/v1/enrollments/\(receipt.enrollmentID)/receipt",
            method: "POST",
            body: EnrollmentReceiptRequest(
                state: receipt.state.relayName,
                receiptWireBase64: try receipt.serializedData().base64EncodedString()
            )
        )
    }

    public func registerPushToken(
        _ token: Data,
        deviceID: String,
        environment: String
    ) async throws {
        guard MobileSyncIdentifier.isValid(deviceID),
              !token.isEmpty,
              ["sandbox", "production"].contains(environment) else {
            throw MobileSyncTransportError.invalidConfiguration
        }
        try await client.requestWithoutResponse(
            path: "/v1/devices/\(deviceID)/push-token",
            method: "PUT",
            body: PushTokenRequest(token: token.hexString, environment: environment)
        )
    }

    public func deletePushToken(deviceID: String) async throws {
        guard MobileSyncIdentifier.isValid(deviceID) else {
            throw MobileSyncTransportError.invalidConfiguration
        }
        try await client.requestWithoutResponse(
            path: "/v1/devices/\(deviceID)/push-token",
            method: "DELETE"
        )
    }

    public func deleteQualificationData() async throws {
        try await client.requestWithoutResponse(
            path: "/v1/qualification-data",
            method: "DELETE"
        )
    }
}

struct MobileRelayHTTPClient: Sendable {
    let baseURL: URL
    let bearerToken: String
    let session: URLSession

    init(baseURL: URL, bearerToken: String, session: URLSession) throws {
        guard baseURL.scheme == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              bearerToken.utf8.count >= 32,
              bearerToken.utf8.count <= 512 else {
            throw MobileSyncTransportError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session
    }

    func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Body? = Optional<EmptyBody>.none
    ) async throws -> Response {
        let data = try await responseData(path: path, method: method, query: query, body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MobileSyncTransportError.invalidResponse
        }
    }

    func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await request(path: path, method: method, query: query, body: Optional<EmptyBody>.none)
    }

    func requestWithoutResponse<Body: Encodable>(
        path: String,
        method: String,
        body: Body? = Optional<EmptyBody>.none
    ) async throws {
        _ = try await responseData(path: path, method: method, body: body)
    }

    private func responseData<Body: Encodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Body?
    ) async throws -> Data {
        guard path.hasPrefix("/"),
              !path.contains(".."),
              var components = URLComponents(
                url: baseURL.appendingPathComponent(String(path.dropFirst())),
                resolvingAgainstBaseURL: false
              ) else {
            throw MobileSyncTransportError.invalidConfiguration
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw MobileSyncTransportError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MobileSyncTransportError.disconnected
        }
        guard let http = response as? HTTPURLResponse else {
            throw MobileSyncTransportError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) {
            return data
        }
        let code = (try? JSONDecoder().decode(RelayErrorResponse.self, from: data).error)
            ?? "http_\(http.statusCode)"
        throw mapRelayError(status: http.statusCode, code: code)
    }
}

private struct EmptyBody: Codable {}

private struct SendEnvelopeRequest: Codable {
    let envelopeID: String
    let senderDeviceID: String
    let recipientDeviceID: String
    let senderSequence: UInt64
    let payloadKind: String
    let envelopeWireBase64: String
}

private struct SendEnvelopeResponse: Codable {
    let deliveryID: String
    let relayPosition: UInt64
    let duplicate: Bool
    let recordedAtUnixMillis: Int64
}

private struct PullDeliveriesResponse: Codable {
    struct Delivery: Codable {
        let deliveryID: String
        let relayPosition: UInt64
        let recipientDeviceID: String
        let envelopeWireBase64: String
    }
    let deliveries: [Delivery]
    let nextPosition: UInt64
    let hasMore: Bool
}

private struct AcknowledgeDeliveryRequest: Codable {
    let recipientDeviceID: String
}

private struct CreateEnrollmentRequest: Codable {
    let enrollmentID: String
    let deviceID: String
    let challengeWireBase64: String
}

private struct EnrollmentResponse: Codable {
    let enrollmentID: String
    let deviceID: String
    let challengeWireBase64: String
    let receiptWireBase64: String?
    let state: String
    let createdAtUnixMillis: Int64
    let updatedAtUnixMillis: Int64
}

private struct EnrollmentReceiptRequest: Codable {
    let state: String
    let receiptWireBase64: String
}

private struct PushTokenRequest: Codable {
    let token: String
    let environment: String
}

private struct RelayErrorResponse: Codable {
    let error: String
}

private func mapRelayError(status: Int, code: String) -> MobileSyncTransportError {
    switch (status, code) {
    case (401, _): .unauthorized
    case (_, "envelope_id_reused"): .envelopeIDReused
    case (_, "invalid_cursor"): .invalidCursor
    case (_, "invalid_page_size"): .invalidPageSize
    case (_, "delivery_not_found"): .deliveryNotFound
    case (_, "recipient_mismatch"): .recipientMismatch
    case (_, "payload_too_large"), (_, "request_too_large"): .envelopeTooLarge
    default: .relayRejected(code)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Kaname_V1_DeviceEnrollmentState {
    var relayName: String {
        switch self {
        case .active: "active"
        case .rejected: "rejected"
        case .revoked: "revoked"
        default: "pending"
        }
    }
}
