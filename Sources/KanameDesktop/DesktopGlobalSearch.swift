import Foundation

public enum DesktopGlobalSearchDomain: String, CaseIterable, Codable, Hashable, Sendable {
    case conversations
    case projects
    case research
    case knowledge
    case email
    case calendar
    case automations
    case github
    case skills
    case approvals
    case artifacts

    public var label: String {
        switch self {
        case .conversations: "Conversations"
        case .projects: "Projects"
        case .research: "Research"
        case .knowledge: "Knowledge"
        case .email: "Email"
        case .calendar: "Calendar"
        case .automations: "Automations"
        case .github: "GitHub"
        case .skills: "Skills & Tools"
        case .approvals: "Approvals"
        case .artifacts: "Artifacts"
        }
    }
}

public enum DesktopGlobalSearchLocalSource: String, Codable, Hashable, Sendable {
    case kanameWorkspace
    case providerSnapshot
    case obsidianSnapshot
    case gmailSnapshot
    case calendarSnapshot
    case githubSnapshot
    case localFileMetadata
}

public struct DesktopGlobalSearchProvenance: Codable, Equatable, Hashable, Sendable {
    public let source: DesktopGlobalSearchLocalSource
    public let sourceID: String
    public let sourceLabel: String
    public let scopeLabel: String?
    public let projectID: String?
    public let projectLabel: String?
    public let accountID: String?
    public let accountLabel: String?
    public let capturedAtUnixMillis: Int64?

    public static func localSnapshot(
        source: DesktopGlobalSearchLocalSource,
        sourceID: String,
        sourceLabel: String,
        scopeLabel: String? = nil,
        projectID: String? = nil,
        projectLabel: String? = nil,
        accountID: String? = nil,
        accountLabel: String? = nil,
        capturedAtUnixMillis: Int64? = nil
    ) -> Self {
        Self(
            source: source,
            sourceID: sourceID,
            sourceLabel: sourceLabel,
            scopeLabel: scopeLabel,
            projectID: projectID,
            projectLabel: projectLabel,
            accountID: accountID,
            accountLabel: accountLabel,
            capturedAtUnixMillis: capturedAtUnixMillis
        )
    }
}

public struct DesktopGlobalSearchNavigationTarget: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case conversation
        case project
        case research
        case knowledgeDocument
        case emailThread
        case calendarEvent
        case automation
        case githubWork
        case skill
        case approval
        case artifact
    }

    public let kind: Kind
    public let itemID: String
    public let scopeID: String?

    public init(kind: Kind, itemID: String, scopeID: String? = nil) {
        self.kind = kind
        self.itemID = itemID
        self.scopeID = scopeID
    }

    fileprivate var deduplicationKey: String {
        "\(kind.rawValue)\u{1f}\(scopeID ?? "")\u{1f}\(itemID)"
    }
}

public enum DesktopGlobalSearchResolvedNavigation: Equatable, Sendable {
    case conversation(String)
    case project(String)
    case knowledgeDocument(path: String)
    case scopedConversation(String)
    case destinationFallback(DesktopGlobalSearchNavigationTarget)
}

public enum DesktopGlobalSearchNavigationResolver {
    public static func resolve(
        _ target: DesktopGlobalSearchNavigationTarget,
        in snapshot: DesktopAppSnapshot
    ) -> DesktopGlobalSearchResolvedNavigation {
        switch target.kind {
        case .conversation:
            guard snapshot.threads.contains(where: { $0.id == target.itemID }) else {
                return .destinationFallback(target)
            }
            return .conversation(target.itemID)
        case .project:
            guard snapshot.projects.contains(where: { $0.id == target.itemID }) else {
                return .destinationFallback(target)
            }
            return .project(target.itemID)
        case .knowledgeDocument:
            guard snapshot.operations.knowledgeDocuments.contains(where: { $0.path == target.itemID }) else {
                return .destinationFallback(target)
            }
            return .knowledgeDocument(path: target.itemID)
        case .approval, .artifact:
            guard let threadID = target.scopeID,
                  snapshot.threads.contains(where: { $0.id == threadID }) else {
                return .destinationFallback(target)
            }
            return .scopedConversation(threadID)
        case .research, .emailThread, .calendarEvent, .automation, .githubWork, .skill:
            // These workspaces currently expose a domain surface but no durable
            // local exact-selection binding. Keeping the typed target intact lets
            // the UI disclose that fallback without guessing or reading remotely.
            return .destinationFallback(target)
        }
    }
}

