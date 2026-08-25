import Foundation
import SwiftUI

struct LinkClientMessage: Codable, Identifiable, Sendable {
    let id: String
    let author: LinkParticipantRole
    let authorName: String
    let body: String
    let sentAtUnixMillis: Int64
    let receipt: LinkReceiptStatus
}

struct LinkClientDiscussion: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let status: LinkDiscussionStatus
    let actionLabel: String
    let messages: [LinkClientMessage]
}

struct LinkClientSpace: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let hostName: String
    let verified: Bool
    let discussions: [LinkClientDiscussion]
}

struct LinkClientSnapshot: Codable, Sendable {
    let connection: LinkConnectionState
    let lastSyncUnixMillis: Int64?
    let spaces: [LinkClientSpace]
    let diagnosticCode: String?
    let verificationCode: String?

    static let empty = LinkClientSnapshot(
        connection: .enrollmentRequired,
        lastSyncUnixMillis: nil,
        spaces: [],
        diagnosticCode: nil,
        verificationCode: nil
    )

    static let synthetic = LinkClientSnapshot(
        connection: .hostOnline,
        lastSyncUnixMillis: 1_776_990_640_000,
        spaces: [
            LinkClientSpace(
                id: "space-synthetic-simplykay",
                name: "SimplyKay pilot",
                hostName: "Justin's Kaname",
                verified: true,
                discussions: [
                    LinkClientDiscussion(
                        id: "discussion-wfp-104",
                        title: "Monthly reporting correction",
                        status: .actionRequired,
                        actionLabel: "Review version 2",
                        messages: [
                            LinkClientMessage(
                                id: "message-1",
                                author: .collaborator,
                                authorName: "Kay",
                                body: "The subscription total should exclude the cancelled account. Could you update the report?",
                                sentAtUnixMillis: 1_776_989_820_000,
                                receipt: .gatewayAccepted
                            ),
                            LinkClientMessage(
                                id: "message-2",
                                author: .host,
                                authorName: "Justin",
                                body: "Version 2 is ready. I corrected the synthetic account total and validated the spreadsheet structure.",
                                sentAtUnixMillis: 1_776_990_540_000,
                                receipt: .published
                            ),
                        ]
                    ),
                    LinkClientDiscussion(
                        id: "discussion-onboarding",
                        title: "Pilot onboarding",
                        status: .delivered,
                        actionLabel: "No action needed",
                        messages: []
                    ),
                ]
            ),
        ],
        diagnosticCode: "SYNTHETIC-PREVIEW",
        verificationCode: nil
    )
}

@MainActor
@Observable
final class LinkClientViewModel {
    var snapshot: LinkClientSnapshot = .empty
    var selectedSpaceID: String?
    var selectedDiscussionID: String?
    var draft = ""
    var invitationJSON = ""
    var enrollmentDisplayName = ""
    var isWorking = false
    var notice: String?
    let isSyntheticPreview: Bool

    private let core: LinkClientCoreRunner

    init(
        core: LinkClientCoreRunner = LinkClientCoreRunner(),
        syntheticPreview: Bool = ProcessInfo.processInfo.arguments.contains("--synthetic-preview")
    ) {
        self.core = core
        self.isSyntheticPreview = syntheticPreview
        if syntheticPreview {
            apply(.synthetic)
        }
    }

    var selectedSpace: LinkClientSpace? {
        snapshot.spaces.first { $0.id == selectedSpaceID }
    }

    var selectedDiscussion: LinkClientDiscussion? {
        selectedSpace?.discussions.first { $0.id == selectedDiscussionID }
    }

    func load() async {
        guard !isSyntheticPreview else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await core.request(.init(operation: "snapshot"))
            guard let snapshot = response.snapshot else {
                throw LinkClientCoreError.invalidResponse
            }
            apply(snapshot)
            notice = nil
        } catch LinkClientCoreError.helperUnavailable {
            snapshot = .empty
            notice = "The signed Link core is unavailable. Reinstall Kaname Link."
        } catch {
            snapshot = LinkClientSnapshot(
                connection: .hostOffline,
                lastSyncUnixMillis: snapshot.lastSyncUnixMillis,
                spaces: snapshot.spaces,
                diagnosticCode: "LINK-CORE-UNAVAILABLE",
                verificationCode: snapshot.verificationCode
            )
            notice = "The host could not be reached. Your queued messages remain on this device."
        }
    }

    func sendDraft() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 16_384,
              let spaceID = selectedSpaceID,
              let discussionID = selectedDiscussionID,
              snapshot.connection.capabilities.canQueueMessage,
              !isSyntheticPreview else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await core.request(.init(
                operation: "sendMessage",
                payload: [
                    "spaceID": spaceID,
                    "discussionID": discussionID,
                    "body": trimmed,
                ]
            ))
            draft = ""
            await load()
        } catch {
            notice = "The message remains queued on this device."
        }
    }

    func enroll() async {
        guard !isSyntheticPreview else { return }
        let displayName = enrollmentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty,
              displayName.utf8.count <= 128,
              !displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let invitationData = invitationJSON.data(using: .utf8),
              !invitationData.isEmpty,
              invitationData.count <= 64 * 1_024,
              let invite = try? JSONDecoder().decode(
                  LinkInvitationArtifact.self,
                  from: invitationData
              ) else {
            notice = "Enter the complete Link invitation and a display name."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await core.request(.enroll(invite: invite, displayName: displayName))
            guard let snapshot = response.snapshot else {
                throw LinkClientCoreError.invalidResponse
            }
            invitationJSON = ""
            apply(snapshot)
            if let code = snapshot.verificationCode {
                notice = "Enrollment requested. Compare \(code) with the host before approval."
            } else {
                notice = "Enrollment requested. Compare the device verification code with the host before approval."
            }
        } catch {
            notice = "Enrollment was not accepted. Ask the host for a fresh invitation."
        }
    }

    private func apply(_ next: LinkClientSnapshot) {
        snapshot = next
        if selectedSpaceID == nil || !next.spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = next.spaces.first?.id
        }
        if selectedDiscussionID == nil
            || selectedSpace?.discussions.contains(where: { $0.id == selectedDiscussionID }) != true {
            selectedDiscussionID = selectedSpace?.discussions.first?.id
        }
    }
}
