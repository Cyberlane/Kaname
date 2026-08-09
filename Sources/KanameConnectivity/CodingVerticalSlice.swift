import CryptoKit
import Foundation
import KanameDomain
import KanameLocalCore
import KanameProtocol
import SwiftProtobuf

public struct CodingContextSource: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case repositoryInstructions
        case repositoryKnowledge
        case obsidian
        case searchResult
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let path: String
    public let excerpt: String
    public let sha256: String

    public init(kind: Kind, title: String, path: String, excerpt: String) {
        self.kind = kind
        self.title = title
        self.path = path
        self.excerpt = excerpt
        self.sha256 = Self.digest(Data(excerpt.utf8))
        self.id = "\(kind.rawValue):\(path):\(sha256)"
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LocalSearchMatch: Identifiable, Equatable, Sendable {
    public let path: String
    public let line: Int
    public let preview: String

    public var id: String { "\(path):\(line):\(preview)" }
}

public struct SkillRegistryEntry: Identifiable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let path: String
    public var id: String { path }
}

public struct CodingWorkspaceSnapshot: Equatable, Sendable {
    public let root: URL
    public let isIsolatedWorktree: Bool
    public let branch: String
    public let head: String
    public let revision: String
    public let status: String
    public let diffStat: String
    public let contextSources: [CodingContextSource]
    public let searchMatches: [LocalSearchMatch]
    public let skills: [SkillRegistryEntry]
}

public struct CodingEvidenceSnapshot: Equatable, Sendable {
    public let workspace: URL
    public let revision: String
    public let status: String
    public let diffStat: String
    public let diff: String
    public let diffCheckPassed: Bool
    public let verificationCommand: String
    public let verificationExitStatus: Int32
    public let verificationOutput: String
    public let verificationOutputWasTruncated: Bool
    public let artifactPaths: [String]
    public let digest: String

    public var passed: Bool {
        diffCheckPassed && verificationExitStatus == 0 && !artifactPaths.isEmpty
    }
}

public enum CodingWorkspaceInspectorError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case notRepository
    case notIsolatedWorktree

    public var errorDescription: String? {
        switch self {
        case let .unavailable(detail): detail
        case .notRepository: "The selected path is not the root of a Git repository."
        case .notIsolatedWorktree: "Phase 2 write work requires a linked isolated Git worktree."
        }
    }
}

