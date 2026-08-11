#if os(macOS)
import Darwin
#endif
import Foundation
import KanameDomain

public struct KanameConversationServiceRequest: Codable, Equatable, Sendable {
    public let runID: String
    public let threadID: String
    public let projectID: String
    public let provider: String
    public let model: String
    public let reasoningEffort: String
    public let runtimeMode: ConversationRuntimeMode
    public let networkAccess: Bool
    public let prompt: String
    public let workspacePath: String
    public let providerStatePath: String
    public let resumableNativeThreadID: String?
    public let localCoreMachService: String
    public let localCoreRequirement: String
    public let createdAtUnixMillis: Int64

    public init(
        runID: String,
        threadID: String,
        projectID: String,
        provider: String,
        model: String,
        reasoningEffort: String,
        runtimeMode: ConversationRuntimeMode = .approvalRequired,
        networkAccess: Bool = false,
        prompt: String,
        workspacePath: String,
        providerStatePath: String,
        resumableNativeThreadID: String?,
        localCoreMachService: String,
        localCoreRequirement: String,
        createdAtUnixMillis: Int64
    ) {
        (self.runID, self.threadID, self.projectID) = (runID, threadID, projectID)
        (self.provider, self.model, self.reasoningEffort) = (provider, model, reasoningEffort)
        (self.runtimeMode, self.networkAccess) = (runtimeMode, runtimeMode == .fullAccess ? true : networkAccess)
        (self.prompt, self.workspacePath, self.providerStatePath) = (prompt, workspacePath, providerStatePath)
        (self.resumableNativeThreadID, self.localCoreMachService, self.localCoreRequirement) = (
            resumableNativeThreadID, localCoreMachService, localCoreRequirement
        )
        self.createdAtUnixMillis = createdAtUnixMillis
    }

    private enum CodingKeys: String, CodingKey {
        case runID, threadID, projectID, provider, model, reasoningEffort
        case runtimeMode, networkAccess, prompt, workspacePath, providerStatePath
        case resumableNativeThreadID, localCoreMachService, localCoreRequirement, createdAtUnixMillis
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        threadID = try container.decode(String.self, forKey: .threadID)
        projectID = try container.decode(String.self, forKey: .projectID)
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        reasoningEffort = try container.decode(String.self, forKey: .reasoningEffort)
        runtimeMode = try container.decodeIfPresent(ConversationRuntimeMode.self, forKey: .runtimeMode) ?? .approvalRequired
        networkAccess = runtimeMode == .fullAccess
            ? true
            : try container.decodeIfPresent(Bool.self, forKey: .networkAccess) ?? false
        prompt = try container.decode(String.self, forKey: .prompt)
        workspacePath = try container.decode(String.self, forKey: .workspacePath)
        providerStatePath = try container.decode(String.self, forKey: .providerStatePath)
        resumableNativeThreadID = try container.decodeIfPresent(String.self, forKey: .resumableNativeThreadID)
        localCoreMachService = try container.decode(String.self, forKey: .localCoreMachService)
        localCoreRequirement = try container.decode(String.self, forKey: .localCoreRequirement)
        createdAtUnixMillis = try container.decode(Int64.self, forKey: .createdAtUnixMillis)
    }
}

public struct KanameConversationServiceEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case serviceStarted
        case provider
        case serviceFailed
    }

    public let id: String
    public let runID: String
    public let threadID: String
    public let ordinal: Int
    public let kind: Kind
    public let providerKind: CodexRunEventKind?
    public let nativeType: String
    public let nativeThreadID: String?
    public let nativeTurnID: String?
    public let approvalID: String?
    public let text: String?
    public let rawPayloadBase64: String?
    public let payloadWasTruncated: Bool
    public let createdAtUnixMillis: Int64

    public static func record(
        id: String,
        runID: String,
        threadID: String,
        ordinal: Int,
        kind: Kind,
        providerKind: CodexRunEventKind?,
        nativeType: String,
        nativeThreadID: String?,
        nativeTurnID: String?,
        approvalID: String?,
        text: String?,
        rawPayloadBase64: String?,
        payloadWasTruncated: Bool,
        createdAtUnixMillis: Int64
    ) -> Self {
        Self(
            id: id,
            runID: runID,
            threadID: threadID,
            ordinal: ordinal,
            kind: kind,
            providerKind: providerKind,
            nativeType: nativeType,
            nativeThreadID: nativeThreadID,
            nativeTurnID: nativeTurnID,
            approvalID: approvalID,
            text: text,
            rawPayloadBase64: rawPayloadBase64,
            payloadWasTruncated: payloadWasTruncated,
            createdAtUnixMillis: createdAtUnixMillis
        )
    }
}

