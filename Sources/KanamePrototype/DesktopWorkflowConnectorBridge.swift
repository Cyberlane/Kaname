import CryptoKit
import Foundation
import KanameConnectivity

/// App-side half of the workflow connector bridge.
///
/// The Rust executor talks to `KanameWorkflowConnectorHost`, which forwards
/// `describe`, `dispatch`, and `reconcile` requests here over a Unix socket.
/// This is where Gmail credentials and the mail adapter live, so the effect is
/// performed by the app process under the channel's external-mutation policy.
/// Development denies external mutations; dispatches are then rejected with a
/// clear reason instead of silently succeeding.
final class DesktopWorkflowConnectorBridge: @unchecked Sendable {
    static let shared = DesktopWorkflowConnectorBridge()

    private let queue = DispatchQueue(label: "com.cyberlane.kaname.connector-bridge", qos: .utility)
    private var listenerDescriptor: Int32 = -1
    private var socketPath: String?
    private var environment: KanameDesktopEnvironment = .current
    private var adapter: (any MailProviderAdapter)?

    private init() {}

    func start(environment: KanameDesktopEnvironment) {
        queue.async { [self] in
            guard listenerDescriptor < 0 else { return }
            self.environment = environment
            let service = NativeGoogleIntegrationService(
                rootDirectory: environment.googleDirectory,
                keychainService: environment.googleKeychainService,
                clientConfiguration: nil,
                accessMode: environment.googleIntegrationAccessMode
            )
            adapter = GmailMailProviderAdapter(service: service)
            let path = environment.runtimeDirectory.appendingPathComponent("connector-bridge.sock").path
            try? FileManager.default.createDirectory(at: environment.runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            unlink(path)
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(descriptor); return }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in bytes.enumerated() { buffer[index] = byte }
                buffer[bytes.count] = 0
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(descriptor, 8) == 0 else { close(descriptor); return }
            chmod(path, 0o600)
            listenerDescriptor = descriptor
            socketPath = path
            Thread.detachNewThread { [self] in acceptLoop(descriptor) }
        }
    }