public enum CodingWorkspaceInspector {
    public static func inspect(
        workspaceURL: URL,
        searchQuery: String = "",
        obsidianNotePath: String? = nil
    ) async throws -> CodingWorkspaceSnapshot {
        let root = workspaceURL.standardizedFileURL
        let top = try await git(["rev-parse", "--show-toplevel"], in: root)
        guard top.exitStatus == 0,
              URL(fileURLWithPath: top.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL == root else {
            throw CodingWorkspaceInspectorError.notRepository
        }

        async let headResult = git(["rev-parse", "HEAD"], in: root)
        async let branchResult = git(["branch", "--show-current"], in: root)
        async let statusResult = git(["status", "--short", "--branch"], in: root)
        async let diffStatResult = git(["diff", "--stat"], in: root)
        let (headOutput, branchOutput, statusOutput, diffStatOutput) = try await (
            headResult, branchResult, statusResult, diffStatResult
        )
        guard headOutput.exitStatus == 0,
              branchOutput.exitStatus == 0,
              statusOutput.exitStatus == 0,
              diffStatOutput.exitStatus == 0 else {
            throw CodingWorkspaceInspectorError.unavailable("Git could not inspect the selected worktree.")
        }
        let head = headOutput.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = statusOutput.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = revisionDigest(head: head, status: status)
        let contextSources = await loadContextSources(root: root, obsidianNotePath: obsidianNotePath)
        let matches = try await search(query: searchQuery, workspaceURL: root)

        return CodingWorkspaceSnapshot(
            root: root,
            isIsolatedWorktree: isLinkedWorktree(root),
            branch: branchOutput.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            head: head,
            revision: revision,
            status: status,
            diffStat: diffStatOutput.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            contextSources: contextSources,
            searchMatches: matches,
            skills: loadSkillRegistry()
        )
    }

    public static func collectEvidence(
        workspaceURL: URL,
        verificationExecutable: String = "swift",
        verificationArguments: [String] = ["test"],
        timeout: Duration = .seconds(600)
    ) async throws -> CodingEvidenceSnapshot {
        let root = workspaceURL.standardizedFileURL
        async let statusResult = git(["status", "--short", "--branch"], in: root)
        async let statResult = git(["diff", "--stat"], in: root)
        async let diffResult = git(["diff", "--no-ext-diff", "--unified=3"], in: root, maximumOutputBytes: 524_288)
        async let checkResult = git(["diff", "--check"], in: root)
        let verification = try await LocalProcess.capture(
            executable: verificationExecutable,
            arguments: verificationArguments,
            workingDirectory: root,
            timeout: timeout,
            environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(),
            maximumOutputBytes: 262_144
        )
        let (status, stat, diff, check) = try await (statusResult, statResult, diffResult, checkResult)
        let head = try await git(["rev-parse", "HEAD"], in: root)
            .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusText = status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = revisionDigest(head: head, status: statusText)
        let verificationOutput = [verification.standardOutput, verification.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let artifactPaths = changedPaths(from: statusText)
        let digestInput = [
            revision,
            statusText,
            stat.standardOutput,
            diff.standardOutput,
            "\(check.exitStatus)",
            verificationExecutable,
            verificationArguments.joined(separator: "\u{0}"),
            "\(verification.exitStatus)",
            verificationOutput,
        ].joined(separator: "\u{0}")

        return CodingEvidenceSnapshot(
            workspace: root,
            revision: revision,
            status: statusText,
            diffStat: stat.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            diff: diff.standardOutput,
            diffCheckPassed: check.exitStatus == 0,
            verificationCommand: ([verificationExecutable] + verificationArguments).joined(separator: " "),
            verificationExitStatus: verification.exitStatus,
            verificationOutput: verificationOutput,
            verificationOutputWasTruncated: verification.standardOutputWasTruncated || verification.standardErrorWasTruncated,
            artifactPaths: artifactPaths,
            digest: digest(Data(digestInput.utf8))
        )
    }

    public static func currentRevision(workspaceURL: URL) async throws -> String {
        let root = workspaceURL.standardizedFileURL
        async let headResult = git(["rev-parse", "HEAD"], in: root)
        async let statusResult = git(["status", "--short", "--branch"], in: root)
        let (head, status) = try await (headResult, statusResult)
        guard head.exitStatus == 0, status.exitStatus == 0 else {
            throw CodingWorkspaceInspectorError.unavailable("Git could not verify the approved worktree revision.")
        }
        return revisionDigest(
            head: head.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            status: status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public static func search(
        query: String,
        workspaceURL: URL
    ) async throws -> [LocalSearchMatch] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let result = try await LocalProcess.capture(
            executable: "rg",
            arguments: [
                "--json", "--max-count", "24", "--max-columns", "240",
                "--glob", "!.build/**", "--glob", "!target/**", "--", normalized, ".",
            ],
            workingDirectory: workspaceURL,
            timeout: .seconds(10),
            maximumOutputBytes: 262_144
        )
        guard result.exitStatus == 0 || result.exitStatus == 1 else {
            throw CodingWorkspaceInspectorError.unavailable("Local search failed without changing the repository.")
        }
        return result.standardOutput.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "match",
                  let payload = object["data"] as? [String: Any],
                  let path = (payload["path"] as? [String: Any])?["text"] as? String,
                  let lineNumber = payload["line_number"] as? Int,
                  let lines = (payload["lines"] as? [String: Any])?["text"] as? String else {
                return nil
            }
            return LocalSearchMatch(
                path: path.replacingOccurrences(of: "./", with: ""),
                line: lineNumber,
                preview: String(lines.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            )
        }
    }

    public static func providerPrompt(
        task: String,
        selectedSources: [CodingContextSource],
        selectedMatches: [LocalSearchMatch],
        mode: String
    ) -> String {
        let sources = selectedSources.map { source in
            "SOURCE \(source.path) SHA256 \(source.sha256)\n\(source.excerpt)"
        }.joined(separator: "\n\n")
        let matches = selectedMatches.map {
            "MATCH \($0.path):\($0.line) \($0.preview)"
        }.joined(separator: "\n")
        return """
        Kaname coding workflow mode: \(mode)

        Task:
        \(task)

        Deliberately selected context follows. Do not infer access to unrelated contexts.
        \(sources.isEmpty ? "No repository or Obsidian excerpts were selected." : sources)

        Selected local search results:
        \(matches.isEmpty ? "No local search matches were selected." : matches)
        """
    }

    public static func revisionDigest(head: String, status: String) -> String {
        "\(head):\(digest(Data(status.utf8)))"
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func git(
        _ arguments: [String],
        in root: URL,
        maximumOutputBytes: Int = 131_072
    ) async throws -> CapturedProcessOutput {
        try await LocalProcess.capture(
            executable: "git",
            arguments: arguments,
            workingDirectory: root,
            timeout: .seconds(20),
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private static func isLinkedWorktree(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = root.appending(path: ".git").path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private static func changedPaths(from status: String) -> [String] {
        status.split(separator: "\n").dropFirst().compactMap { line in
            guard line.count > 3 else { return nil }
            let path = line.dropFirst(3).split(separator: " -> ").last.map(String.init) ?? ""
            return path.isEmpty ? nil : path
        }
    }

    private static func loadContextSources(
        root: URL,
        obsidianNotePath: String?
    ) async -> [CodingContextSource] {
        var sources: [CodingContextSource] = []
        let candidates = [
            ("AGENTS.md", CodingContextSource.Kind.repositoryInstructions),
            ("lode/README.md", .repositoryKnowledge),
            ("Docs/Phase1LocalCoreEvidence.md", .repositoryKnowledge),
        ]
        for (relativePath, kind) in candidates {
            let url = root.appending(path: relativePath)
            guard let excerpt = boundedText(at: url, maximumBytes: 32_768) else { continue }
            sources.append(CodingContextSource(
                kind: kind,
                title: url.lastPathComponent,
                path: relativePath,
                excerpt: excerpt
            ))
        }
        if let obsidianNotePath, !obsidianNotePath.isEmpty,
           let result = try? await LocalProcess.capture(
                executable: "obsidian",
                arguments: ["read", "path=\(obsidianNotePath)"],
                workingDirectory: root,
                timeout: .seconds(10),
                maximumOutputBytes: 32_768
           ), result.exitStatus == 0, !result.standardOutput.isEmpty {
            sources.append(CodingContextSource(
                kind: .obsidian,
                title: URL(fileURLWithPath: obsidianNotePath).lastPathComponent,
                path: "obsidian:\(obsidianNotePath)",
                excerpt: result.standardOutput
            ))
        }
        return sources
    }

    private static func boundedText(at url: URL, maximumBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func loadSkillRegistry() -> [SkillRegistryEntry] {
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/skills"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agents/skills"),
        ]
        var entries: [SkillRegistryEntry] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
                guard entries.count < 100,
                      let text = boundedText(at: url, maximumBytes: 8_192) else { continue }
                let name = frontmatterValue("name", in: text) ?? url.deletingLastPathComponent().lastPathComponent
                let description = frontmatterValue("description", in: text) ?? "No compact description available."
                entries.append(SkillRegistryEntry(name: name, description: description, path: url.path))
            }
        }
        return Dictionary(grouping: entries, by: \.name)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func frontmatterValue(_ key: String, in text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        for line in text.split(separator: "\n").dropFirst().prefix(while: { $0 != "---" }) {
            let prefix = "\(key):"
            guard line.hasPrefix(prefix) else { continue }
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}

public struct CodexWorkspaceAuthorization: Equatable, Sendable {
    public let approvalID: String
    public let workspace: URL
    public let targetRevision: String
    public let promptDigest: String
    public let model: String
    public let reasoningEffort: String
    public let fingerprint: Data
    public let expiresAt: Date
    public let storePosition: UInt64

    func validates(request: CodexCodingRequest, workspaceURL: URL, now: Date = Date()) -> Bool {
        workspace.standardizedFileURL == workspaceURL.standardizedFileURL
            && promptDigest == CodingWorkspaceInspector.digest(Data(request.prompt.utf8))
            && model == request.model
            && reasoningEffort == request.reasoningEffort
            && expiresAt > now
            && !fingerprint.isEmpty
            && storePosition > 0
    }
}

public enum Phase2ControlPlane {
    public static func authorizeWorkspaceWrite(
        runner: LocalCoreRunner,
        projectID: String,
        threadID: String,
        workspace: CodingWorkspaceSnapshot,
        request: CodexCodingRequest,
        actorID: String = "codex-authorized-by-justin",
        now: Date = Date()
    ) async throws -> CodexWorkspaceAuthorization {
        guard workspace.isIsolatedWorktree else {
            throw CodingWorkspaceInspectorError.notIsolatedWorktree
        }
        let approvalID = "approval-\(UUID().uuidString.lowercased())"
        let promptDigest = CodingWorkspaceInspector.digest(Data(request.prompt.utf8))
        var scope = Kaname_V1_Scope()
        scope.projectID = projectID
        scope.workspaceID = workspace.root.path
        scope.authorityID = "local-user"
        scope.egressClass = "provider_and_workspace"
        scope.destinationDigest = CodingWorkspaceInspector.digest(
            Data("codex:\(request.model):\(request.reasoningEffort)".utf8)
        )
        var approvalRequest = Kaname_V1_ApprovalRequest()
        approvalRequest.approvalID = approvalID
        approvalRequest.actionKind = "codex.workspace_write"
        approvalRequest.scope = scope
        approvalRequest.targetID = workspace.root.path
        approvalRequest.targetRevision = workspace.revision
        approvalRequest.effectDigest = Data(hex: promptDigest) ?? Data()
        approvalRequest.consequence = "Allow one network-denied Codex turn to make recoverable changes only inside this isolated worktree."
        approvalRequest.reversible = true
        approvalRequest.expiresAtUnixMillis = Int64(now.addingTimeInterval(15 * 60).timeIntervalSince1970 * 1_000)
        approvalRequest.policyReference = "phase2-explicit-isolated-worktree"
        approvalRequest.approvalPayloadVersion = 1
        approvalRequest.fingerprint = approvalFingerprint(approvalRequest)

        var resolution = Kaname_V1_ApprovalResolution()
        resolution.approvalID = approvalID
        resolution.decision = .approve
        resolution.expectedFingerprint = approvalRequest.fingerprint
        resolution.actorID = actorID
        resolution.deviceID = "local-mac"

        var command = Kaname_V1_ApprovalCommand()
        command.streamID = "thread:project:\(projectID):\(threadID)"
        command.request = approvalRequest
        command.resolution = resolution
        command.resolvedAtUnixMillis = Int64(now.timeIntervalSince1970 * 1_000)
        command.currentTargetRevision = workspace.revision
        let receipt = try await runner.authorizeAction(command)
        guard receipt.approvalID == approvalID,
              receipt.decision == .approve,
              receipt.fingerprint == approvalRequest.fingerprint else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return CodexWorkspaceAuthorization(
            approvalID: approvalID,
            workspace: workspace.root,
            targetRevision: workspace.revision,
            promptDigest: promptDigest,
            model: request.model,
            reasoningEffort: request.reasoningEffort,
            fingerprint: approvalRequest.fingerprint,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(approvalRequest.expiresAtUnixMillis) / 1_000),
            storePosition: receipt.storePosition
        )
    }

    public static func recordReview(
        runner: LocalCoreRunner,
        projectID: String,
        threadID: String,
        workspace: URL,
        evidence: CodingEvidenceSnapshot,
        accepted: Bool,
        knowledgeUpdateProposal: String,
        actorID: String = "codex-authorized-by-justin",
        now: Date = Date()
    ) async throws -> Kaname_V1_CommandOutcome {
        let streamID = "thread:project:\(projectID):\(threadID)"
        var replayRequest = Kaname_V1_ReplayRequest()
        replayRequest.selectorID = "thread:\(streamID)"
        replayRequest.pageSize = 1
        let replay = try await runner.replay(replayRequest)

        var review = Kaname_V1_ReviewDecision()
        review.streamID = streamID
        review.evidenceDigest = Data(hex: evidence.digest) ?? Data()
        review.accepted = accepted
        review.knowledgeUpdateProposal = String(knowledgeUpdateProposal.prefix(16_384))
        var payload = Kaname_V1_OpaqueTypedPayload()
        payload.typeURL = "kaname.review.decision.v1"
        payload.contentType = "application/x-protobuf"
        payload.value = try review.serializedData()
        payload.payloadVersion = 1
        var scope = Kaname_V1_Scope()
        scope.projectID = projectID
        scope.workspaceID = workspace.standardizedFileURL.path
        scope.authorityID = "local-user"
        scope.egressClass = "local_review"
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        let commandID = "review-\(UUID().uuidString.lowercased())"
        var command = Kaname_V1_CommandEnvelope()
        command.schemaVersion = version
        command.commandID = commandID
        command.idempotencyKey = commandID
        command.kind = accepted ? "review.accept" : "review.reject"
        command.payload = payload
        command.scope = scope
        command.actorID = actorID
        command.expectedRevision = replay.highWaterMark
        command.submittedAtUnixMillis = Int64(now.timeIntervalSince1970 * 1_000)
        return try await runner.recordReview(command)
    }

    static func approvalFingerprint(_ request: Kaname_V1_ApprovalRequest) -> Data {
        var data = Data("kaname.approval.fingerprint.v1\0".utf8)
        data.append(bigEndian: request.approvalPayloadVersion)
        data.append(Data(request.actionKind.utf8))
        let scope = request.scope
        for value in [
            scope.projectID, scope.workspaceID, scope.accountID,
            scope.authorityID, scope.egressClass, scope.destinationDigest,
        ] {
            data.append(Data(value.utf8))
            data.append(0)
        }
        data.append(Data(request.targetID.utf8))
        data.append(Data(request.targetRevision.utf8))
        data.append(request.effectDigest)
        data.append(Data(request.consequence.utf8))
        data.append(request.reversible ? 1 : 0)
        data.append(bigEndian: request.expiresAtUnixMillis)
        data.append(Data(request.policyReference.utf8))
        return Data(SHA256.hash(data: data))
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }

    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