public enum DesktopGlobalSearchAuthority: String, Codable, Equatable, Sendable {
    case localSnapshotOnly
}

public enum DesktopGlobalSearchPrivacyContract {
    public static let authority = DesktopGlobalSearchAuthority.localSnapshotOnly
    public static let permitsImplicitRemoteReads = false
    public static let permitsCredentialAccess = false
    public static let permitsScopeExpansion = false
}

public struct DesktopGlobalSearchIdentity: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let domain: DesktopGlobalSearchDomain
    public let navigationTarget: DesktopGlobalSearchNavigationTarget

    public init(
        id: String,
        domain: DesktopGlobalSearchDomain,
        navigationTarget: DesktopGlobalSearchNavigationTarget
    ) {
        (self.id, self.domain, self.navigationTarget) = (id, domain, navigationTarget)
    }
}

public struct DesktopGlobalSearchContent: Codable, Equatable, Sendable {
    public let title: String
    public let summary: String
    public let keywords: [String]

    public init(title: String, summary: String, keywords: [String] = []) {
        (self.title, self.summary, self.keywords) = (title, summary, keywords)
    }
}

public struct DesktopGlobalSearchDocument: Codable, Equatable, Identifiable, Sendable {
    public let identity: DesktopGlobalSearchIdentity
    public let content: DesktopGlobalSearchContent
    public let provenance: DesktopGlobalSearchProvenance
    public let updatedAtUnixMillis: Int64

    public static func localSnapshot(
        identity: DesktopGlobalSearchIdentity,
        content: DesktopGlobalSearchContent,
        provenance: DesktopGlobalSearchProvenance,
        updatedAtUnixMillis: Int64
    ) -> DesktopGlobalSearchDocument {
        DesktopGlobalSearchDocument(
            identity: identity,
            content: content,
            provenance: provenance,
            updatedAtUnixMillis: updatedAtUnixMillis
        )
    }

    public var id: String { identity.id }
    public var domain: DesktopGlobalSearchDomain { identity.domain }
    public var title: String { content.title }
    public var summary: String { content.summary }
    public var keywords: [String] { content.keywords }
    public var navigationTarget: DesktopGlobalSearchNavigationTarget { identity.navigationTarget }
}

public struct DesktopGlobalSearchLocalCorpus: Equatable, Sendable {
    public let documents: [DesktopGlobalSearchDocument]
    public let capturedAtUnixMillis: Int64
    public let authority = DesktopGlobalSearchPrivacyContract.authority
    fileprivate let indexedDocuments: [DesktopGlobalSearchIndexedDocument]

    public init(documents: [DesktopGlobalSearchDocument], capturedAtUnixMillis: Int64) {
        self.documents = documents
        self.capturedAtUnixMillis = capturedAtUnixMillis
        indexedDocuments = documents.map(DesktopGlobalSearchIndexedDocument.init)
    }
}

private struct DesktopGlobalSearchIndexedDocument: Equatable, Sendable {
    let document: DesktopGlobalSearchDocument
    let normalizedTitle: String
    let normalizedSummary: String
    let normalizedKeywords: [String]
    let normalizedProvenance: String
    let searchableText: String
    let titleWords: Set<String>
    let deduplicationKey: String
    let stableTieBreakKey: [String]

    init(document: DesktopGlobalSearchDocument) {
        self.document = document
        normalizedTitle = DesktopGlobalSearch.normalized(document.title)
        normalizedSummary = DesktopGlobalSearch.normalized(document.summary)
        normalizedKeywords = document.keywords.map(DesktopGlobalSearch.normalized)
        normalizedProvenance = DesktopGlobalSearch.normalized([
            document.provenance.source.rawValue,
            document.provenance.sourceLabel,
            document.provenance.scopeLabel,
            document.provenance.projectLabel,
            document.provenance.accountLabel,
        ].compactMap { $0 }.joined(separator: " "))
        searchableText = ([normalizedTitle, normalizedSummary, normalizedProvenance] + normalizedKeywords)
            .joined(separator: " ")
        titleWords = Set(normalizedTitle.split(whereSeparator: \Character.isWhitespace).map(String.init))
        deduplicationKey = "\(document.domain.rawValue)\u{1f}\(document.navigationTarget.deduplicationKey)"
        stableTieBreakKey = [
            document.domain.rawValue,
            document.navigationTarget.kind.rawValue,
            document.navigationTarget.scopeID ?? "",
            document.navigationTarget.itemID,
            document.title,
            document.summary,
            document.keywords.sorted().joined(separator: "\u{1f}"),
            document.provenance.source.rawValue,
            document.provenance.sourceID,
            document.provenance.sourceLabel,
            document.provenance.scopeLabel ?? "",
            document.provenance.projectID ?? "",
            document.provenance.projectLabel ?? "",
            document.provenance.accountID ?? "",
            document.provenance.accountLabel ?? "",
            document.provenance.capturedAtUnixMillis.map(String.init) ?? "",
        ]
    }
}