public struct KanameConversationWorkerState: Codable, Equatable, Sendable {
    public let threadID: String
    public let runID: String?
    public let processIdentifier: Int32
    public let updatedAtUnixMillis: Int64

    public static func record(
        threadID: String,
        runID: String?,
        processIdentifier: Int32,
        updatedAtUnixMillis: Int64
    ) -> Self {
        Self(
            threadID: threadID,
            runID: runID,
            processIdentifier: processIdentifier,
            updatedAtUnixMillis: updatedAtUnixMillis
        )
    }
}

public enum KanameConversationServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier
    case requestTooLarge
    case workerUnavailable
    case launchFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "Kaname rejected an invalid conversation service identifier."
        case .requestTooLarge: "The provider request exceeded Kaname's local service boundary."
        case .workerUnavailable: "The durable conversation worker is unavailable in this build."
        case let .launchFailed(code): "Kaname could not start its durable conversation worker (\(code))."
        }
    }
}

public struct KanameConversationServiceStore: Sendable {
    public static let maximumEvidenceBytes = 16 * 1_024 * 1_024
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public func enqueue(_ request: KanameConversationServiceRequest) throws {
        try validate(request.threadID)
        try validate(request.runID)
        let data = try JSONEncoder().encode(request)
        guard data.count <= 128 * 1024 else { throw KanameConversationServiceError.requestTooLarge }
        let inbox = try privateDirectory(threadDirectory(request.threadID).appending(path: "Inbox", directoryHint: .isDirectory))
        let name = String(format: "%020lld-%@.json", request.createdAtUnixMillis, request.runID)
        try writePrivate(data, to: inbox.appending(path: name))
    }

    public func pendingRequests(threadID: String) throws -> [(URL, KanameConversationServiceRequest)] {
        try validate(threadID)
        let inbox = try privateDirectory(threadDirectory(threadID).appending(path: "Inbox", directoryHint: .isDirectory))
        return try decodedJSONFiles(in: inbox, as: KanameConversationServiceRequest.self)
    }

    public func finishRequest(at url: URL, threadID: String) throws {
        let inbox = threadDirectory(threadID).appending(path: "Inbox", directoryHint: .isDirectory).standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent() == inbox else { throw KanameConversationServiceError.invalidIdentifier }
        try FileManager.default.removeItem(at: url)
    }

    public func append(_ event: KanameConversationServiceEvent) throws {
        try validate(event.threadID)
        try validate(event.runID)
        let events = try privateDirectory(threadDirectory(event.threadID).appending(path: "Events", directoryHint: .isDirectory))
        try writePrivate(try JSONEncoder().encode(event), to: events.appending(path: "\(event.runID)-\(String(format: "%06d", event.ordinal)).json"))
    }

    public func events(threadID: String) throws -> [KanameConversationServiceEvent] {
        try validate(threadID)
        let events = try privateDirectory(threadDirectory(threadID).appending(path: "Events", directoryHint: .isDirectory))
        return try decodedJSONFiles(in: events, as: KanameConversationServiceEvent.self)
            .map(\.1)
            .sorted {
                $0.createdAtUnixMillis == $1.createdAtUnixMillis
                    ? $0.id < $1.id
                    : $0.createdAtUnixMillis < $1.createdAtUnixMillis
            }
    }

