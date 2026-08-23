import Foundation
import KanameConnectivity
import KanameDesktop

@MainActor
final class DesktopKnowledgeViewModel: ObservableObject {
    @Published private(set) var document: ObsidianDocumentSnapshot?
    @Published private(set) var searchResults: [ObsidianSearchResult] = []
    @Published private(set) var diff: ObsidianNoteDiff?
    @Published private(set) var activeWriteID: String?
    @Published private(set) var codingThreadID: String?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published var draft = ""

    func prepareCodingDraft(
        model: DesktopAppModel,
        threadID: String,
        path: String,
        scopePath: String,
        candidates: [DesktopCodingKnowledgeCandidate]
    ) {
        guard !isBusy else { return }
        guard let cleanPath = writableNotePath(model: model, path: path, scopePath: scopePath) else {
            message = "Choose an exact Markdown note inside a writable vault scope."
            return
        }
        guard model.codingKnowledgeLane(threadID: threadID) != nil else {
            message = "This coding thread has no durable knowledge lane yet."
            return
        }
        codingThreadID = threadID
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let snapshot = try await service(model: model).inspect(path: cleanPath)
                document = snapshot
                draft = Self.seededDraft(content: snapshot.content, candidates: candidates)
                diff = nil
                activeWriteID = nil
                model.recordKnowledgeDocument(Self.documentRecord(snapshot, existing: model.snapshot.operations.knowledgeDocuments.first {
                    $0.path == snapshot.path
                }))
                message = "Loaded " + snapshot.path + ". Review the seeded draft before requesting exact write approval."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func seedDefaultScope(model: DesktopAppModel) {
        guard model.snapshot.operations.vaultScopes.isEmpty,
              let source = model.snapshot.domains.knowledgeSources.first(where: { $0.kind == .obsidian }) else { return }
        _ = model.addVaultScope(path: source.scope, sourceID: source.id, canWrite: false)
    }

    func resumeCodingProposal(model: DesktopAppModel, threadID: String) {
        codingThreadID = threadID
        document = nil
        activeWriteID = nil
        draft = ""
        diff = nil
        message = nil
        guard let lane = model.codingKnowledgeLane(threadID: threadID),
              let writeID = lane.writeID,
              let write = model.snapshot.operations.knowledgeWrites.first(where: { $0.id == writeID }),
              let proposal = model.snapshot.operations.knowledgeProposals.first(where: { $0.id == write.proposalID }) else { return }
        activeWriteID = write.id
        draft = proposal.proposedContent
        diff = nil
        message = "Resumed the persisted knowledge proposal. Review the exact diff and approval state."
    }

    func inspect(model: DesktopAppModel, path: String) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let snapshot = try await service(model: model).inspect(path: path)
                document = snapshot
                draft = snapshot.content
                diff = nil
                activeWriteID = nil
                model.recordKnowledgeDocument(Self.documentRecord(snapshot, existing: model.snapshot.operations.knowledgeDocuments.first {
                    $0.path == snapshot.path
                }))
                message = "Loaded \(snapshot.path) with provenance and link context."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func search(model: DesktopAppModel, query: String, scope: DesktopVaultScopeRecord) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                searchResults = try await service(model: model).search(query: query, scope: scope.path)
                message = searchResults.isEmpty
                    ? "No notes matched within \(scope.path)."
                    : "Found \(searchResults.count) scoped result(s)."
            } catch {
                searchResults = []
                message = error.localizedDescription
            }
        }
    }

    func reviewDraft(model: DesktopAppModel, codingThreadID: String? = nil) {
        guard let document else {
            message = "Open a note before reviewing changes."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let proposed = try await service(model: model).proposedDiff(
                    path: document.path,
                    baseContent: document.content,
                    proposedContent: draft
                )
                guard proposed.baseDigest != proposed.proposedDigest else {
                    diff = nil
                    activeWriteID = nil
                    message = "The draft matches the current note."
                    return
                }
                guard let proposalID = model.createKnowledgeProposal(
                    sourceID: scope(model: model, path: document.path)?.sourceID,
                    title: "Edit \(Self.title(for: document.path))",
                    target: document.path,
                    summary: proposed.summary,
                    proposedContent: draft,
                    baseRevision: proposed.baseDigest
                ) else {
                    message = "The proposed edit could not be recorded."
                    return
                }
                let linkedCodingThreadID = codingThreadID ?? self.codingThreadID
                if let linkedCodingThreadID,
                   !model.linkCodingKnowledge(threadID: linkedCodingThreadID, proposalID: proposalID) {
                    message = "The coding workflow changed before the proposal could be linked. Nothing was approved or written."
                    return
                }
                guard let writeID = model.recordKnowledgeWrite(
                    proposalID: proposalID,
                    targetPath: proposed.targetPath,
                    baseDigest: proposed.baseDigest,
                    proposedDigest: proposed.proposedDigest,
                    diffSummary: proposed.summary,
                    unifiedDiff: proposed.unifiedDiff
                ) else {
                    message = "Kaname could not persist a digest-bound write proposal. Nothing was approved or written."
                    return
                }
                if let linkedCodingThreadID,
                   model.codingKnowledgeLane(threadID: linkedCodingThreadID)?.writeID != writeID {
                    message = "Kaname could not durably bind the proposed write to this coding thread. Nothing was approved or written."
                    return
                }
                diff = proposed
                activeWriteID = writeID
                message = "Review the exact diff, then request write approval."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func requestApproval(model: DesktopAppModel) {
        guard let writeID = activeWriteID,
              let write = model.snapshot.operations.knowledgeWrites.first(where: { $0.id == writeID }),
              write.approvalID == nil else { return }
        let exactTarget = Self.approvalTarget(path: write.targetPath, baseDigest: write.baseDigest)
        guard let approvalID = model.createApproval(
            threadID: codingThreadID,
            title: "Write Obsidian note",
            exactTarget: exactTarget,
            consequence: "Replace \(write.targetPath) only if revision \(write.baseDigest.prefix(12)) is still current.",
            dataLeavingDevice: "Nothing; this is a local vault write.",
            reversible: true,
            expiresAtUnixMillis: nil
        ) else { return }
        guard model.attachKnowledgeApproval(writeID: writeID, approvalID: approvalID) else {
            message = "Kaname could not bind the approval to this exact note revision. Nothing was written."
            return
        }
        message = "The exact note write is ready for approval in Inbox."
    }

    func applyApprovedDraft(model: DesktopAppModel) {
        guard !isBusy, let writeID = activeWriteID,
              let write = model.snapshot.operations.knowledgeWrites.first(where: { $0.id == writeID }),
              let approvalID = write.approvalID,
              let approval = model.snapshot.operations.approvals.first(where: { $0.id == approvalID }),
              approval.state == .approved,
              approval.exactTarget == Self.approvalTarget(path: write.targetPath, baseDigest: write.baseDigest) else {
            message = "Approve this exact base revision in Inbox before applying it."
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let reconciled = try await service(model: model).write(
                    path: write.targetPath,
                    content: draft,
                    grant: ObsidianNoteMutationGrant(
                        approvalID: approval.id,
                        targetPath: write.targetPath,
                        baseDigest: write.baseDigest
                    )
                )
                document = reconciled
                diff = nil
                model.reconcileKnowledgeWrite(
                    id: writeID,
                    state: .reconciled,
                    currentDigest: reconciled.digest,
                    detail: "Approved local vault write was re-read and matched its proposed digest."
                )
                model.recordKnowledgeDocument(Self.documentRecord(reconciled, existing: model.snapshot.operations.knowledgeDocuments.first {
                    $0.path == reconciled.path
                }))
                message = "Saved and reconciled \(reconciled.path)."
            } catch let error as ObsidianVaultError {
                let digest: String?
                if case let .conflict(currentDigest) = error { digest = currentDigest } else { digest = nil }
                model.reconcileKnowledgeWrite(id: writeID, state: .failed, currentDigest: digest, detail: error.localizedDescription)
                message = error.localizedDescription
            } catch {
                model.reconcileKnowledgeWrite(id: writeID, state: .failed, currentDigest: nil, detail: error.localizedDescription)
                message = error.localizedDescription
            }
        }
    }

    func resetDraft() {
        guard let document else { return }
        draft = document.content
        diff = nil
        activeWriteID = nil
        message = "Draft reset to the last inspected revision."
    }

    func clearSearch() {
        searchResults = []
    }

    private func service(model: DesktopAppModel) throws -> ObsidianVaultService {
        let readable = model.snapshot.operations.vaultScopes.filter(\.canRead).map(\.path)
        let writable = model.snapshot.operations.vaultScopes.filter(\.canWrite).map(\.path)
        return try ObsidianVaultService(readableScopes: readable, writableScopes: writable)
    }

    private func scope(model: DesktopAppModel, path: String) -> DesktopVaultScopeRecord? {
        model.snapshot.operations.vaultScopes.first { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    private func writableNotePath(model: DesktopAppModel, path: String, scopePath: String) -> String? {
        let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = clean.split(separator: "/", omittingEmptySubsequences: false)
        guard !clean.isEmpty,
              clean.utf8.count <= 2_048,
              !clean.hasPrefix("/"),
              URL(fileURLWithPath: clean).pathExtension.lowercased() == "md",
              !components.contains("."),
              !components.contains(".."),
              !components.contains("") else { return nil }
        guard model.snapshot.operations.vaultScopes.contains(where: {
            $0.canWrite && $0.path == scopePath && (clean == $0.path || clean.hasPrefix($0.path + "/"))
        }) else { return nil }
        return clean
    }

    private static func seededDraft(
        content: String,
        candidates: [DesktopCodingKnowledgeCandidate]
    ) -> String {
        guard !candidates.isEmpty else { return content }
        let additions = candidates.enumerated().map { index, candidate in
            let evidence = candidate.evidenceDigest.map { "\nEvidence digest: \($0)" } ?? ""
            return String(index + 1) + ". **" + candidate.title + "** (" + candidate.category.rawValue + ")\n" + candidate.detail + evidence
        }.joined(separator: "\n\n")
        let separator = content.hasSuffix("\n") ? "\n" : "\n\n"
        return content + separator + "## Proposed coding knowledge\n\n" + additions + "\n"
    }

    private static func documentRecord(
        _ snapshot: ObsidianDocumentSnapshot,
        existing: DesktopKnowledgeDocumentRecord?
    ) -> DesktopKnowledgeDocumentRecord {
        var record = DesktopKnowledgeDocumentRecord(
            path: snapshot.path,
            title: title(for: snapshot.path),
            digest: snapshot.digest,
            provenance: "Obsidian CLI · local vault · revision \(snapshot.digest.prefix(12))",
            lastReadAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        record.replaceContext(
            projectID: existing?.projectID,
            role: existing?.role,
            sourceURLs: sourceURLs(in: snapshot.content),
            wikilinks: snapshot.wikilinks,
            backlinks: snapshot.backlinks,
            attachments: snapshot.attachments,
            properties: snapshot.properties,
            conflictDigest: nil
        )
        return record
    }

    private static func sourceURLs(in content: String) -> [String] {
        guard let expression = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        return Array(Set(expression.matches(in: content, range: range).compactMap(\.url?.absoluteString))).sorted()
    }

    private static func title(for path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func approvalTarget(path: String, baseDigest: String) -> String {
        "obsidian:\(path)#sha256=\(baseDigest)"
    }
}