public struct DesktopGlobalSearchQuery: Equatable, Sendable {
    public let rawValue: String
    public let normalizedValue: String
    public let tokens: [String]
    let indexableTokens: [String]
    let indexableValue: String
    let linearTokens: [String]
    let linearValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        normalizedValue = DesktopGlobalSearch.normalized(rawValue)
        tokens = normalizedValue.split(whereSeparator: \Character.isWhitespace).map(String.init)
        indexableTokens = tokens.flatMap(DesktopGlobalSearchFTS.unicode61Tokens)
        indexableValue = indexableTokens.joined(separator: " ")
        linearTokens = indexableTokens.isEmpty ? tokens : indexableTokens
        linearValue = indexableTokens.isEmpty ? normalizedValue : indexableValue
    }

    public var isEmpty: Bool { normalizedValue.isEmpty }
}

public enum DesktopGlobalSearchMatchedField: String, Codable, Comparable, Hashable, Sendable {
    case title
    case summary
    case keywords
    case provenance

    public static func < (lhs: DesktopGlobalSearchMatchedField, rhs: DesktopGlobalSearchMatchedField) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct DesktopGlobalSearchResult: Equatable, Identifiable, Sendable {
    public let document: DesktopGlobalSearchDocument
    public let score: Int
    public let matchedFields: [DesktopGlobalSearchMatchedField]

    public var id: String { document.id }
    public var domain: DesktopGlobalSearchDomain { document.domain }
    public var provenance: DesktopGlobalSearchProvenance { document.provenance }
    public var navigationTarget: DesktopGlobalSearchNavigationTarget { document.navigationTarget }
    public var selectionID: String {
        [
            domain.rawValue,
            navigationTarget.kind.rawValue,
            navigationTarget.scopeID ?? "",
            navigationTarget.itemID,
            id,
        ].joined(separator: "\u{1f}")
    }
}

public struct DesktopGlobalSearchSection: Equatable, Identifiable, Sendable {
    public let domain: DesktopGlobalSearchDomain
    public let results: [DesktopGlobalSearchResult]

    public var id: DesktopGlobalSearchDomain { domain }
    public var title: String { domain.label }
}

public struct DesktopGlobalSearchOutput: Equatable, Sendable {
    public let sections: [DesktopGlobalSearchSection]
    public let fullTextResult: DesktopGlobalSearchFTS.MatchResult

    public init(
        sections: [DesktopGlobalSearchSection],
        fullTextResult: DesktopGlobalSearchFTS.MatchResult
    ) {
        self.sections = sections
        self.fullTextResult = fullTextResult
    }

    public var statusLine: String? {
        fullTextResult.failure?.statusLine
    }
}

public typealias DesktopGlobalSearchSelectionDirection = DesktopCyclicSelectionDirection

public struct DesktopGlobalSearchSelectionState: Equatable, Sendable {
    public private(set) var selectedResultID: String?

    public init(selectedResultID: String? = nil) {
        self.selectedResultID = selectedResultID
    }

    public mutating func reconcile(with sections: [DesktopGlobalSearchSection]) {
        let results = sections.flatMap(\.results)
        if let selectedResultID, results.contains(where: { $0.selectionID == selectedResultID }) {
            return
        }
        selectedResultID = results.first?.selectionID
    }

    public mutating func move(
        _ direction: DesktopGlobalSearchSelectionDirection,
        in sections: [DesktopGlobalSearchSection]
    ) {
        let results = sections.flatMap(\.results)
        selectedResultID = DesktopCyclicSelection.moving(
            selectedResultID,
            direction,
            in: results.map(\.selectionID)
        )
    }

