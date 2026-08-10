import Dispatch
import Testing
@testable import KanameDesktop

@Suite(.serialized)
struct DesktopGlobalSearchPerformanceTests {
    private static let documentCount = 5_500
    private static let retainedSampleCount = 20
    // Full-suite concurrency adds measurable scheduler contention on CI and local
    // qualification hosts. Keep the interactive P95 below 350 ms while retaining
    // a separate 500 ms hard ceiling for every observed sample.
    private static let p95BudgetNanoseconds: UInt64 = 350_000_000
    private static let upperBudgetNanoseconds: UInt64 = 500_000_000

    @Test
    func representativeLargeLocalCorpusSearchStaysWithinRetainedLatencyBudgets() {
        let corpus = Self.representativeCorpus()
        let query = DesktopGlobalSearchQuery("atlas recovery")
        for _ in 0..<3 {
            _ = DesktopGlobalSearch.search(query: query, in: corpus, limit: DesktopGlobalSearch.maximumResults)
        }

        var samples: [UInt64] = []
        var observedResultCount = 0
        samples.reserveCapacity(Self.retainedSampleCount)
        for _ in 0..<Self.retainedSampleCount {
            let started = DispatchTime.now().uptimeNanoseconds
            let sections = DesktopGlobalSearch.search(
                query: query,
                in: corpus,
                limit: DesktopGlobalSearch.maximumResults
            )
            let ended = DispatchTime.now().uptimeNanoseconds
            observedResultCount = sections.reduce(0) { $0 + $1.results.count }
            samples.append(ended >= started ? ended - started : 0)
        }

        let sorted = samples.sorted()
        let p95Index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1))
        let retainedP95 = sorted[p95Index]
        let observedMaximum = sorted.last ?? .max
        print("MEASURE: DesktopGlobalSearch 5500-documents n=20 p95=\(retainedP95)ns max=\(observedMaximum)ns")
        #expect(corpus.documents.count == Self.documentCount)
        #expect(Set(corpus.documents.map(\.domain)) == Set(DesktopGlobalSearchDomain.allCases))
        #expect(observedResultCount == DesktopGlobalSearch.maximumResults)
        #expect(retainedP95 <= Self.p95BudgetNanoseconds)
        #expect(observedMaximum <= Self.upperBudgetNanoseconds)
    }

    @Test
    func publicSearchResultMemoryContractRemainsBoundedForAnUnboundedRequestedLimit() {
        let corpus = Self.representativeCorpus()
        let sections = DesktopGlobalSearch.search(
            query: DesktopGlobalSearchQuery("atlas recovery"),
            in: corpus,
            limit: .max
        )
        let results = sections.flatMap(\.results)

        #expect(results.count == DesktopGlobalSearch.maximumResults)
        #expect(sections.count <= DesktopGlobalSearchDomain.allCases.count)
        #expect(Set(results.map(\.id)).count == results.count)
        #expect(results.allSatisfy { $0.provenance.source != .providerSnapshot })
    }

    private static func representativeCorpus() -> DesktopGlobalSearchLocalCorpus {
        let sources: [DesktopGlobalSearchLocalSource] = [
            .kanameWorkspace,
            .obsidianSnapshot,
            .gmailSnapshot,
            .calendarSnapshot,
            .githubSnapshot,
            .localFileMetadata,
        ]
        let domains = DesktopGlobalSearchDomain.allCases
        let documents = (0..<documentCount).map { index in
            let domain = domains[index % domains.count]
            let source = sources[index % sources.count]
            let scope = "scope-\(index % 37)"
            return DesktopGlobalSearchDocument.localSnapshot(
                identity: DesktopGlobalSearchIdentity(
                    id: "local-\(index)",
                    domain: domain,
                    navigationTarget: DesktopGlobalSearchNavigationTarget(
                        kind: navigationKind(for: domain),
                        itemID: "item-\(index)",
                        scopeID: scope
                    )
                ),
                content: DesktopGlobalSearchContent(
                    title: "Atlas recovery local item \(index)",
                    summary: "Planning coding research snapshot segment \(index % 101)",
                    keywords: ["atlas", "recovery", "local", "bucket-\(index % 29)"]
                ),
                provenance: DesktopGlobalSearchProvenance.localSnapshot(
                    source: source,
                    sourceID: "source-\(index)",
                    sourceLabel: "Deterministic local \(source.rawValue)",
                    scopeLabel: scope,
                    projectID: "project-\(index % 53)",
                    projectLabel: "Project \(index % 53)",
                    accountID: domain == .email || domain == .calendar ? "account-\(index % 7)" : nil,
                    accountLabel: domain == .email || domain == .calendar ? "Local account \(index % 7)" : nil,
                    capturedAtUnixMillis: 20_000
                ),
                updatedAtUnixMillis: Int64(10_000 + index)
            )
        }
        return DesktopGlobalSearchLocalCorpus(documents: documents, capturedAtUnixMillis: 20_000)
    }

    private static func navigationKind(
        for domain: DesktopGlobalSearchDomain
    ) -> DesktopGlobalSearchNavigationTarget.Kind {
        switch domain {
        case .conversations: .conversation
        case .projects: .project
        case .research: .research
        case .knowledge: .knowledgeDocument
        case .email: .emailThread
        case .calendar: .calendarEvent
        case .automations: .automation
        case .github: .githubWork
        case .skills: .skill
        case .approvals: .approval
        case .artifacts: .artifact
        }
    }
}