    public func acknowledge(_ event: KanameConversationServiceEvent) throws {
        try validate(event.threadID)
        try validate(event.runID)
        let events = threadDirectory(event.threadID).appending(path: "Events", directoryHint: .isDirectory)
        let filename = "\(event.runID)-\(String(format: "%06d", event.ordinal)).json"
        let url = events.appending(path: filename).standardizedFileURL
        guard url.deletingLastPathComponent() == events.standardizedFileURL else {
            throw KanameConversationServiceError.invalidIdentifier
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func appendEvidence(_ payload: Data, threadID: String, runID: String) throws {
        try validate(threadID)
        try validate(runID)
        guard !payload.isEmpty else { return }
        let url = try evidenceURL(threadID: threadID, runID: runID)
        let existingSize = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard existingSize < Self.maximumEvidenceBytes else { return }
        let retained = payload.prefix(Self.maximumEvidenceBytes - existingSize)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(retained).write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: retained)
        }
        let separator = Data("\n".utf8)
        if existingSize + retained.count < Self.maximumEvidenceBytes {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: separator)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func evidenceURL(threadID: String, runID: String) throws -> URL {
        try validate(threadID)
        try validate(runID)
        let directory = try privateDirectory(
            threadDirectory(threadID).appending(path: "Evidence", directoryHint: .isDirectory)
        )
        return directory.appending(path: "\(runID).jsonl")
    }

    public func writeWorkerState(_ state: KanameConversationWorkerState) throws {
        try validate(state.threadID)
        try writePrivate(
            try JSONEncoder().encode(state),
            to: threadDirectory(state.threadID).appending(path: "worker.json")
        )
    }

    public func workerState(threadID: String) -> KanameConversationWorkerState? {
        guard (try? validate(threadID)) != nil else { return nil }
        let url = threadDirectory(threadID).appending(path: "worker.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KanameConversationWorkerState.self, from: data)
    }

    public func isWorkerAlive(threadID: String) -> Bool {
        guard let state = workerState(threadID: threadID) else { return false }
#if os(macOS)
        return Darwin.kill(state.processIdentifier, 0) == 0
#else
        return false
#endif
    }

    public func requestInterrupt(threadID: String, runID: String) throws {
        try writeControl(threadID: threadID, runID: runID, suffix: "interrupt", payload: Data())
    }

    public func requestAnswer(threadID: String, runID: String, requestID: String, answers: [String: [String]]) throws {
        let payload = try JSONEncoder().encode(AnswerControl(requestID: requestID, answers: answers))
        try writeControl(threadID: threadID, runID: runID, suffix: "answer", payload: payload)
    }

    public func consumeInterrupt(threadID: String, runID: String) -> Bool {
        consumeControl(threadID: threadID, runID: runID, suffix: "interrupt") != nil
    }

    public func consumeAnswer(threadID: String, runID: String) -> (String, [String: [String]])? {
        guard let data = consumeControl(threadID: threadID, runID: runID, suffix: "answer"),
              let answer = try? JSONDecoder().decode(AnswerControl.self, from: data) else { return nil }
        return (answer.requestID, answer.answers)
    }

    public func workerLockURL(threadID: String) throws -> URL {
        try validate(threadID)
        return try privateDirectory(threadDirectory(threadID)).appending(path: "worker.lock")
    }

    private struct AnswerControl: Codable {
        let requestID: String
        let answers: [String: [String]]
    }

    private func decodedJSONFiles<Value: Decodable>(
        in directory: URL,
        as type: Value.Type
    ) throws -> [(URL, Value)] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let value = try? JSONDecoder().decode(type, from: data) else { return nil }
                return (url, value)
            }
    }

    private func writeControl(threadID: String, runID: String, suffix: String, payload: Data) throws {
        try validate(threadID)
        try validate(runID)
        let controls = try privateDirectory(threadDirectory(threadID).appending(path: "Controls", directoryHint: .isDirectory))
        try writePrivate(payload, to: controls.appending(path: "\(runID)-\(suffix)"))
    }

    private func consumeControl(threadID: String, runID: String, suffix: String) -> Data? {
        let url = threadDirectory(threadID).appending(path: "Controls/\(runID)-\(suffix)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }

    private func threadDirectory(_ threadID: String) -> URL {
        rootDirectory.appending(path: "Threads/\(threadID)", directoryHint: .isDirectory)
    }

    @discardableResult
    private func privateDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var current = url.standardizedFileURL
        let root = rootDirectory.standardizedFileURL
        while current.path.hasPrefix(root.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
            if current == root { break }
            current = current.deletingLastPathComponent()
        }
        return url
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        _ = try privateDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validate(_ identifier: String) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 160,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw KanameConversationServiceError.invalidIdentifier
        }
    }
}

public enum KanameConversationWorkerLauncher {
    public static func launch(executableURL: URL, storeRoot: URL, threadID: String) throws -> Int32 {
#if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw KanameConversationServiceError.workerUnavailable
        }
        let arguments = [executableURL.path, "--root", storeRoot.path, "--thread", threadID]
        let storage = arguments.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        var argv = storage + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executableURL.path, nil, nil, &argv, environ)
        guard result == 0 else { throw KanameConversationServiceError.launchFailed(result) }
        return pid
#else
        throw KanameConversationServiceError.workerUnavailable
#endif
    }
}
