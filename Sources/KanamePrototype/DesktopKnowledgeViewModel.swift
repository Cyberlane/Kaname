import Foundation
import KanameConnectivity
import KanameDesktop

@MainActor
final class DesktopKnowledgeViewModel: ObservableObject {
    @Published private(set) var document: ObsidianDocumentSnapshot?
    @Published private(set) var searchResults: [ObsidianSearchResult] = []
    @Published private(set) var diff: ObsidianNoteDiff?
    @Published private(set) var activeWriteID: String?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published var draft = ""

    func seedDefaultScope(model: DesktopAppModel) {
        guard model.snapshot.operations.vaultScopes.isEmpty,
              let source = model.snapshot.domains.knowledgeSources.first(where: { $0.kind == .obsidian }) else { return }
        _ = model.addVaultScope(path: source.scope, sourceID: source.id, canWrite: false)
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

    func reviewDraft(model: DesktopAppModel) {
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
                let writeID = model.recordKnowledgeWrite(
                    proposalID: proposalID,
                    targetPath: proposed.targetPath,
                    baseDigest: proposed.baseDigest,
                    proposedDigest: proposed.proposedDigest,
                    diffSummary: proposed.summary,
                    unifiedDiff: proposed.unifiedDiff
                )
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
            threadID: nil,
            title: "Write Obsidian note",
            exactTarget: exactTarget,
            consequence: "Replace \(write.targetPath) only if revision \(write.baseDigest.prefix(12)) is still current.",
            dataLeavingDevice: "Nothing; this is a local vault write.",
            reversible: true,
            expiresAtUnixMillis: nil
        ) else { return }
        model.attachKnowledgeApproval(writeID: writeID, approvalID: approvalID)
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
