import Foundation
import Testing
@testable import KanameDesktop

struct DesktopGlobalSearchTests {
    @Test
    func queryNormalizationIsCaseWidthDiacriticAndWhitespaceInsensitive() {
        let query = DesktopGlobalSearchQuery("  ＲÉSUMÉ\n   Review  ")

        #expect(query.normalizedValue == "resume review")
        #expect(query.tokens == ["resume", "review"])
    }

    @Test
    func searchUsesOnlyAnExplicitLocalSnapshotCorpus() {
        let corpus = DesktopGlobalSearchLocalCorpus(documents: [], capturedAtUnixMillis: 1_000)

        #expect(corpus.authority == .localSnapshotOnly)
        #expect(DesktopGlobalSearchPrivacyContract.authority == .localSnapshotOnly)
        #expect(!DesktopGlobalSearchPrivacyContract.permitsImplicitRemoteReads)
        #expect(!DesktopGlobalSearchPrivacyContract.permitsCredentialAccess)
        #expect(!DesktopGlobalSearchPrivacyContract.permitsScopeExpansion)
    }

    @Test
    func localIndexBuildsCrossDomainDocumentsWithoutReadingOutsideTheSnapshot() throws {
        let snapshot = DesktopAppSnapshot.starter(now: 1_000)
        let corpus = DesktopGlobalSearchLocalIndex.corpus(
            from: snapshot,
            capturedAtUnixMillis: 2_000
        )

        #expect(corpus.authority == .localSnapshotOnly)
        #expect(corpus.capturedAtUnixMillis == 2_000)
        #expect(corpus.documents.allSatisfy { $0.provenance.capturedAtUnixMillis == 2_000 })
        #expect(Set(corpus.documents.map(\.domain)).isSuperset(of: [.conversations, .projects, .knowledge, .skills]))
        let project = try #require(corpus.documents.first { $0.id == "project:project-kaname" })
        #expect(project.navigationTarget == .init(kind: .project, itemID: "project-kaname"))
        #expect(project.provenance.source == .kanameWorkspace)
        #expect(project.provenance.projectLabel == "Kaname")
    }

    @Test
    func exactTitleOutranksSummaryAndInputOrderDoesNotMatter() throws {
        let exact = document(
            id: "exact",
            domain: .projects,
            title: "Recovery Plan",
            summary: "Desktop resilience",
            target: .init(kind: .project, itemID: "project-recovery"),
            updatedAt: 1_000
        )
        let summary = document(
            id: "summary",
            domain: .projects,
            title: "Desktop hardening",
            summary: "Review the recovery plan",
            target: .init(kind: .project, itemID: "project-hardening"),
            updatedAt: 2_000
        )
        let query = DesktopGlobalSearchQuery("recovery plan")

        let forward = DesktopGlobalSearch.search(
            query: query,
            in: .init(documents: [summary, exact], capturedAtUnixMillis: 3_000)
        ).flatMap(\.results)
        let reversed = DesktopGlobalSearch.search(
            query: query,
            in: .init(documents: [exact, summary], capturedAtUnixMillis: 3_000)
        ).flatMap(\.results)

        #expect(forward.map(\.id) == ["exact", "summary"])
        #expect(reversed.map(\.id) == forward.map(\.id))
        #expect(try #require(forward.first).matchedFields.contains(.title))
    }

    @Test
    func logicalTargetsDeduplicateToTheStrongestStableResult() {
        let target = DesktopGlobalSearchNavigationTarget(
            kind: .emailThread,
            itemID: "gmail-thread-7",
            scopeID: "account-one"
        )
        let weaker = document(
            id: "cache-old",
            domain: .email,
            title: "Weekly status",
            summary: "Contains the project atlas update",
            target: target,
            updatedAt: 2_000,
            source: .gmailSnapshot
        )
        let stronger = document(
            id: "cache-new",
            domain: .email,
            title: "Project Atlas",
            summary: "Weekly status",
            target: target,
            updatedAt: 1_000,
            source: .gmailSnapshot
        )

        let results = DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("project atlas"),
            in: .init(documents: [weaker, stronger], capturedAtUnixMillis: 3_000)
        ).flatMap(\.results)

