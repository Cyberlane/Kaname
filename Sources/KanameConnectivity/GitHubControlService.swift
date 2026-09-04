import Foundation

public struct GitHubPullRequestSnapshot: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let url: String
    public let headBranch: String
    public let baseBranch: String
    public let state: String
    public let checkSummary: String
    public let reviewSummary: String
}

public struct GitHubRepositorySnapshot: Equatable, Sendable {
    public let repository: String
    public let pullRequests: [GitHubPullRequestSnapshot]
}

/// One entry from the authenticated user's GitHub notification inbox.
public struct GitHubNotificationSnapshot: Equatable, Sendable {
    public let id: String
    public let reason: String
    public let unread: Bool
    public let updatedAt: String
    public let repository: String
    public let subjectTitle: String
    public let subjectType: String
    public let subjectURL: String
}

public enum GitHubControlError: Error, Equatable, LocalizedError, Sendable {
    case invalidRepository
    case approvalMismatch
    case mergeBlocked(String)
    case malformedResponse
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository: "Choose a local repository with an authenticated GitHub remote."
        case .approvalMismatch: "The approval does not match this exact GitHub action and target."
        case let .mergeBlocked(reason): "Merge blocked: \(reason)"
        case .malformedResponse: "GitHub returned a response Kaname could not safely reconcile."
        case let .commandFailed(detail): detail
        }
    }
}