    func stop() {
        queue.sync {
            if listenerDescriptor >= 0 { close(listenerDescriptor) }
            listenerDescriptor = -1
            if let socketPath { unlink(socketPath) }
            socketPath = nil
        }
    }

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { break }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while request.count < 8 * 1_048_576 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            request.append(buffer, count: count)
            if request.last == 0x0A { break }
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let requestCopy = request
        Task.detached { [self] in
            box.set(await self.handle(requestCopy))
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 300)
        let response = box.get() ?? ["outcome": "not_sent", "errorCode": "connector.bridge_timeout", "summary": "The app did not answer in time."]
        var payload = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
        payload.append(0x0A)
        var sent = 0
        while sent < payload.count {
            let written = payload.withUnsafeBytes { raw -> Int in
                Foundation.write(client, raw.baseAddress!.advanced(by: sent), payload.count - sent)
            }
            guard written > 0 else { break }
            sent += written
        }
    }

    /// Hands a JSON object from the async handler back to the blocking socket thread.
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: Any]?
        func set(_ newValue: [String: Any]) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: Requests

    private static let mailActions = ["archive", "draft", "label", "mark-read", "send", "trash"]
    private static let connectorClass = "mail"
    private static var packageDigest: String {
        SHA256.hash(data: Data("kaname.connector.mail.gmail.v1".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func handle(_ line: Data) async -> [String: Any] {
        guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let mode = envelope["mode"] as? String else {
            return ["outcome": "not_sent", "errorCode": "connector.bridge_request_invalid", "summary": "Malformed bridge request."]
        }
        let request = (envelope["request"] as? [String: Any]) ?? [:]
        switch mode {
        case "describe": return await describe()
        case "dispatch": return await dispatch(request)
        case "reconcile": return await reconcile(request)
        default: return ["outcome": "not_sent", "errorCode": "connector.bridge_mode_unknown", "summary": "Unknown bridge mode \(mode)."]
        }
    }

    private func describe() async -> [String: Any] {
        guard let adapter, let accounts = try? await adapter.accounts() else { return ["connectors": [] as [Any]] }
        let connectors: [[String: Any]] = accounts.map { account in
            [
                "connectorClass": Self.connectorClass,
                "version": "1",
                "packageDigest": Self.packageDigest,
                "bindingId": "gmail:\(account.identity.localID)",
                "accountBindingId": account.identity.localID,
                "allowedActions": Self.mailActions,
                "idempotent": true,
                "supportsReconciliation": true,
            ]
        }
        return ["connectors": connectors]
    }

    private struct MailInput {
        let accountID: String
        let conversationIDs: [String]
        let addLabels: [String]
        let removeLabels: [String]
        let recipients: String
        let subject: String
        let body: String
        let inReplyTo: String?
        let references: [String]
        let conversationID: String?

        init(_ value: [String: Any], accountBindingID: String) {
            accountID = (value["accountId"] as? String) ?? accountBindingID
            conversationIDs = (value["conversationIds"] as? [String]) ?? (value["threadIds"] as? [String]) ?? []
            addLabels = (value["addLabelIds"] as? [String]) ?? (value["addResourceIds"] as? [String]) ?? []
            removeLabels = (value["removeLabelIds"] as? [String]) ?? (value["removeResourceIds"] as? [String]) ?? []
            recipients = (value["recipients"] as? String) ?? (value["to"] as? String) ?? ""
            subject = (value["subject"] as? String) ?? ""
            body = (value["body"] as? String) ?? ""
            inReplyTo = value["inReplyTo"] as? String
            references = (value["references"] as? [String]) ?? []
            conversationID = value["conversationId"] as? String
        }
    }

    private func mutation(for action: String, input: MailInput) -> MailConversationMutation? {
        switch action {
        case "archive": .archive
        case "trash": .trash
        case "mark-read": .markRead
        case "label": .applyResources(add: input.addLabels, remove: input.removeLabels)
        default: nil
        }
    }

    private func receipt(_ id: String, providerReference: String, outcome: String, evidence: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])) ?? Data()
        return [
            "receiptId": id,
            "providerReference": providerReference,
            "outcome": outcome,
            "evidenceDigest": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        ]
    }

    private func dispatch(_ request: [String: Any]) async -> [String: Any] {
        let started = Date()
        let action = (request["action"] as? String) ?? ""
        let idempotencyKey = (request["idempotencyKey"] as? String) ?? UUID().uuidString
        let accountBinding = (request["accountBindingId"] as? String) ?? ""
        let inputValue = (request["input"] as? [String: Any]) ?? [:]
        let input = MailInput(inputValue, accountBindingID: accountBinding)
        func elapsed() -> UInt64 { UInt64(Date().timeIntervalSince(started) * 1_000) }
        guard let adapter else {
            return ["outcome": "not_sent", "errorCode": "connector.unavailable", "summary": "No mail adapter is configured.", "elapsedMilliseconds": elapsed()]
        }
        guard environment.allowsExternalMutations else {
            return [
                "outcome": "rejected",
                "errorCode": "connector.channel_denies_external_mutations",
                "summary": "The \(environment.displayName) channel does not allow external mutations. Use the Candidate or Stable channel to send real effects.",
                "receipt": receipt("policy-\(idempotencyKey)", providerReference: "", outcome: "not_applied", evidence: ["policy": "denied", "channel": environment.displayName]),
                "elapsedMilliseconds": elapsed(),
            ]
        }
        guard Self.mailActions.contains(action) else {
            return ["outcome": "rejected", "errorCode": "connector.action_unsupported", "summary": "Mail connector has no action \(action).", "elapsedMilliseconds": elapsed()]
        }
        do {
            switch action {
            case "send", "draft":
                guard !input.recipients.isEmpty || action == "draft" else {
                    return ["outcome": "rejected", "errorCode": "connector.recipients_missing", "summary": "send needs recipients.", "elapsedMilliseconds": elapsed()]
                }
                let message = MailOutboundMessage(
                    recipients: input.recipients, subject: input.subject, body: input.body,
                    inReplyTo: input.inReplyTo, references: input.references, conversationID: input.conversationID
                )
                let operation: MailOutboundOperation = action == "send" ? .send : .draft
                let exactTarget = try await adapter.exactOutboundTarget(accountID: input.accountID, operation: operation, message: message)
                let outbound = try await adapter.performOutbound(
                    accountID: input.accountID, operation: operation, message: message,
                    grant: MailEffectGrant(approvalID: idempotencyKey, exactTarget: exactTarget)
                )
                return [
                    "outcome": "succeeded",
                    "receipt": receipt("gmail-\(action)-\(idempotencyKey)", providerReference: outbound.remoteID, outcome: "applied", evidence: ["remoteId": outbound.remoteID, "messageId": outbound.messageID ?? "", "action": action]),
                    "elapsedMilliseconds": elapsed(),
                ]
            default:
                guard let mutation = mutation(for: action, input: input), !input.conversationIDs.isEmpty else {
                    return ["outcome": "rejected", "errorCode": "connector.conversations_missing", "summary": "\(action) needs conversationIds.", "elapsedMilliseconds": elapsed()]
                }
                let result = await MailMutationBatchExecutor(adapter: adapter).execute(
                    accountID: input.accountID, conversationIDs: input.conversationIDs, mutation: mutation, approvalID: idempotencyKey
                )
                let evidence: [String: Any] = ["succeeded": result.succeededConversationIDs, "failures": result.failures, "action": action]
                if result.outcomeKnown, result.failures.isEmpty {
                    return ["outcome": "succeeded", "receipt": receipt("gmail-\(action)-\(idempotencyKey)", providerReference: "gmail:\(input.accountID)", outcome: "applied", evidence: evidence), "elapsedMilliseconds": elapsed()]
                }
                if result.outcomeKnown {
                    return ["outcome": "rejected", "errorCode": "connector.partial_failure", "summary": result.failures.values.joined(separator: "; "), "receipt": receipt("gmail-\(action)-\(idempotencyKey)", providerReference: "gmail:\(input.accountID)", outcome: "not_applied", evidence: evidence), "elapsedMilliseconds": elapsed()]
                }
                return ["outcome": "outcome_unknown", "errorCode": "connector.outcome_unknown", "summary": result.failures.values.joined(separator: "; "), "receipt": receipt("gmail-\(action)-\(idempotencyKey)", providerReference: "gmail:\(input.accountID)", outcome: "unknown", evidence: evidence), "elapsedMilliseconds": elapsed()]
            }
        } catch MailProviderAdapterError.approvalMismatch {
            return ["outcome": "rejected", "errorCode": "connector.approval_mismatch", "summary": "The exact target no longer matched the grant.", "elapsedMilliseconds": elapsed()]
        } catch {
            return ["outcome": "outcome_unknown", "errorCode": "connector.transport_error", "summary": error.localizedDescription, "elapsedMilliseconds": elapsed()]
        }
    }

    private func reconcile(_ request: [String: Any]) async -> [String: Any] {
        let started = Date()
        let action = (request["action"] as? String) ?? ""
        let accountBinding = (request["accountBindingId"] as? String) ?? ""
        let input = MailInput((request["input"] as? [String: Any]) ?? [:], accountBindingID: accountBinding)
        let idempotencyKey = (request["idempotencyKey"] as? String) ?? ""
        func elapsed() -> UInt64 { UInt64(Date().timeIntervalSince(started) * 1_000) }
        guard let adapter, let mutation = mutation(for: action, input: input), !input.conversationIDs.isEmpty else {
            return ["outcome": "still_unknown", "errorCode": "connector.not_reconcilable", "summary": "Only mailbox mutations can be re-read; outbound mail stays unknown until a provider reference lookup exists.", "elapsedMilliseconds": elapsed()]
        }
        let result = await MailMutationBatchExecutor(adapter: adapter).reconcile(accountID: input.accountID, conversationIDs: input.conversationIDs, mutation: mutation)
        let evidence: [String: Any] = ["succeeded": result.succeededConversationIDs, "failures": result.failures, "action": action]
        if result.failures.isEmpty {
            return ["outcome": "applied", "receipt": receipt("gmail-reconcile-\(idempotencyKey)", providerReference: "gmail:\(input.accountID)", outcome: "applied", evidence: evidence), "elapsedMilliseconds": elapsed()]
        }
        return ["outcome": "not_applied", "errorCode": "connector.postcondition_missing", "summary": result.failures.values.joined(separator: "; "), "receipt": receipt("gmail-reconcile-\(idempotencyKey)", providerReference: "gmail:\(input.accountID)", outcome: "not_applied", evidence: evidence), "elapsedMilliseconds": elapsed()]
    }
}
