import CryptoKit
import Foundation
import KanameMobileSync
import KanameProtocol
import Testing

@Suite(.serialized)
struct HTTPMobileSyncTransportTests {
    private let now: Int64 = 1_786_220_000_000
    private let token = String(repeating: "q", count: 64)

    @Test
    func httpsSendRoutesOnlyAuthenticatedEnvelopeMetadata() async throws {
        let session = StubRelayURLProtocol.session { request in
            #expect(request.url?.absoluteString == "https://relay.example/v1/envelopes")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            let body = try #require(request.bodyData)
            let object = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            #expect(object["envelopeID"] as? String == "envelope-http-1")
            #expect(object["senderDeviceID"] as? String == "iphone-justin")
            #expect(object["recipientDeviceID"] as? String == "mac-authority")
            #expect(object["payloadKind"] as? String == "queue.enqueue")
            #expect(object.keys.sorted() == [
                "envelopeID",
                "envelopeWireBase64",
                "payloadKind",
                "recipientDeviceID",
                "senderDeviceID",
                "senderSequence",
            ])
            return StubRelayURLProtocol.json(
                status: 201,
                object: [
                    "deliveryID": "relay-delivery-4",
                    "relayPosition": 4,
                    "duplicate": false,
                    "recordedAtUnixMillis": now,
                ]
            )
        }
        let transport = try HTTPMobileSyncTransport(
            baseURL: URL(string: "https://relay.example")!,
            bearerToken: token,
            session: session
        )
        let receipt = try await transport.send(
            envelopeWire: try encryptedWire(),
            nowUnixMillis: now
        )

        #expect(receipt.deliveryID == "relay-delivery-4")
        #expect(receipt.relayPosition == 4)
        #expect(!receipt.duplicate)
    }

    @Test
    func pullDecodesExactWireAndAcknowledgementRejectsWrongAuthority() async throws {
        let wire = try encryptedWire()
        let session = StubRelayURLProtocol.session { request in
            if request.url?.path == "/v1/deliveries" {
                #expect(request.url?.query == "recipient=mac-authority&after=2&limit=10")
                return StubRelayURLProtocol.json(
                    object: [
                        "deliveries": [[
                            "deliveryID": "relay-delivery-3",
                            "relayPosition": 3,
                            "recipientDeviceID": "mac-authority",
                            "envelopeWireBase64": wire.base64EncodedString(),
                        ]],
                        "nextPosition": 3,
                        "hasMore": false,
                    ]
                )
            }
            #expect(request.url?.path == "/v1/deliveries/relay-delivery-3/ack")
            let body = try #require(request.bodyData)
            let object = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            #expect(object == ["recipientDeviceID": "mac-authority"])
            return (204, Data())
        }
        let transport = try HTTPMobileSyncTransport(
            baseURL: URL(string: "https://relay.example")!,
            bearerToken: token,
            session: session
        )

        let page = try await transport.pull(
            recipientDeviceID: "mac-authority",
            afterPosition: 2,
            limit: 10
        )
        #expect(page.deliveries.first?.envelopeWire == wire)
        try await transport.acknowledge(
            deliveryID: "relay-delivery-3",
            recipientDeviceID: "mac-authority"
        )
    }

    @Test
    func unauthorizedResponseMapsWithoutRetainingServerBody() async throws {
        let session = StubRelayURLProtocol.session { _ in
            StubRelayURLProtocol.json(status: 401, object: ["error": "unauthorized"])
        }
        let transport = try HTTPMobileSyncTransport(
            baseURL: URL(string: "https://relay.example")!,
            bearerToken: token,
            session: session
        )

        await #expect(throws: MobileSyncTransportError.unauthorized) {
            try await transport.pull(
                recipientDeviceID: "iphone-justin",
                afterPosition: 0,
                limit: 10
            )
        }
    }

    @Test
    func relayCredentialContractIsDeviceOnlyAndRejectsInvalidValues() throws {
        let service = "com.cyber-lane.kaname.relay-test-\(UUID().uuidString.lowercased())"
        let store = try KeychainMobileRelayCredentialStore(service: service)
        #expect(store.service == service)
        #expect(throws: MobileRelayCredentialStoreError.invalidToken) {
            try store.replace(token: "short")
        }

        let attributes = MobileSyncKeychainProtection.storageAttributes(
            service: service,
            account: "relay-bearer-token"
        )
        #expect(
            attributes[kSecAttrAccessible] as! CFString
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        #expect(
            !CFBooleanGetValue((attributes[kSecAttrSynchronizable] as! CFBoolean))
        )
    }

    private func encryptedWire() throws -> Data {
        let phone = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x41, count: 32)
        )
        let mac = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x42, count: 32)
        )
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        var header = Kaname_V1_SyncAuthenticatedHeader()
        header.schemaVersion = version
        header.envelopeID = "envelope-http-1"
        header.senderDeviceID = "iphone-justin"
        header.senderKeyID = "iphone-key-1"
        header.recipientDeviceID = "mac-authority"
        header.recipientKeyID = "mac-key-1"
        header.senderSequence = 1
        header.sentAtUnixMillis = now
        header.expiresAtUnixMillis = now + 60_000
        header.payloadKind = "queue.enqueue"
        header.contentType = "application/x-protobuf"
        return try MobileSyncCipher.seal(
            Data("private-body".utf8),
            header: header,
            senderPrivateKey: phone,
            recipientPublicKey: mac.publicKey,
            nowUnixMillis: now
        ).serializedData()
    }
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class StubRelayURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (status: Int, data: Data)
    nonisolated(unsafe) private static var handler: Handler?

    static func session(handler: @escaping Handler) -> URLSession {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubRelayURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func json(status: Int = 200, object: Any) -> (Int, Data) {
        (status, try! JSONSerialization.data(withJSONObject: object))
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
