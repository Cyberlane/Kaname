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
    func snapshotCoordinatorKeepsStreamingRowsAndCorpusAtomicAndRejectsOlderOutput() {
        var snapshot = DesktopAppSnapshot.starter(now: 1_000)
        snapshot.operations.worktrees = []
        snapshot.threads = [snapshot.threads[0]]
        let threadID = snapshot.threads[0].id
        let unchangedThreadTimestamp = snapshot.threads[0].updatedAtUnixMillis
        let unchangedSavedTimestamp = snapshot.lastSavedAtUnixMillis
        var coordinator = DesktopGlobalSearchSnapshotCoordinator()

        func replacingAssistantBody(_ body: String) -> DesktopAppSnapshot {
            var replacement = snapshot
            replacement.threads[0].messages = [DesktopMessage(
                id: "streaming-route",
                role: .assistant,
                body: body,
                createdAtUnixMillis: 2_000
            )]
            return replacement
        }

        func output(
            for value: DesktopAppSnapshot,
            schedule: DesktopGlobalSearchSnapshotCoordinator.Schedule,
            term: String
        ) -> (DesktopGlobalSearchLocalCorpus, DesktopGlobalSearchOutput) {
            let rows = DesktopGlobalSearchFTS.supplementalRows(from: value)
            let corpus = schedule.cachedCorpus ?? DesktopGlobalSearchLocalIndex.corpus(
                from: value,
                supplementalRows: rows
            )
            return (
                corpus,
                DesktopGlobalSearch.searchOutput(
                    query: DesktopGlobalSearchQuery(term),
                    in: corpus,
                    ftsRows: rows
                )
            )
        }

        let firstSnapshot = replacingAssistantBody("alpha streaming evidence")
        let firstSchedule = coordinator.schedule(snapshot: firstSnapshot)
        let first = output(for: firstSnapshot, schedule: firstSchedule, term: "alpha")
        let acceptedFirst = coordinator.apply(corpus: first.0, for: firstSchedule)
        #expect(acceptedFirst)
        #expect(first.1.sections.flatMap(\.results).contains {
            $0.id == "conversation-message:\(threadID):streaming-route"
        })

        let delayedSnapshot = replacingAssistantBody("beta streaming evidence")
        let delayedSchedule = coordinator.schedule(snapshot: delayedSnapshot)
        #expect(delayedSchedule.cachedCorpus == nil)
        let delayed = output(for: delayedSnapshot, schedule: delayedSchedule, term: "beta")

        let newestSnapshot = replacingAssistantBody("gamma streaming evidence")
        let newestSchedule = coordinator.schedule(snapshot: newestSnapshot)
        #expect(newestSchedule.cachedCorpus == nil)
        let newest = output(for: newestSnapshot, schedule: newestSchedule, term: "gamma")

        let acceptedDelayed = coordinator.apply(corpus: delayed.0, for: delayedSchedule)
        let acceptedNewest = coordinator.apply(corpus: newest.0, for: newestSchedule)
        #expect(!acceptedDelayed)
        #expect(acceptedNewest)
        #expect(newest.1.sections.flatMap(\.results).contains {
            $0.id == "conversation-message:\(threadID):streaming-route"
        })
        #expect(DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("beta"),
            in: newest.0,
            ftsRows: DesktopGlobalSearchFTS.supplementalRows(from: newestSnapshot)
        ).flatMap(\.results).allSatisfy {
            $0.id != "conversation-message:\(threadID):streaming-route"
        })
        #expect(newestSnapshot.threads[0].updatedAtUnixMillis == unchangedThreadTimestamp)
        #expect(newestSnapshot.lastSavedAtUnixMillis == unchangedSavedTimestamp)
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
    func ftsErrorSurfacedNotSwallowed() throws {
        let local = document(
            id: "local-checkpoint",
            domain: .knowledge,
            title: "Checkpoint recovery",
            summary: "Linear local snapshot result",
            target: .init(kind: .knowledgeDocument, itemID: "checkpoint-note"),
            updatedAt: 1_000,
            source: .obsidianSnapshot
        )
        let failure = DesktopGlobalSearchFTS.Failure(
            stage: .queryExecution,
            reason: "simulated ranking failure"
        )

        let output = DesktopGlobalSearch.searchOutput(
            query: DesktopGlobalSearchQuery("checkpoint"),
            in: .init(documents: [local], capturedAtUnixMillis: 2_000),
            fullTextResult: .failure(failure)
        )

        #expect(output.sections.flatMap(\.results).map(\.id) == ["local-checkpoint"])
        #expect(output.fullTextResult == .failure(failure))
        #expect(output.statusLine == "Full-text ranking unavailable: simulated ranking failure")
        #expect(try #require(output.sections.first?.results.first).matchedFields.contains(.title))
    }

    @Test
    func fullTextNoMatchHasNoDegradationStatus() {
        let output = DesktopGlobalSearch.searchOutput(
            query: DesktopGlobalSearchQuery("missing"),
            in: .init(documents: [], capturedAtUnixMillis: 1_000),
            fullTextResult: .matches([])
        )

        #expect(output.sections.isEmpty)
        #expect(output.fullTextResult == .matches([]))
        #expect(output.statusLine == nil)
    }

    @Test
    func cancelledFullTextWorkHasNoResultsOrDegradationStatus() {
        let output = DesktopGlobalSearch.searchOutput(
            query: DesktopGlobalSearchQuery("checkpoint"),
            in: .init(
                documents: [document(
                    id: "checkpoint",
                    domain: .knowledge,
                    title: "Checkpoint recovery",
                    summary: "Local snapshot",
                    target: .init(kind: .knowledgeDocument, itemID: "checkpoint"),
                    updatedAt: 1_000
                )],
                capturedAtUnixMillis: 2_000
            ),
            fullTextResult: .cancelled
        )

        #expect(output.sections.isEmpty)
        #expect(output.fullTextResult == .cancelled)
        #expect(output.statusLine == nil)
    }

    @Test
    func punctuationOnlyTokensDoNotSuppressLinearResults() {
        let local = document(
            id: "secure-checkpoint",
            domain: .knowledge,
            title: "Checkpoint 🔒",
            summary: "Local snapshot",
            target: .init(kind: .knowledgeDocument, itemID: "secure-checkpoint"),
            updatedAt: 1_000,
            source: .obsidianSnapshot
        )
        let corpus = DesktopGlobalSearchLocalCorpus(
            documents: [local],
            capturedAtUnixMillis: 2_000
        )

        let results = DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("checkpoint!!!"),
            in: corpus
        ).flatMap(\.results)
        let emojiResults = DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("🔒"),
            in: corpus
        ).flatMap(\.results)

        #expect(results.map(\.id) == ["secure-checkpoint"])
        #expect(emojiResults.map(\.id) == ["secure-checkpoint"])
        #expect(!DesktopGlobalSearchQuery("!!! … 🔒").isEmpty)
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
