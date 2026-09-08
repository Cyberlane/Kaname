import Combine
import CryptoKit
import Foundation
import KanameConnectivity
import KanameDomain
import KanameLocalCore
#if os(macOS)
import Darwin
#endif

extension DesktopAppModel {
    public var activeProjects: [DesktopProject] {
        snapshot.projects
            .filter { $0.archivedAtUnixMillis == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var archivedProjects: [DesktopProject] {
        snapshot.projects
            .filter { $0.archivedAtUnixMillis != nil }
            .sorted { ($0.archivedAtUnixMillis ?? 0) > ($1.archivedAtUnixMillis ?? 0) }
    }

    public func project(id: String?) -> DesktopProject? {
        guard let id else { return nil }
        return snapshot.projects.first { $0.id == id }
    }

    public func projects(matching query: String, includeArchived: Bool = false) -> [DesktopProject] {
        let normalized = Self.normalized(query).lowercased()
        let projects = includeArchived ? archivedProjects : activeProjects
        guard !normalized.isEmpty else { return projects }
        return projects.filter { project in
            project.name.lowercased().contains(normalized)
                || project.summary.lowercased().contains(normalized)
                || project.path?.lowercased().contains(normalized) == true
                || project.context.instructionReferences.contains { $0.lowercased().contains(normalized) }
        }
    }

    @discardableResult
    public func createProject(
        name: String,
        path: String?,
        summary: String,
        context: DesktopProjectContext = .empty
    ) -> String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= 120,
              cleanSummary.utf8.count <= 2_000 else { return nil }
        let cleanPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedPath = cleanPath?.isEmpty == false ? Self.canonicalProjectPath(cleanPath!) : nil
        guard storedPath?.utf8.count ?? 0 <= 4_096,
              !snapshot.projects.contains(where: { project in
                  guard let existing = project.path else { return false }
                  return Self.canonicalProjectPath(existing) == storedPath
              }) else { return nil }
        let instructionReferences = Self.uniqueNormalized(
            context.instructionReferences,
            maximumCount: 24,
            maximumBytes: 1_024
        )
        let knowledgeIDs = Set(snapshot.domains.knowledgeSources.map(\.id))
        let skillIDs = Set(snapshot.domains.skills.map(\.id))
        let provider = Self.normalized(context.defaultProvider)
        let model = Self.normalized(context.defaultModel)
        guard !provider.isEmpty, provider.utf8.count <= 120,
              !model.isEmpty, model.utf8.count <= 200 else { return nil }
        let project = DesktopProject(
            name: cleanName,
            path: storedPath,
            summary: cleanSummary,
            context: DesktopProjectContext(
                instructionReferences: instructionReferences,
                knowledgeSourceIDs: Self.unique(context.knowledgeSourceIDs.filter(knowledgeIDs.contains)),
                skillIDs: Self.unique(context.skillIDs.filter(skillIDs.contains)),
                allowsCrossProjectRecall: context.allowsCrossProjectRecall,
                defaultKind: context.defaultKind,
                defaultProvider: provider,
                defaultModel: model
            ),
            createdAtUnixMillis: now()
        )
        mutate { $0.projects.append(project) }
        return project.id
    }

    private static func canonicalProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    @discardableResult
    public func updateProject(
        id: String,
        name: String,
        path: String?,
        summary: String,
        context: DesktopProjectContext
    ) -> Bool {
        let cleanName = Self.normalized(name)
        let cleanSummary = Self.normalized(summary)
        let cleanPath = path.map(Self.normalized)
        let instructions = Self.uniqueNormalized(context.instructionReferences, maximumCount: 24, maximumBytes: 1_024)
        let knowledgeIDs = Set(snapshot.domains.knowledgeSources.map(\.id))
        let skillIDs = Set(snapshot.domains.skills.map(\.id))
        let provider = Self.normalized(context.defaultProvider)
        let model = Self.normalized(context.defaultModel)
        guard snapshot.projects.contains(where: { $0.id == id }),
              !cleanName.isEmpty, cleanName.utf8.count <= 120,
              cleanSummary.utf8.count <= 2_000,
              cleanPath?.utf8.count ?? 0 <= 4_096,
              !provider.isEmpty, provider.utf8.count <= 120,
              !model.isEmpty, model.utf8.count <= 200 else { return false }
        let sanitizedContext = DesktopProjectContext(
            instructionReferences: instructions,
            knowledgeSourceIDs: Self.unique(context.knowledgeSourceIDs.filter(knowledgeIDs.contains)),
            skillIDs: Self.unique(context.skillIDs.filter(skillIDs.contains)),
            allowsCrossProjectRecall: context.allowsCrossProjectRecall,
            defaultKind: context.defaultKind,
            defaultProvider: provider,
            defaultModel: model
        )
        mutate { snapshot in
            guard let index = snapshot.projects.firstIndex(where: { $0.id == id }) else { return }
            snapshot.projects[index].name = cleanName
            snapshot.projects[index].path = cleanPath?.isEmpty == false ? cleanPath : nil
            snapshot.projects[index].summary = cleanSummary
            snapshot.projects[index].context = sanitizedContext
        }
        return true
    }

    public func setProjectArchived(id: String, archived: Bool) {
        mutate { snapshot in
            guard let index = snapshot.projects.firstIndex(where: { $0.id == id }) else { return }
            snapshot.projects[index].archivedAtUnixMillis = archived ? now() : nil
            if archived {
                for threadIndex in snapshot.threads.indices where snapshot.threads[threadIndex].projectID == id {
                    snapshot.threads[threadIndex].attention = .archived
                    snapshot.threads[threadIndex].unread = false
                }
            }
        }
    }

    public func updatePreferences(_ preferences: DesktopPreferences) {
        mutate { $0.preferences = preferences }
    }

    public func replaceAccounts(
        for services: Set<DesktopAccountRecord.Service>,
        with accounts: [DesktopAccountRecord]
    ) {
        guard accounts.allSatisfy({ services.contains($0.service) }) else { return }
        mutate { snapshot in
            snapshot.domains.accounts.removeAll { services.contains($0.service) }
            snapshot.domains.accounts.append(contentsOf: accounts)
            snapshot.domains.accounts = Self.sortedRecords(snapshot.domains.accounts) {
                "\($0.service.rawValue)|\($0.identity)"
            }
        }
    }

    public func replaceCalendarSources(_ sources: [DesktopCalendarSourceRecord]) {
        let priorEnablement = Dictionary(
            uniqueKeysWithValues: snapshot.domains.calendarSources.map { ($0.id, $0.isEnabled) }
        )
        mutate { snapshot in
            let merged = sources.map { source in
                var updated = source
                updated.isEnabled = priorEnablement[source.id] ?? source.isEnabled
                return updated
            }
            let deduplicated = Dictionary(grouping: merged) {
                "\($0.provider.rawValue)|\($0.accountID)|\($0.externalIdentifier)".lowercased()
            }.compactMap { $0.value.last }
            snapshot.domains.calendarSources = Self.sortedRecords(deduplicated) {
                "\($0.provider.rawValue)|\($0.displayName)"
            }
        }
    }

    public func setCalendarSourceEnabled(id: String, enabled: Bool) {
        mutateRecord(at: \.domains.calendarSources, id: id) { source in
            source.isEnabled = enabled
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueNormalized(
        _ values: [String],
        maximumCount: Int,
        maximumBytes: Int
    ) -> [String] {
        let values = unique(values.map(normalized).filter { !$0.isEmpty && $0.utf8.count <= maximumBytes })
        guard values.count > maximumCount else { return values }
        return Array(values[0..<maximumCount])
    }

    private static func sortedRecords<Record>(
        _ records: [Record],
        key: (Record) -> String
    ) -> [Record] {
        records.sorted {
            key($0).localizedCaseInsensitiveCompare(key($1)) == .orderedAscending
        }
    }
}