        #expect(results.map(\.id) == ["cache-new"])
    }

    @Test
    func tiedDuplicateSnapshotsResolveIndependentlyOfInputOrder() throws {
        let target = DesktopGlobalSearchNavigationTarget(kind: .project, itemID: "project-atlas")
        let alpha = document(
            id: "atlas",
            domain: .projects,
            title: "Project Atlas",
            summary: "Alpha local detail",
            target: target,
            updatedAt: 1_000
        )
        let zulu = document(
            id: "atlas",
            domain: .projects,
            title: "Project Atlas",
            summary: "Zulu local detail",
            target: target,
            updatedAt: 1_000
        )
        let query = DesktopGlobalSearchQuery("project atlas")

        let forward = DesktopGlobalSearch.search(
            query: query,
            in: .init(documents: [zulu, alpha], capturedAtUnixMillis: 2_000)
        )
        let reversed = DesktopGlobalSearch.search(
            query: query,
            in: .init(documents: [alpha, zulu], capturedAtUnixMillis: 2_000)
        )

        #expect(try #require(forward.first?.results.first).document.summary == "Alpha local detail")
        #expect(reversed == forward)
    }

    @Test
    func keyboardSelectionReconcilesAndWrapsAcrossGroups() throws {
        let documents = [
            document(
                id: "project",
                domain: .projects,
                title: "Kaname project",
                summary: "Local workspace",
                target: .init(kind: .project, itemID: "project-kaname"),
                updatedAt: 2_000
            ),
            document(
                id: "email",
                domain: .email,
                title: "Kaname email",
                summary: "Local snapshot",
                target: .init(kind: .emailThread, itemID: "thread-1", scopeID: "account-1"),
                updatedAt: 1_000,
                source: .gmailSnapshot
            ),
        ]
        let sections = DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("kaname"),
            in: .init(documents: documents, capturedAtUnixMillis: 3_000)
        )
        var selection = DesktopGlobalSearchSelectionState()

        selection.reconcile(with: sections)
        #expect(selection.result(in: sections)?.id == "project")
        selection.move(.next, in: sections)
        #expect(selection.result(in: sections)?.id == "email")
        selection.move(.next, in: sections)
        #expect(selection.result(in: sections)?.id == "project")
        selection.move(.previous, in: sections)
        #expect(selection.result(in: sections)?.id == "email")

        selection.reconcile(with: [])
        #expect(selection.selectedResultID == nil)
        #expect(selection.result(in: []) == nil)
    }

    @Test
    func theSameExternalIDInDifferentAccountsRemainsIsolated() {
        let documents = ["account-one", "account-two"].map { accountID in
            document(
                id: accountID,
                domain: .email,
                title: "Project Atlas",
                summary: "Account-scoped message",
                target: .init(kind: .emailThread, itemID: "gmail-thread-7", scopeID: accountID),
                updatedAt: 1_000,
                source: .gmailSnapshot
            )
        }

        let results = DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("project atlas"),
            in: .init(documents: documents, capturedAtUnixMillis: 2_000)
        ).flatMap(\.results)

        #expect(results.map(\.id) == ["account-one", "account-two"])
        #expect(Set(results.compactMap { $0.navigationTarget.scopeID }) == ["account-one", "account-two"])
    }

    @Test
    func sectionsKeepDomainOrderProvenanceAndExactNavigation() throws {
        let emailTarget = DesktopGlobalSearchNavigationTarget(
            kind: .emailThread,
            itemID: "thread-1",
            scopeID: "account-1"
        )
        let email = document(
            id: "email",
            domain: .email,
            title: "Kaname release",
            summary: "Release follow-up",
            target: emailTarget,
            updatedAt: 2_000,
            source: .gmailSnapshot,
            sourceLabel: "Gmail · Work"
        )
        let project = document(
            id: "project",
            domain: .projects,
            title: "Kaname",
            summary: "Local-first release work",
            target: .init(kind: .project, itemID: "project-kaname"),
            updatedAt: 1_000
        )

        let sections = DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("kaname"),
            in: .init(documents: [email, project], capturedAtUnixMillis: 3_000)
        )

        #expect(sections.map(\.domain) == [.projects, .email])
        let emailResult = try #require(sections.last?.results.first)
        #expect(emailResult.provenance.source == .gmailSnapshot)
        #expect(emailResult.provenance.sourceLabel == "Gmail · Work")
        #expect(emailResult.navigationTarget == emailTarget)
    }

    @Test
    func navigationResolverKeepsExactLocalSelectionsAndTypedFallbacks() throws {
        var snapshot = DesktopAppSnapshot.starter(now: 1_000)
        let document = DesktopKnowledgeDocumentRecord(
            path: "/vault/Plan.md",
            title: "Plan",
            digest: "digest-plan",
            provenance: "Obsidian",
            lastReadAtUnixMillis: 1_000
        )
        snapshot.operations.knowledgeDocuments = [document]
        let conversationID = try #require(snapshot.threads.first?.id)
        let projectID = try #require(snapshot.projects.first?.id)

        #expect(DesktopGlobalSearchNavigationResolver.resolve(
            .init(kind: .conversation, itemID: conversationID),
            in: snapshot
        ) == .conversation(conversationID))
        #expect(DesktopGlobalSearchNavigationResolver.resolve(
            .init(kind: .project, itemID: projectID),
            in: snapshot
        ) == .project(projectID))
        #expect(DesktopGlobalSearchNavigationResolver.resolve(
            .init(kind: .knowledgeDocument, itemID: document.path),
            in: snapshot
        ) == .knowledgeDocument(path: document.path))

        let emailTarget = DesktopGlobalSearchNavigationTarget(
            kind: .emailThread,
            itemID: "thread-7",
            scopeID: "account-one"
        )
        #expect(DesktopGlobalSearchNavigationResolver.resolve(emailTarget, in: snapshot)
            == .destinationFallback(emailTarget))
    }

    @Test
    func generationGateRejectsStaleAndCancelledSearchResults() {
        var gate = DesktopGlobalSearchGenerationGate()

        let first = gate.schedule()
        #expect(gate.accepts(first))
        let second = gate.schedule()
        #expect(!gate.accepts(first))
        #expect(gate.accepts(second))

        gate.cancel()
        #expect(!gate.accepts(second))
        let resumed = gate.schedule()
        #expect(gate.accepts(resumed))
    }

    @Test
    func everyQueryTokenMustMatchAndLimitsAreBounded() {
        let matching = document(
            id: "matching",
            domain: .knowledge,
            title: "Authority boundary",
            summary: "Local snapshot provenance",
            target: .init(kind: .knowledgeDocument, itemID: "note-1"),
            updatedAt: 1_000,
            source: .obsidianSnapshot
        )
        let partial = document(
            id: "partial",
            domain: .knowledge,
            title: "Authority",
            summary: "No other term",
            target: .init(kind: .knowledgeDocument, itemID: "note-2"),
            updatedAt: 2_000,
            source: .obsidianSnapshot
        )
        let corpus = DesktopGlobalSearchLocalCorpus(
            documents: [matching, partial],
            capturedAtUnixMillis: 3_000
        )

        #expect(DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("authority provenance"),
            in: corpus
        ).flatMap(\.results).map(\.id) == ["matching"])
        #expect(DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("authority"),
            in: corpus,
            limit: 1
        ).flatMap(\.results).count == 1)
        #expect(DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("authority"),
            in: corpus,
            limit: 0
        ).isEmpty)
    }

    @Test
    func maximumResultsAndTieBreaksStayDeterministic() {
        let documents = (0..<205).reversed().map { index in
            let id = String(format: "item-%03d", index)
            return document(
                id: id,
                domain: .artifacts,
                title: "Release artifact",
                summary: "Local build evidence",
                target: .init(kind: .artifact, itemID: id),
                updatedAt: 1_000
            )
        }

        let results = DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("release artifact"),
            in: .init(documents: documents, capturedAtUnixMillis: 2_000),
            limit: 10_000
        ).flatMap(\.results)

        #expect(results.count == DesktopGlobalSearch.maximumResults)
        #expect(results.first?.id == "item-000")
        #expect(results.last?.id == "item-199")
    }

    private func document(
        id: String,
        domain: DesktopGlobalSearchDomain,
        title: String,
        summary: String,
        target: DesktopGlobalSearchNavigationTarget,
        updatedAt: Int64,
        source: DesktopGlobalSearchLocalSource = .kanameWorkspace,
        sourceLabel: String = "Kaname workspace"
    ) -> DesktopGlobalSearchDocument {
        DesktopGlobalSearchDocument.localSnapshot(
            identity: DesktopGlobalSearchIdentity(
                id: id,
                domain: domain,
                navigationTarget: target
            ),
            content: DesktopGlobalSearchContent(
                title: title,
                summary: summary
            ),
            provenance: DesktopGlobalSearchProvenance.localSnapshot(
                source: source,
                sourceID: "source-\(id)",
                sourceLabel: sourceLabel
            ),
            updatedAtUnixMillis: updatedAt
        )
    }
}
