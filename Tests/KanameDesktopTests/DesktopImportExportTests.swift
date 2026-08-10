import Foundation
import Testing
@testable import KanameDesktop

struct DesktopImportExportTests {
    @Test
    func importPreviewIsBoundedDeduplicatedAndNeverAutoSends() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "Plan.md")
        let second = root.appending(path: "work.swift")
        try Data("# Plan\nKeep it local.".utf8).write(to: first)
        try Data("let value = 42\n".utf8).write(to: second)

        let preview = try DesktopImportExportService.previewImport(urls: [first, second, first])
        #expect(preview.files.count == 2)
        #expect(preview.files.allSatisfy { $0.sha256.count == 64 })
        #expect(preview.composerDraft.contains("have not been sent yet"))
        #expect(preview.composerDraft.contains("<file name=\"Plan.md\""))
        #expect(!preview.composerDraft.contains(root.path))
    }

    @Test
    func identicalFileContentsKeepDistinctStableReviewIdentities() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "First.md")
        let second = root.appending(path: "Second.md")
        let identicalContents = Data("Same reviewable text".utf8)
        try identicalContents.write(to: first)
        try identicalContents.write(to: second)

        let preview = try DesktopImportExportService.previewImport(urls: [first, second])

        #expect(preview.files.map(\.displayName) == ["First.md", "Second.md"])
        #expect(Set(preview.files.map(\.id)).count == 2)
        #expect(Set(preview.files.map(\.sha256)).count == 1)
        #expect(preview.composerDraft.contains("<file name=\"First.md\""))
        #expect(preview.composerDraft.contains("<file name=\"Second.md\""))
    }

    @Test
    func importRejectsUnsupportedBinaryOversizeAndSymlink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appending(path: "secret.bin")
        try Data([0, 1, 2]).write(to: binary)
        #expect(throws: DesktopImportExportError.unsupportedFile("secret.bin")) {
            try DesktopImportExportService.previewImport(urls: [binary])
        }

        let large = root.appending(path: "large.txt")
        try Data(repeating: 65, count: DesktopImportExportService.maximumFileBytes + 1).write(to: large)
        #expect(throws: DesktopImportExportError.fileTooLarge("large.txt")) {
            try DesktopImportExportService.previewImport(urls: [large])
        }

        let target = root.appending(path: "target.md")
        let link = root.appending(path: "linked.md")
        try Data("private".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: DesktopImportExportError.symbolicLink("linked.md")) {
            try DesktopImportExportService.previewImport(urls: [link])
        }
    }

    @Test
    func conversationAndProjectExportsAreDeterministicAndTyped() throws {
        let snapshot = DesktopAppSnapshot.starter(now: 1_000)
        let thread = try #require(snapshot.threads.first)
        var project = try #require(snapshot.projects.first)
        let privateWorkspacePath = "/Users/private-owner/Projects/recognizable-secret-workspace"
        project.path = privateWorkspacePath
        project.context.instructionReferences = [
            "AGENTS.md",
            "Docs/UX.md",
            "\(privateWorkspacePath)/Docs/Portable.md",
            "/Users/private-owner/Library/recognizable-private-instruction.md",
            "~/Library/recognizable-tilde-instruction.md",
            "$HOME/recognizable-dollar-home-instruction.md",
            "${HOME}/recognizable-braced-home-instruction.md",
            "C:\\Users\\private-owner\\recognizable-windows-instruction.md",
            "Users/private-owner/recognizable-home-like-instruction.md",
            "Scoped/$HOME/recognizable-embedded-home-instruction.md",
            "../recognizable-traversal-instruction.md",
        ]

        let conversation = try DesktopImportExportService.exportConversation(thread, projectName: project.name)
        #expect(conversation.kind == .conversationMarkdown)
        #expect(conversation.suggestedFilename.hasSuffix("-conversation.md"))
        #expect(String(decoding: conversation.data, as: UTF8.self).contains("## Assistant"))

        let first = try DesktopImportExportService.exportProject(project)
        let second = try DesktopImportExportService.exportProject(project)
        #expect(first.kind == .projectJSON)
        #expect(first.data == second.data)
        let object = try #require(JSONSerialization.jsonObject(with: first.data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["name"] as? String == project.name)
        #expect(object["workspacePath"] == nil)
        #expect(object["instructionReferences"] as? [String] == ["AGENTS.md", "Docs/UX.md", "Docs/Portable.md"])

        let exportedText = String(decoding: first.data, as: UTF8.self)
        let privateFragments = [
            privateWorkspacePath,
            "/Users/private-owner",
            "private-owner",
            "recognizable-secret-workspace",
            "recognizable-private-instruction",
            "recognizable-tilde-instruction",
            "recognizable-dollar-home-instruction",
            "recognizable-braced-home-instruction",
            "recognizable-windows-instruction",
            "recognizable-home-like-instruction",
            "recognizable-embedded-home-instruction",
            "recognizable-traversal-instruction",
        ]
        #expect(privateFragments.allSatisfy { !exportedText.contains($0) })
        #expect(privateFragments.allSatisfy { !first.data.contains(Data($0.utf8)) })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kaname-import-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