    public func result(in sections: [DesktopGlobalSearchSection]) -> DesktopGlobalSearchResult? {
        guard let selectedResultID else { return nil }
        return sections.lazy.flatMap(\.results).first { $0.selectionID == selectedResultID }
    }
}

public enum DesktopGlobalSearchLocalIndex {
    public static func corpus(
        from snapshot: DesktopAppSnapshot,
        capturedAtUnixMillis: Int64? = nil,
        supplementalRows suppliedSupplementalRows: [DesktopGlobalSearchFTS.IndexedRow]? = nil
    ) -> DesktopGlobalSearchLocalCorpus {
        let capturedAt = capturedAtUnixMillis ?? snapshot.lastSavedAtUnixMillis
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
        let accounts = Dictionary(uniqueKeysWithValues: snapshot.domains.accounts.map { ($0.id, $0.displayName) })
        let supplementalRows = suppliedSupplementalRows ?? DesktopGlobalSearchFTS.supplementalRows(from: snapshot)
        var documents: [DesktopGlobalSearchDocument] = []

        for thread in snapshot.threads {
            documents.append(localDocument(
                id: "conversation:\(thread.id)",
                domain: .conversations,
                title: thread.title,
                summary: thread.summary,
                keywords: [thread.kind.label, thread.attention.label, thread.provider, thread.model],
                target: .init(kind: .conversation, itemID: thread.id, scopeID: thread.projectID),
                sourceLabel: "Kaname conversation",
                projectID: thread.projectID,
                projectLabel: thread.projectID.flatMap { projects[$0] },
                updatedAtUnixMillis: thread.updatedAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for project in snapshot.projects {
            documents.append(localDocument(
                id: "project:\(project.id)",
                domain: .projects,
                title: project.name,
                summary: project.summary,
                keywords: [project.path, project.context.defaultKind.label, project.context.defaultProvider].compactMap { $0 },
                target: .init(kind: .project, itemID: project.id),
                sourceLabel: "Kaname project",
                scopeLabel: project.archivedAtUnixMillis == nil ? "Active" : "Archived",
                projectID: project.id,
                projectLabel: project.name,
                updatedAtUnixMillis: project.archivedAtUnixMillis ?? project.createdAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for research in snapshot.domains.research {
            documents.append(localDocument(
                id: "research:\(research.id)",
                domain: .research,
                title: research.title,
                summary: research.question,
                keywords: [research.status.label, "\(research.sourceCount) sources"],
                target: .init(kind: .research, itemID: research.id),
                sourceLabel: "Kaname research",
                updatedAtUnixMillis: research.updatedAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for source in snapshot.domains.knowledgeSources {
            documents.append(localDocument(
                id: "knowledge-source:\(source.id)",
                domain: .knowledge,
                title: source.name,
                summary: source.scope,
                keywords: [source.kind.label, source.status.label],
                target: .init(kind: .knowledgeDocument, itemID: source.id),
                source: source.kind == .obsidian ? .obsidianSnapshot : .kanameWorkspace,
                sourceLabel: "\(source.kind.label) source",
                scopeLabel: source.scope,
                updatedAtUnixMillis: source.lastReadAtUnixMillis ?? capturedAt,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for document in snapshot.operations.knowledgeDocuments {
            documents.append(localDocument(
                id: "knowledge-document:\(document.path)",
                domain: .knowledge,
                title: document.title,
                summary: document.path,
                keywords: [document.role?.label, document.provenance].compactMap { $0 } + document.wikilinks,
                target: .init(kind: .knowledgeDocument, itemID: document.path, scopeID: document.projectID),
                source: .obsidianSnapshot,
                sourceID: document.path,
                sourceLabel: document.provenance,
                projectID: document.projectID,
                projectLabel: document.projectID.flatMap { projects[$0] },
                updatedAtUnixMillis: document.lastReadAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for draft in snapshot.domains.emailDrafts {
            documents.append(localDocument(
                id: "email-draft:\(draft.id)",
                domain: .email,
                title: draft.subject.isEmpty ? "Untitled email draft" : draft.subject,
                summary: draft.body,
                keywords: [draft.recipients, draft.status.label],
                target: .init(kind: .emailThread, itemID: draft.id, scopeID: draft.accountID),
                sourceLabel: "Local email draft",
                accountID: draft.accountID,
                accountLabel: draft.accountID.flatMap { accounts[$0] },
                updatedAtUnixMillis: draft.updatedAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for thread in snapshot.operations.mailAttention {
            documents.append(localDocument(
                id: "gmail-thread:\(thread.id)",
                domain: .email,
                title: thread.subject,
                summary: thread.sender,
                keywords: [thread.accountIdentity, thread.unread ? "Unread" : "Read"],
                target: .init(kind: .emailThread, itemID: thread.threadID, scopeID: thread.accountID),
                source: .gmailSnapshot,
                sourceID: thread.threadID,
                sourceLabel: "Gmail snapshot",
                accountID: thread.accountID,
                accountLabel: thread.accountIdentity,
                updatedAtUnixMillis: thread.updatedAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for proposal in snapshot.domains.calendarProposals {
            documents.append(localDocument(
                id: "calendar:\(proposal.id)",
                domain: .calendar,
                title: proposal.title,
                summary: proposal.exactTarget ?? proposal.recurrence,
                keywords: [proposal.status.label, proposal.mutationKind?.label, proposal.timeZoneIdentifier].compactMap { $0 },
                target: .init(kind: .calendarEvent, itemID: proposal.eventExternalID ?? proposal.id, scopeID: proposal.calendarSourceID),
                sourceLabel: "Kaname calendar proposal",
                accountID: proposal.accountID,
                accountLabel: proposal.accountID.flatMap { accounts[$0] },
                updatedAtUnixMillis: proposal.reconciledAtUnixMillis ?? proposal.startAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for automation in snapshot.domains.automations {
            documents.append(localDocument(
                id: "automation:\(automation.id)",
                domain: .automations,
                title: automation.name,
                summary: automation.actionSummary,
                keywords: [automation.schedule, automation.status.label, automation.authority?.label].compactMap { $0 },
                target: .init(kind: .automation, itemID: automation.id, scopeID: automation.projectID),
                sourceLabel: "Kaname automation",
                projectID: automation.projectID,
                projectLabel: automation.projectID.flatMap { projects[$0] },
                updatedAtUnixMillis: automation.createdAtUnixMillis ?? automation.nextRunAtUnixMillis ?? capturedAt,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for workspace in snapshot.domains.gitWorkspaces {
            documents.append(localDocument(
                id: "github-workspace:\(workspace.id)",
                domain: .github,
                title: workspace.name,
                summary: workspace.remoteSummary,
                keywords: [workspace.branch, workspace.localPath, workspace.status.label],
                target: .init(kind: .githubWork, itemID: workspace.id, scopeID: workspace.projectID),
                source: .githubSnapshot,
                sourceLabel: "Git workspace snapshot",
                projectID: workspace.projectID,
                projectLabel: workspace.projectID.flatMap { projects[$0] },
                updatedAtUnixMillis: capturedAt,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for request in snapshot.operations.pullRequests {
            documents.append(localDocument(
                id: "github-pr:\(request.id)",
                domain: .github,
                title: request.title,
                summary: "\(request.repository) #\(request.number)",
                keywords: [request.headBranch, request.baseBranch, request.checkSummary, request.reviewSummary, request.state.label],
                target: .init(kind: .githubWork, itemID: request.id, scopeID: request.workspaceID),
                source: .githubSnapshot,
                sourceID: request.url,
                sourceLabel: "GitHub pull request snapshot",
                updatedAtUnixMillis: request.lastReconciledAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for skill in snapshot.domains.skills {
            documents.append(localDocument(
                id: "skill:\(skill.id)",
                domain: .skills,
                title: skill.name,
                summary: skill.scope,
                keywords: [skill.kind.label, skill.source, skill.revision, skill.status.label, skill.enabled ? "Enabled" : "Disabled"],
                target: .init(kind: .skill, itemID: skill.id),
                sourceLabel: "Kaname capability registry",
                scopeLabel: skill.scope,
                updatedAtUnixMillis: capturedAt,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for approval in snapshot.operations.approvals {
            documents.append(localDocument(
                id: "approval:\(approval.id)",
                domain: .approvals,
                title: approval.title,
                summary: approval.consequence,
                keywords: [approval.exactTarget, approval.dataLeavingDevice, approval.state.label],
                target: .init(kind: .approval, itemID: approval.id, scopeID: approval.threadID),
                sourceLabel: "Kaname approval journal",
                scopeLabel: approval.threadID.flatMap { id in snapshot.threads.first(where: { $0.id == id })?.title },
                updatedAtUnixMillis: approval.requestedAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }
        for artifact in snapshot.operations.artifacts {
            documents.append(localDocument(
                id: "artifact:\(artifact.id)",
                domain: .artifacts,
                title: artifact.name,
                summary: artifact.localPath,
                keywords: [artifact.kind.label, artifact.provenance, artifact.digest],
                target: .init(kind: .artifact, itemID: artifact.id, scopeID: artifact.threadID),
                source: .localFileMetadata,
                sourceLabel: "Local artifact metadata",
                scopeLabel: artifact.threadID.flatMap { id in snapshot.threads.first(where: { $0.id == id })?.title },
                updatedAtUnixMillis: artifact.createdAtUnixMillis,
                capturedAtUnixMillis: capturedAt
            ))
        }

        documents.append(contentsOf: DesktopGlobalSearchFTS.supplementalDocuments(
            from: supplementalRows,
            projectNamesByID: projects,
            capturedAtUnixMillis: capturedAt
        ))

        return DesktopGlobalSearchLocalCorpus(documents: documents, capturedAtUnixMillis: capturedAt)
    }

    private static func localDocument(
        id: String,
        domain: DesktopGlobalSearchDomain,
        title: String,
        summary: String,
        keywords: [String],
        target: DesktopGlobalSearchNavigationTarget,
        source: DesktopGlobalSearchLocalSource = .kanameWorkspace,
        sourceID: String = "workspace",
        sourceLabel: String,
        scopeLabel: String? = nil,
        projectID: String? = nil,
        projectLabel: String? = nil,
        accountID: String? = nil,
        accountLabel: String? = nil,
        updatedAtUnixMillis: Int64,
        capturedAtUnixMillis: Int64
    ) -> DesktopGlobalSearchDocument {
        DesktopGlobalSearchDocument.localSnapshot(
            identity: DesktopGlobalSearchIdentity(id: id, domain: domain, navigationTarget: target),
            content: DesktopGlobalSearchContent(title: title, summary: summary, keywords: keywords),
            provenance: DesktopGlobalSearchProvenance.localSnapshot(
                source: source,
                sourceID: sourceID,
                sourceLabel: sourceLabel,
                scopeLabel: scopeLabel,
                projectID: projectID,
                projectLabel: projectLabel,
                accountID: accountID,
                accountLabel: accountLabel,
                capturedAtUnixMillis: capturedAtUnixMillis
            ),
            updatedAtUnixMillis: updatedAtUnixMillis
        )
    }
}

public enum DesktopGlobalSearch {
    public static let maximumResults = 200

    public static func search(
        query: DesktopGlobalSearchQuery,
        in corpus: DesktopGlobalSearchLocalCorpus,
        limit: Int = 50,
        ftsRows: [DesktopGlobalSearchFTS.IndexedRow] = []
    ) -> [DesktopGlobalSearchSection] {
        searchOutput(query: query, in: corpus, limit: limit, ftsRows: ftsRows).sections
    }

    public static func searchOutput(
        query: DesktopGlobalSearchQuery,
        in corpus: DesktopGlobalSearchLocalCorpus,
        limit: Int = 50,
        ftsRows: [DesktopGlobalSearchFTS.IndexedRow] = []
    ) -> DesktopGlobalSearchOutput {
        let boundedLimit = min(max(0, limit), maximumResults)
        let fullTextResult = DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: query,
            rows: ftsRows,
            limit: boundedLimit
        )
        return searchOutput(
            query: query,
            in: corpus,
            limit: limit,
            fullTextResult: fullTextResult
        )
    }

    static func searchOutput(
        query: DesktopGlobalSearchQuery,
        in corpus: DesktopGlobalSearchLocalCorpus,
        limit: Int = 50,
        fullTextResult: DesktopGlobalSearchFTS.MatchResult
    ) -> DesktopGlobalSearchOutput {
        guard !query.isEmpty, limit > 0 else {
            return DesktopGlobalSearchOutput(sections: [], fullTextResult: .matches([]))
        }
        if case .cancelled = fullTextResult {
            return DesktopGlobalSearchOutput(sections: [], fullTextResult: .cancelled)
        }
        let boundedLimit = min(limit, maximumResults)
        var bestByTarget: [String: DesktopGlobalSearchCandidate] = [:]
        var ftsRank: [String: Int] = [:]
        for (order, documentID) in fullTextResult.documentIDs.enumerated()
        where ftsRank[documentID] == nil {
            ftsRank[documentID] = order
        }

        for indexedDocument in corpus.indexedDocuments {
            guard var candidate = result(for: indexedDocument, query: query) else { continue }
            if let ftsOrder = ftsRank[indexedDocument.document.id] {
                candidate = DesktopGlobalSearchCandidate(
                    document: candidate.document,
                    score: candidate.score + 1_000 - ftsOrder,
                    matchedTitle: candidate.matchedTitle,
                    matchedSummary: true,
                    matchedKeywords: candidate.matchedKeywords,
                    matchedProvenance: candidate.matchedProvenance,
                    normalizedTitle: candidate.normalizedTitle,
                    stableTieBreakKey: candidate.stableTieBreakKey
                )
            }
            if let existing = bestByTarget[indexedDocument.deduplicationKey], resultPrecedes(existing, candidate) {
                continue
            }
            bestByTarget[indexedDocument.deduplicationKey] = candidate
        }

        let selected = bestByTarget.values.sorted(by: resultPrecedes).prefix(boundedLimit).map(\.result)
        let grouped = Dictionary(grouping: selected, by: \.domain)
        let sections: [DesktopGlobalSearchSection] = DesktopGlobalSearchDomain.allCases.compactMap { domain in
            guard let results = grouped[domain], !results.isEmpty else { return nil }
            return DesktopGlobalSearchSection(domain: domain, results: results)
        }
        return DesktopGlobalSearchOutput(sections: sections, fullTextResult: fullTextResult)
    }

    public static func normalized(_ value: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        return value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func result(
        for indexedDocument: DesktopGlobalSearchIndexedDocument,
        query: DesktopGlobalSearchQuery
    ) -> DesktopGlobalSearchCandidate? {
        guard query.linearTokens.allSatisfy(indexedDocument.searchableText.contains) else { return nil }

        var score = 0
        var matchedTitle = false
        var matchedSummary = false
        var matchedKeywords = false
        var matchedProvenance = false
        if indexedDocument.normalizedTitle == query.linearValue {
            score += 1_200
            matchedTitle = true
        } else if indexedDocument.normalizedTitle.hasPrefix(query.linearValue) {
            score += 900
            matchedTitle = true
        } else if indexedDocument.normalizedTitle.contains(query.linearValue) {
            score += 700
            matchedTitle = true
        }
        if indexedDocument.normalizedSummary.contains(query.linearValue) {
            score += 350
            matchedSummary = true
        }
        if indexedDocument.normalizedKeywords.contains(query.linearValue) {
            score += 500
            matchedKeywords = true
        } else if indexedDocument.normalizedKeywords.contains(where: { $0.contains(query.linearValue) }) {
            score += 250
            matchedKeywords = true
        }
        if indexedDocument.normalizedProvenance.contains(query.linearValue) {
            score += 180
            matchedProvenance = true
        }

        for token in query.linearTokens {
            if indexedDocument.titleWords.contains(token) {
                score += 160
                matchedTitle = true
            } else if indexedDocument.normalizedTitle.contains(token) {
                score += 90
                matchedTitle = true
            }
            if indexedDocument.normalizedKeywords.contains(token) {
                score += 120
                matchedKeywords = true
            } else if indexedDocument.normalizedKeywords.contains(where: { $0.contains(token) }) {
                score += 70
                matchedKeywords = true
            }
            if indexedDocument.normalizedSummary.contains(token) {
                score += 40
                matchedSummary = true
            }
            if indexedDocument.normalizedProvenance.contains(token) {
                score += 25
                matchedProvenance = true
            }
        }

        return DesktopGlobalSearchCandidate(
            document: indexedDocument.document,
            score: score,
            matchedTitle: matchedTitle,
            matchedSummary: matchedSummary,
            matchedKeywords: matchedKeywords,
            matchedProvenance: matchedProvenance,
            normalizedTitle: indexedDocument.normalizedTitle,
            stableTieBreakKey: indexedDocument.stableTieBreakKey
        )
    }

    private static func resultPrecedes(
        _ lhs: DesktopGlobalSearchCandidate,
        _ rhs: DesktopGlobalSearchCandidate
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.document.updatedAtUnixMillis != rhs.document.updatedAtUnixMillis {
            return lhs.document.updatedAtUnixMillis > rhs.document.updatedAtUnixMillis
        }
        if lhs.normalizedTitle != rhs.normalizedTitle { return lhs.normalizedTitle < rhs.normalizedTitle }
        if lhs.document.id != rhs.document.id { return lhs.document.id < rhs.document.id }
        return lhs.stableTieBreakKey.lexicographicallyPrecedes(rhs.stableTieBreakKey)
    }
}

private struct DesktopGlobalSearchCandidate {
    let document: DesktopGlobalSearchDocument
    let score: Int
    let matchedTitle: Bool
    let matchedSummary: Bool
    let matchedKeywords: Bool
    let matchedProvenance: Bool
    let normalizedTitle: String
    let stableTieBreakKey: [String]

    var result: DesktopGlobalSearchResult {
        var matchedFields: [DesktopGlobalSearchMatchedField] = []
        if matchedKeywords { matchedFields.append(.keywords) }
        if matchedProvenance { matchedFields.append(.provenance) }
        if matchedSummary { matchedFields.append(.summary) }
        if matchedTitle { matchedFields.append(.title) }
        return DesktopGlobalSearchResult(document: document, score: score, matchedFields: matchedFields)
    }
}

public struct DesktopGlobalSearchGenerationGate: Equatable, Sendable {
    public private(set) var latestGeneration: UInt64
    public private(set) var isActive: Bool

    public init(latestGeneration: UInt64 = 0, isActive: Bool = false) {
        self.latestGeneration = latestGeneration
        self.isActive = isActive
    }

    @discardableResult
    public mutating func schedule() -> UInt64 {
        latestGeneration &+= 1
        isActive = true
        return latestGeneration
    }

    public mutating func cancel() {
        latestGeneration &+= 1
        isActive = false
    }

    public func accepts(_ generation: UInt64) -> Bool {
        isActive && generation == latestGeneration
    }
}

/// Keeps the palette's reusable linear corpus and its FTS rows on one immutable
/// snapshot generation. Request generations independently reject delayed work.
public struct DesktopGlobalSearchSnapshotCoordinator: Sendable {
    public struct Schedule: Sendable {
        public let requestGeneration: UInt64
        public let snapshotGeneration: DesktopGlobalSearchFTS.SnapshotGeneration
        public let snapshotSavedAtUnixMillis: Int64
        public let cachedCorpus: DesktopGlobalSearchLocalCorpus?
    }

    private struct CachedCorpus: Sendable {
        let generation: DesktopGlobalSearchFTS.SnapshotGeneration
        let snapshotSavedAtUnixMillis: Int64
        let corpus: DesktopGlobalSearchLocalCorpus
    }

    private var gate = DesktopGlobalSearchGenerationGate()
    private var cachedCorpus: CachedCorpus?

    public init() {}

    public var latestRequestGeneration: UInt64 { gate.latestGeneration }

    public mutating func schedule(snapshot: DesktopAppSnapshot) -> Schedule {
        let snapshotGeneration = DesktopGlobalSearchFTS.snapshotGeneration(from: snapshot)
        return Schedule(
            requestGeneration: gate.schedule(),
            snapshotGeneration: snapshotGeneration,
            snapshotSavedAtUnixMillis: snapshot.lastSavedAtUnixMillis,
            cachedCorpus: cachedCorpus.flatMap {
                $0.generation == snapshotGeneration
                    && $0.snapshotSavedAtUnixMillis == snapshot.lastSavedAtUnixMillis
                    ? $0.corpus
                    : nil
            }
        )
    }

    public mutating func apply(
        corpus: DesktopGlobalSearchLocalCorpus,
        for schedule: Schedule
    ) -> Bool {
        guard gate.accepts(schedule.requestGeneration) else { return false }
        cachedCorpus = CachedCorpus(
            generation: schedule.snapshotGeneration,
            snapshotSavedAtUnixMillis: schedule.snapshotSavedAtUnixMillis,
            corpus: corpus
        )
        return true
    }

    public mutating func cancel() {
        gate.cancel()
    }
}