public actor GitHubControlService {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
    }

    public func inspect(repository: URL) async throws -> GitHubRepositorySnapshot {
        let root = repository.standardizedFileURL
        let repoData = try await gh(["repo", "view", "--json", "nameWithOwner"], at: root)
        let repositoryName = try JSONDecoder().decode(RepositoryIdentity.self, from: repoData).nameWithOwner
        guard Self.isRepositoryName(repositoryName) else { throw GitHubControlError.invalidRepository }
        let pullRequestData = try await gh([
            "pr", "list", "--repo", repositoryName, "--state", "all", "--limit", "100", "--json",
            "number,title,url,headRefName,baseRefName,state,mergeStateStatus,statusCheckRollup,reviews",
        ], at: root)
        return GitHubRepositorySnapshot(
            repository: repositoryName,
            pullRequests: try Self.decodePullRequests(pullRequestData)
        )
    }

    /// Lists the authenticated user's notifications (newest first). Uses the
    /// same `gh` identity as the rest of the service; nothing is marked read.
    public func notifications(unreadOnly: Bool = false, limit: Int = 50) async throws -> [GitHubNotificationSnapshot] {
        let perPage = min(max(limit, 1), 100)
        let query = "notifications?per_page=\(perPage)&all=\(unreadOnly ? "false" : "true")"
        let data = try await gh(["api", query], at: FileManager.default.homeDirectoryForCurrentUser)
        struct Wire: Decodable {
            struct Subject: Decodable {
                let title: String?
                let url: String?
                let type: String?
            }
            struct Repository: Decodable { let full_name: String? }
            let id: String
            let reason: String?
            let unread: Bool?
            let updated_at: String?
            let subject: Subject?
            let repository: Repository?
        }
        guard let items = try? JSONDecoder().decode([Wire].self, from: data) else {
            throw GitHubControlError.malformedResponse
        }
        return items.map { item in
            GitHubNotificationSnapshot(
                id: item.id,
                reason: item.reason ?? "",
                unread: item.unread ?? false,
                updatedAt: item.updated_at ?? "",
                repository: item.repository?.full_name ?? "",
                subjectTitle: item.subject?.title ?? "",
                subjectType: item.subject?.type ?? "",
                subjectURL: item.subject?.url ?? ""
            )
        }
    }

    public func createPullRequest(
        repository: String,
        localRepository: URL,
        head: String,
        base: String,
        title: String,
        body: String,
        grant: LocalGitMutationGrant
    ) async throws -> String {
        let exactTarget = Self.pullRequestTarget(repository: repository, head: head, base: base)
        guard grant.kind == .createPullRequest, grant.exactTarget == exactTarget else {
            throw GitHubControlError.approvalMismatch
        }
        guard Self.isRepositoryName(repository), Self.isBranch(head), Self.isBranch(base), !title.isEmpty else {
            throw GitHubControlError.invalidRepository
        }
        let data = try await gh([
            "pr", "create", "--repo", repository, "--head", head, "--base", base,
            "--title", String(title.prefix(256)), "--body", String(body.prefix(32_000)),
        ], at: localRepository.standardizedFileURL)
        guard let url = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), url.hasPrefix("https://") else {
            throw GitHubControlError.malformedResponse
        }
        return url
    }

    public func mergePullRequest(
        repository: String,
        number: Int,
        localRepository: URL,
        dependenciesAreMerged: Bool,
        grant: LocalGitMutationGrant
    ) async throws {
        let exactTarget = Self.mergeTarget(repository: repository, number: number)
        guard grant.kind == .mergePullRequest, grant.exactTarget == exactTarget else {
            throw GitHubControlError.approvalMismatch
        }
        guard dependenciesAreMerged else { throw GitHubControlError.mergeBlocked("a preceding stack layer is still open") }
        let readinessData = try await gh([
            "pr", "view", "--repo", repository, "\(number)", "--json", "headRefOid,statusCheckRollup,reviews",
        ], at: localRepository.standardizedFileURL)
        let readiness: MergeReadiness
        do { readiness = try JSONDecoder().decode(MergeReadiness.self, from: readinessData) }
        catch { throw GitHubControlError.malformedResponse }
        guard readiness.headRefOid.range(of: "^[0-9a-fA-F]{40,64}$", options: .regularExpression) != nil else {
            throw GitHubControlError.malformedResponse
        }
        let conclusions = readiness.statusCheckRollup.compactMap { $0.conclusion ?? $0.state }.map { $0.uppercased() }
        guard !conclusions.isEmpty,
              conclusions.allSatisfy({ ["SUCCESS", "NEUTRAL", "SKIPPED"].contains($0) }) else {
            throw GitHubControlError.mergeBlocked("required checks are absent or not green")
        }
        let reviews = readiness.reviews.map { $0.state.uppercased() }
        guard reviews.contains("APPROVED"), !reviews.contains("CHANGES_REQUESTED") else {
            throw GitHubControlError.mergeBlocked("current review state is not approved")
        }
        _ = try await gh([
            "pr", "merge", "--repo", repository, "\(number)", "--merge", "--match-head-commit",
            readiness.headRefOid,
        ], at: localRepository.standardizedFileURL)
    }

    public static func pullRequestTarget(repository: String, head: String, base: String) -> String {
        "\(repository)|\(head)->\(base)"
    }

    public static func mergeTarget(repository: String, number: Int) -> String {
        "\(repository)#\(number)"
    }

    public static func decodePullRequests(_ data: Data) throws -> [GitHubPullRequestSnapshot] {
        let payloads: [PullRequestPayload]
        do { payloads = try JSONDecoder().decode([PullRequestPayload].self, from: data) }
        catch { throw GitHubControlError.malformedResponse }
        return payloads.map { payload in
            let conclusions = payload.statusCheckRollup.compactMap { $0.conclusion ?? $0.state }.map { $0.uppercased() }
            let successful = conclusions.filter { ["SUCCESS", "NEUTRAL", "SKIPPED"].contains($0) }.count
            let checks = conclusions.isEmpty ? "No checks" : "\(successful)/\(conclusions.count) checks green"
            let decisions = payload.reviews.map { $0.state.uppercased() }
            let review = decisions.contains("CHANGES_REQUESTED") ? "Changes requested"
                : decisions.contains("APPROVED") ? "Approved"
                : "No approval"
            return GitHubPullRequestSnapshot(
                number: payload.number,
                title: payload.title,
                url: payload.url,
                headBranch: payload.headRefName,
                baseBranch: payload.baseRefName,
                state: payload.state,
                checkSummary: checks,
                reviewSummary: review
            )
        }
    }

    private func gh(_ arguments: [String], at directory: URL) async throws -> Data {
        do {
            let text = try await LocalProcess.captureSuccessfulText(
                executable: "gh",
                arguments: arguments,
                workingDirectory: directory,
                timeout: timeout,
                environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(),
                maximumOutputBytes: 2_097_152,
                preserveWhitespace: true
            )
            return Data(text.utf8)
        } catch {
            throw GitHubControlError.commandFailed(error.localizedDescription)
        }
    }

    private static func isRepositoryName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }

    private static func isBranch(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$", options: .regularExpression) != nil
            && !value.contains("..")
    }
}

private struct RepositoryIdentity: Decodable { let nameWithOwner: String }

private struct PullRequestPayload: Decodable {
    struct Check: Decodable { let conclusion: String?; let state: String? }
    struct Review: Decodable { let state: String }
    let number: Int
    let title: String
    let url: String
    let headRefName: String
    let baseRefName: String
    let state: String
    let mergeStateStatus: String?
    let statusCheckRollup: [Check]
    let reviews: [Review]
}

private struct MergeReadiness: Decodable {
    let headRefOid: String
    let statusCheckRollup: [PullRequestPayload.Check]
    let reviews: [PullRequestPayload.Review]
}
