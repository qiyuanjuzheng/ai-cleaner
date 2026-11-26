import Foundation

public enum SessionProjectEvidence: Hashable, Sendable {
    case reported(String)
    case exactIndex(String)
    case conflict

    var path: String? {
        switch self {
        case .reported(let path), .exactIndex(let path): path
        case .conflict: nil
        }
    }

    static func merging(_ first: Self?, _ second: Self?) -> Self? {
        guard let first else { return second }
        guard let second else { return first }
        return first.path != nil && first.path == second.path ? first : .conflict
    }

    static func workspacePath(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), !raw.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        let resolved = url.resolvingSymlinksInPath()
        let canonical = (try? resolved.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
        let path = ExcludedItemMatcher.normalizePath(canonical ?? resolved.path)
        return path == "/" ? nil : path
    }
}

public enum SessionProjectID: Hashable, Sendable {
    case workspace(String)
    case unidentified

    public var workspacePath: String? {
        if case .workspace(let path) = self { return path }
        return nil
    }

    public var name: String {
        workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未识别项目"
    }
}

public struct SessionProject: Identifiable, Sendable {
    public let id: SessionProjectID
    public let sessions: [CleanableItem]

    public init(id: SessionProjectID, sessions: [CleanableItem]) {
        self.id = id
        self.sessions = sessions
    }
}

/// Resolves only exact client/session IDs. Display names never establish ownership.
public struct ProjectSessionCatalog: Sendable {
    private struct SessionKey: Hashable {
        let clientID: String
        let sessionID: String

        init?(_ item: CleanableItem) {
            guard let id = item.exactSessionID else { return nil }
            clientID = item.clientID
            sessionID = id
        }
    }

    private let ownedLocations: [String: [URL]]
    private let projectIDsByItemID: [String: SessionProjectID]
    private let artifactKeysBySessionID: [String: SessionKey]
    private let artifactsByKey: [SessionKey: [CleanableItem]]
    private let workspacePaths: ProjectLocationMatcher
    public let projects: [SessionProject]

    public init(items: [CleanableItem] = []) {
        let sessions = items.filter { $0.category == .sessions && !$0.isSessionArtifact }
            .sorted { lhs, rhs in
                let lhsDate = lhs.cleanupSnapshot?.modifiedAt ?? .distantPast
                let rhsDate = rhs.cleanupSnapshot?.modifiedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id < rhs.id
            }
        var evidenceByKey: [SessionKey: SessionProjectEvidence] = [:]
        for item in items {
            guard let key = SessionKey(item), let evidence = item.projectEvidence else { continue }
            evidenceByKey[key] = SessionProjectEvidence.merging(evidenceByKey[key], evidence)
        }

        var groups: [SessionProjectID: [CleanableItem]] = [:]
        var projectIDs: [String: SessionProjectID] = [:]
        var keysBySessionID: [String: SessionKey] = [:]
        var locations: [String: [URL]] = [:]
        for session in sessions {
            let key = SessionKey(session)
            let evidence = key.flatMap { evidenceByKey[$0] }
            let path = evidence == .conflict ? nil : session.projectEvidence?.path
            let project = path.map(SessionProjectID.workspace) ?? .unidentified
            groups[project, default: []].append(session)
            if let path {
                locations[path, default: []].append(session.url)
                projectIDs[session.id] = project
            }
            if let key, evidence != .conflict, evidence?.path == path {
                keysBySessionID[session.id] = key
            }
        }

        var artifacts: [SessionKey: [CleanableItem]] = [:]
        for item in items where item.isSessionArtifact {
            guard let key = SessionKey(item), evidenceByKey[key] != .conflict else { continue }
            if let path = evidenceByKey[key]?.path {
                locations[path, default: []].append(item.url)
                projectIDs[item.id] = .workspace(path)
            }
            artifacts[key, default: []].append(item)
        }
        artifactKeysBySessionID = keysBySessionID
        artifactsByKey = artifacts
        ownedLocations = locations
        projectIDsByItemID = projectIDs
        workspacePaths = ProjectLocationMatcher(urls: locations.keys.map { URL(fileURLWithPath: $0) })
        projects = groups.map { SessionProject(id: $0.key, sessions: $0.value) }.sorted { lhs, rhs in
            if lhs.id == .unidentified { return false }
            if rhs.id == .unidentified { return true }
            let order = lhs.id.name.localizedStandardCompare(rhs.id.name)
            if order != .orderedSame { return order == .orderedAscending }
            return (lhs.id.workspacePath ?? "") < (rhs.id.workspacePath ?? "")
        }
    }

    public func artifacts(for session: CleanableItem) -> [CleanableItem] {
        guard let key = artifactKeysBySessionID[session.id] else { return [] }
        return artifactsByKey[key] ?? []
    }

    public func projectID(for item: CleanableItem) -> SessionProjectID {
        projectIDsByItemID[item.id] ?? .unidentified
    }

    public func protection(for projects: Set<String>) -> ProjectLocationMatcher {
        ProjectLocationMatcher(urls: projects.flatMap { ownedLocations[$0] ?? [] })
    }

    func wouldRemoveWorkspace(_ item: CleanableItem) -> Bool {
        workspacePaths.contains(atOrBelow: item.url)
    }
}

public struct ProjectLocationMatcher: Sendable {
    private let paths: Set<String>
    private let ancestors: Set<String>

    init(urls: [URL]) {
        var paths: Set<String> = []
        var ancestors: Set<String> = []
        for url in urls {
            for path in Self.pathVariants(url) where paths.insert(path).inserted {
                Self.forEachAncestor(of: path) { ancestors.insert($0) }
            }
        }
        self.paths = paths
        self.ancestors = ancestors
    }

    public func blocks(_ item: CleanableItem) -> Bool {
        guard !paths.isEmpty else { return false }
        for path in Self.pathVariants(item.url) {
            if paths.contains(path) || ancestors.contains(path) { return true }
            var insideProtectedItem = false
            Self.forEachAncestor(of: path) { insideProtectedItem = insideProtectedItem || paths.contains($0) }
            if insideProtectedItem { return true }
        }
        return false
    }

    func contains(atOrBelow url: URL) -> Bool {
        guard !paths.isEmpty else { return false }
        return Self.pathVariants(url).contains { paths.contains($0) || ancestors.contains($0) }
    }

    private static func pathVariants(_ url: URL) -> Set<String> {
        let raw = ExcludedItemMatcher.normalizePath(SafetyGuard.normalizeTempPath(url))
        let resolved = ExcludedItemMatcher.canonicalMatchPath(raw)
        var variants: Set<String> = [raw, resolved]
        // Match alternate spelling only on a volume that reports case-insensitive names.
        let volumeURL = URL(fileURLWithPath: resolved)
        if (try? volumeURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames == false {
            variants.insert(resolved.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")))
        }
        return variants
    }

    private static func forEachAncestor(of path: String, _ visit: (String) -> Void) {
        var suffix = path[...]
        while let end = suffix.lastIndex(of: "/"), end != suffix.startIndex {
            suffix = suffix[..<end]
            visit(String(suffix))
        }
    }
}
