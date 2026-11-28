import AICleanerCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

actor SidecarServer {
    static let protocolVersion = "1.0"
    static let idleTimeout = Duration.seconds(600)

    private struct Session {
        let id: String
        let rawReport: ScanReport
        let catalog: ProjectSessionCatalog
        let report: ScanReport
        let itemsByID: [String: CleanableItem]
        let searchIndex: [String: String]
        let snapshots: [String: FileCleanupSnapshot]
        let protectedPaths: Set<String>

        init(id: String, report: ScanReport, snapshots: [String: FileCleanupSnapshot],
             protectedPaths: Set<String>, excludedItems: [ExcludedItemRecord], platform: any PlatformAdapter) {
            let catalog = ProjectSessionCatalog(items: report.projectItems)
            let matcher = ExcludedItemMatcher(records: excludedItems, caseInsensitive: platform.pathsAreCaseInsensitive)
            let displayReport = report.filtering(excluding: matcher)
                .applyingProjectProtection(catalog.protection(for: protectedPaths, platform: platform))
            let itemsByID = Dictionary(displayReport.allDisplayedItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.id = id
            self.rawReport = report
            self.catalog = catalog
            self.report = displayReport
            self.itemsByID = itemsByID
            self.searchIndex = itemsByID.mapValues(ScanItemFilter.searchableText)
            self.snapshots = snapshots
            self.protectedPaths = protectedPaths
        }
    }

    private struct ProjectScope {
        let project: SessionProject
        let clientID: String?
    }

    private struct ScopedItems {
        let all: [CleanableItem]
        let filtered: [CleanableItem]
        let isProjectScope: Bool
    }

    private struct Preview {
        let token: String
        let scanID: String
        let reportRevision: Int
        let selectionRevision: Int
        let summary: CleanupSelectionSummary
    }

    private let platform: any PlatformAdapter
    private let scanner: any ScanPerforming
    private let cleaner: TrashCleaner
    private let directories: CustomDirectoryStore
    private let exclusions: ExcludedItemStore
    private let history: CleanupHistoryStore
    private let projectProtection: ProjectProtectionStore
    private let settings: SettingsStore
    private let emit: @Sendable (RPCValue) -> Void

    private var handshaken = false
    private var shouldShutdown = false
    private var lastRequestAt = ContinuousClock.now
    private var lastProgressAt: ContinuousClock.Instant?
    private var activeScanID: String?
    private var scanTask: Task<Void, Never>?
    private var session: Session?
    private var reportRevision = 0
    private var selectionRevision = 0
    private var selectedIDs: Set<String> = []
    private var preview: Preview?

    init(platform: any PlatformAdapter = HostPlatformAdapter.shared, scanner: (any ScanPerforming)? = nil,
         legacyAppearance: @escaping @Sendable () -> AppearanceMode? = SettingsStore.installedAppearance,
         emit: @escaping @Sendable (RPCValue) -> Void) {
        let scanner = scanner ?? ScanEngine(platform: platform)
        self.scanner = scanner
        self.platform = platform
        self.cleaner = TrashCleaner(safetyGuard: scanner.safetyGuard)
        self.directories = CustomDirectoryStore(platform: platform, safetyGuard: scanner.safetyGuard)
        self.exclusions = ExcludedItemStore(platform: platform)
        self.history = CleanupHistoryStore(platform: platform)
        self.projectProtection = ProjectProtectionStore(platform: platform)
        self.settings = SettingsStore(directory: platform.userDataDirectory(), legacyAppearance: legacyAppearance)
        self.emit = emit
    }

    /// Returns false after the shutdown response has been written.
    func receive(_ line: String) -> Bool {
        let payload: RPCValue
        do {
            payload = try JSONDecoder().decode(RPCValue.self, from: Data(line.utf8))
        } catch {
            fail(RPCError(-32700, "Parse error"), id: .null)
            return true
        }
        if let batch = payload.array {
            guard !batch.isEmpty else {
                fail(.invalidRequest, id: .null)
                return true
            }
            let replies = batch.compactMap(handle)
            if !replies.isEmpty { emit(.array(replies)) }
        } else if let reply = handle(payload) {
            emit(reply)
        }
        return !shouldShutdown
    }

    func isIdle(now: ContinuousClock.Instant = .now) -> Bool {
        // The desktop still needs the completed report, selection, and cleanup preview.
        scanTask == nil && session == nil && lastRequestAt.duration(to: now) >= Self.idleTimeout
    }

    func stop() {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
    }

    private func handle(_ payload: RPCValue) -> RPCValue? {
        guard let request = payload.object,
              request["jsonrpc"] == .string("2.0"),
              let method = request["method"]?.string,
              request["id"]?.isRequestID != false else {
            return response(id: .null, key: "error", value: RPCError.invalidRequest.value)
        }
        let id = request["id"]
        lastRequestAt = .now
        do {
            guard !shouldShutdown else { throw RPCError.invalidRequest }
            guard request["params"] == nil || request["params"]?.object != nil else { throw RPCError.invalidParams }
            let result = try route(method, params: request["params"]?.object ?? [:])
            return id.map { response(id: $0, key: "result", value: result) }
        } catch let error as RPCError {
            return id.map { response(id: $0, key: "error", value: error.value) }
        } catch {
            let error = RPCError(-32603, "Internal error")
            return id.map { response(id: $0, key: "error", value: error.value) }
        }
    }

    private func route(_ method: String, params: [String: RPCValue]) throws -> RPCValue {
        if method == "core.handshake" {
            let version = try requiredString("protocolVersion", in: params).split(separator: ".", omittingEmptySubsequences: false)
            guard version.count == 2, Int(version[0]) == 1, let minor = Int(version[1]), minor >= 0 else {
                throw RPCError.versionMismatch
            }
            handshaken = true
            return .object([
                "protocolVersion": .string(Self.protocolVersion), "coreVersion": .string(Self.protocolVersion),
                "platform": .string(platform.platform.rawValue),
                "capabilities": .array([
                    "scan", "scan.progress", "items", "selection", "trash", "customDirs", "history", "excluded", "projects", "settings"
                ].map(RPCValue.string))
            ])
        }
        guard handshaken else { throw RPCError.versionMismatch }

        switch method {
        case "core.ping": return .object([:])
        case "core.shutdown":
            shouldShutdown = true
            stop()
            return .object([:])
        case "scan.start": return try startScan()
        case "scan.cancel":
            guard try requiredString("scanId", in: params) == activeScanID else { throw RPCError.scanNotFound }
            scanTask?.cancel()
            return .object([:])
        case "report.summary": return RPCWire.summary(try requiredSession(params).report)
        case "clients.list":
            let scan = try requiredSession(params)
            return .object(["clients": .array(scan.report.clientSummaries.map(RPCWire.client))])
        case "items.query": return try queryItems(params, scan: requiredSession(params))
        case "items.get":
            let scan = try requiredSession(params)
            let items = try requiredIDs("ids", in: params).map { id in try requiredItem(id, in: scan) }
            return .object(["items": .array(items.map { RPCWire.item($0, selected: selectedIDs) })])
        case "items.resolvePath":
            let scan = try requiredSession(params)
            let item = try requiredItem(requiredString("itemId", in: params), in: scan)
            return .object(["path": .string(PlatformPath.fileSystemPath(for: item.url))])
        case "selection.apply": return try applySelection(params, scan: requiredSession(params))
        case "selection.confirmRisk":
            let scan = try requiredSession(params)
            let item = try requiredItem(requiredString("itemId", in: params), in: scan)
            if let reason = item.hardProtectionReason { throw safetyBlocked(reason) }
            guard !item.isCleanable else { throw RPCError.invalidParams }
            replaceSelection(selectedIDs.union([item.id]))
            return selectionResult(scan)
        case "trash.preview": return try makePreview(requiredSession(params))
        case "trash.execute": return try executeTrash(params, scan: requiredSession(params))
        case "history.list": return try .object(["records": .model(withStorage { try history.loadChecked() })])
        case "history.delete":
            let id = try requiredUUID("id", in: params)
            do { _ = try history.delete(id: id) } catch { throw RPCError.storage(error) }
            return .object([:])
        case "history.clear":
            do { try history.clearAll() } catch { throw RPCError.storage(error) }
            return .object([:])
        case "excluded.list": return try listExclusions()
        case "excluded.add": return try excludeItem(params, scan: requiredSession(params))
        case "excluded.restore":
            let id = try requiredUUID("id", in: params)
            return try restoreExclusions(id: id)
        case "excluded.restoreAll": return try restoreExclusions(id: nil)
        case "projects.list": return try listProjects(params, scan: requiredSession(params))
        case "projects.sessions":
            let scan = try requiredSession(params)
            let project = try requiredProject(requiredString("projectId", in: params), scan: scan)
            let scope = ProjectScope(project: project, clientID: try optionalString("clientId", in: params))
            return try queryItems(params, scan: scan, project: scope)
        case "projects.setProtection": return try setProjectProtection(params)
        case "settings.get": return try .model(withStorage { try settings.load() })
        case "settings.set":
            let mode: AppearanceMode? = try optionalEnum("appearanceMode", in: params)
            guard let mode else { throw RPCError.invalidParams }
            return try .model(withStorage { try settings.setAppearance(mode) })
        case "customDirs.list": return try .object(["directories": .model(withStorage { try directories.loadChecked() })])
        case "customDirs.validate": return try validateDirectory(params)
        case "customDirs.add": return try addDirectory(params)
        case "customDirs.remove":
            let id = try requiredUUID("id", in: params)
            do { _ = try directories.remove(id: id) } catch { throw RPCError.storage(error) }
            return .object([:])
        case "disk.capacity":
            let capacity = StartupDiskCapacityReader(platform: platform).read()
            return .object(["total": capacity.map { .integer($0.totalBytes) } ?? .null,
                            "available": capacity.map { .integer($0.availableBytes) } ?? .null])
        default: throw RPCError.methodNotFound
        }
    }

    private func startScan() throws -> RPCValue {
        guard scanTask == nil else { throw RPCError.scanInProgress }
        let id = UUID().uuidString
        let customDirectories = try withStorage { try directories.loadChecked() }
        let excludedItems = try withStorage { try exclusions.loadChecked() }
        let scanner = self.scanner
        let platform = self.platform
        let progress = AsyncStream<ScanProgressEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let relay = Task { [weak self] in
            for await event in progress.stream { await self?.sendProgress(event, scanID: id) }
        }
        activeScanID = id
        lastProgressAt = nil
        session = nil
        replaceSelection([])
        preview = nil
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let report = scanner.scan(customDirectories: customDirectories, excludedItems: excludedItems, now: nil) {
                progress.continuation.yield($0)
            }
            var snapshots: [String: FileCleanupSnapshot] = [:]
            for item in report.allDisplayedItems where item.hardProtectionReason == nil {
                if Task.isCancelled { break }
                snapshots[item.id] = item.cleanupSnapshot ?? FileCleanupSnapshot.capture(at: item.url, platform: platform)
            }
            progress.continuation.finish()
            await relay.value
            await self?.finishScan(id: id, report: report, snapshots: snapshots, cancelled: Task.isCancelled)
        }
        return .object(["scanId": .string(id)])
    }

    private func sendProgress(_ event: ScanProgressEvent, scanID: String) {
        guard activeScanID == scanID, scanTask?.isCancelled != true else { return }
        let now = ContinuousClock.now
        if let lastProgressAt, lastProgressAt.duration(to: now) < .milliseconds(150) { return }
        lastProgressAt = now
        notify("scan.progress", params: RPCWire.progress(event, scanID: scanID))
    }

    private func finishScan(id: String, report: ScanReport, snapshots: [String: FileCleanupSnapshot], cancelled: Bool) {
        guard activeScanID == id else { return }
        let wasCancelled = cancelled || scanTask?.isCancelled == true
        activeScanID = nil
        scanTask = nil
        lastRequestAt = .now
        var params: [String: RPCValue] = ["scanId": .string(id), "status": .string("cancelled"), "summary": .null]
        if !wasCancelled {
            do {
                let paths = try projectProtection.load()
                let excludedItems = try exclusions.loadChecked()
                let next = Session(id: id, report: report, snapshots: snapshots, protectedPaths: paths,
                                   excludedItems: excludedItems, platform: platform)
                session = next
                reportRevision += 1
                params["status"] = .string("completed")
                params["summary"] = RPCWire.summary(next.report)
            } catch {
                params["status"] = .string("failed")
                params["error"] = RPCError.storage(error).value
            }
        }
        params["reportRevision"] = .count(reportRevision)
        notify("scan.completed", params: .object(params))
    }

    private func requiredSession(_ params: [String: RPCValue]) throws -> Session {
        let id = try requiredString("scanId", in: params)
        if let session, session.id == id { return session }
        if activeScanID == id { throw RPCError.scanNotReady }
        throw RPCError.scanNotFound
    }

    private func scopedItems(_ params: [String: RPCValue], scan: Session, project: ProjectScope? = nil) throws -> ScopedItems {
        let all: [CleanableItem]
        var projectScope = project
        if let project {
            all = projectSessions(project, scan: scan)
        } else if let value = params["scope"], value != .null {
            guard let scope = value.object else { throw RPCError.invalidParams }
            switch try requiredString("kind", in: scope) {
            case "all": all = scan.report.allDisplayedItems
            case "client":
                let id = try requiredString("clientId", in: scope)
                all = scan.report.clientSummaries.first { $0.id == id }?.allDisplayedItems ?? []
            case "clientProjects":
                let clientID = try requiredString("clientId", in: scope)
                let id = try requiredString("projectId", in: scope)
                let scope = ProjectScope(project: try requiredProject(id, scan: scan), clientID: clientID)
                projectScope = scope
                all = projectSessions(scope, scan: scan)
            default: throw RPCError.invalidParams
            }
        } else {
            all = scan.report.allDisplayedItems
        }
        let values: [String: RPCValue]
        if let rawFilter = params["filter"], rawFilter != .null {
            guard let decoded = rawFilter.object else { throw RPCError.invalidParams }
            values = decoded
        } else {
            values = [:]
        }
        let filter = ScanItemFilter(
            search: try optionalString("search", in: values) ?? "",
            category: try optionalEnum("category", in: values),
            recommendation: try optionalEnum("recommendation", in: values),
            age: try optionalEnum("age", in: values) ?? .all
        )
        let isProjectScope = projectScope != nil
        let filtered = filter.applying(to: all, modificationDate: { item in
            if isProjectScope { return item.cleanupSnapshot?.modifiedAt }
            return item.isCleanable ? item.modifiedAt : nil
        }, searchIndex: { scan.searchIndex[$0] })
        return ScopedItems(all: all, filtered: filtered, isProjectScope: isProjectScope)
    }

    private func queryItems(_ params: [String: RPCValue], scan: Session, project: ProjectScope? = nil) throws -> RPCValue {
        let sort: ScanItemSort = try optionalEnum("sort", in: params) ?? .sizeDescending
        let offset = try optionalInt("offset", in: params) ?? 0
        let limit = try optionalInt("limit", in: params) ?? 200
        guard offset >= 0, (1...200).contains(limit) else { throw RPCError.invalidParams }
        let scoped = try scopedItems(params, scan: scan, project: project)
        let items = sort.sorting(scoped.filtered)
        let buckets = ScanItemBuckets(items: items)
        let fullySelected = ScanItemSelection.fullySelectedSections(in: buckets.bulkSelectable, selectedIDs: selectedIDs)
        let groups = buckets.sections.map { section in
            RPCValue.object([
                "recommendation": .string(section.recommendation.rawValue), "itemCount": .count(section.items.count),
                "totalBytes": .integer(section.totalBytes), "allBulkSelected": .bool(fullySelected.contains(section.recommendation))
            ])
        }
        let page = buckets.sections.lazy.flatMap(\.items).dropFirst(min(offset, items.count)).prefix(limit)
        let selectedIDs = self.selectedIDs
        let rows = Array(page.map { item in
            let row = RPCWire.item(item, selected: selectedIDs)
            guard scoped.isProjectScope, var fields = row.object else { return row }
            let artifacts = scan.catalog.artifacts(for: item).compactMap { scan.itemsByID[$0.id] }
            fields["artifacts"] = .array(artifacts.map { RPCWire.item($0, selected: selectedIDs) })
            return .object(fields)
        })
        return .object(["reportRevision": .count(reportRevision), "total": .count(items.count),
                        "groups": .array(groups), "items": .array(rows)])
    }

    private func applySelection(_ params: [String: RPCValue], scan: Session) throws -> RPCValue {
        let op = try requiredString("op", in: params)
        if op == "clearAll" {
            replaceSelection([])
            return selectionResult(scan)
        }
        let scope = try scopedItems(params, scan: scan)
        var next = selectedIDs
        switch op {
        case "toggle":
            var visibleIDs = Set(scope.filtered.map(\.id))
            if scope.isProjectScope {
                for item in scope.filtered {
                    visibleIDs.formUnion(scan.catalog.artifacts(for: item).map(\.id))
                }
            }
            for id in Set(try requiredIDs("itemIds", in: params)) {
                let item = try requiredItem(id, in: scan)
                guard visibleIDs.contains(id) else { throw RPCError.invalidParams }
                switch ScanItemSelection.toggle(item, isSelected: next.contains(id)) {
                case .select: next.insert(id)
                case .deselect: next.remove(id)
                case .confirmRisk: throw RPCError.riskConfirmation
                case .blocked: throw safetyBlocked(item.hardProtectionReason ?? "Protected item")
                }
            }
        case "selectRecommendedInScope":
            next = ScanItemSelection.selecting(scope.all, from: next, recommendation: .recommended)
        case "selectSection", "deselectSection", "toggleSection":
            let recommendation: CleanupRecommendation? = try optionalEnum("recommendation", in: params)
            guard let recommendation, recommendation.isCleanable else { throw RPCError.invalidParams }
            let deselect = op == "deselectSection" || (op == "toggleSection" &&
                ScanItemSelection.fullySelectedSections(in: scope.filtered, selectedIDs: next).contains(recommendation))
            next = deselect
                ? ScanItemSelection.deselecting(scope.filtered, from: next, recommendation: recommendation)
                : ScanItemSelection.selecting(scope.filtered, from: next, recommendation: recommendation)
        case "selectAllVisible": next = ScanItemSelection.selecting(scope.filtered, from: next)
        case "invertVisible": next = ScanItemSelection.inverting(scope.filtered, from: next)
        case "clearVisible": next = ScanItemSelection.deselecting(scope.filtered, from: next)
        default: throw RPCError.invalidParams
        }
        replaceSelection(next)
        return selectionResult(scan)
    }

    private func replaceSelection(_ next: Set<String>) {
        guard next != selectedIDs else { return }
        selectedIDs = next
        selectionRevision += 1
        preview = nil
    }

    private func selectionResult(_ scan: Session) -> RPCValue {
        RPCWire.selection(CleanupSelectionSummary(selectedIDs: selectedIDs, itemsByID: scan.itemsByID), revision: selectionRevision)
    }

    private func makePreview(_ scan: Session) throws -> RPCValue {
        let summary = CleanupSelectionSummary(selectedIDs: selectedIDs, itemsByID: scan.itemsByID)
        guard !summary.items.isEmpty else { throw RPCError.invalidParams }
        let token = UUID().uuidString
        preview = Preview(token: token, scanID: scan.id, reportRevision: reportRevision,
                          selectionRevision: selectionRevision, summary: summary)
        return .object(["confirmationToken": .string(token), "totalBytes": .integer(summary.totalBytes),
                        "hasNotRecommended": .bool(!summary.riskItems.isEmpty),
                        "items": .array(summary.items.map { RPCWire.item($0, selected: selectedIDs) })])
    }

    private func executeTrash(_ params: [String: RPCValue], scan: Session) throws -> RPCValue {
        let token = try requiredString("confirmationToken", in: params)
        guard let preview, preview.token == token, preview.scanID == scan.id,
              preview.reportRevision == reportRevision, preview.selectionRevision == selectionRevision else {
            throw RPCError.invalidConfirmation
        }
        let acknowledged = try optionalBool("acknowledgedNotRecommendedRisk", in: params) ?? false
        if !preview.summary.riskItems.isEmpty && !acknowledged { throw RPCError.riskConfirmation }
        let protectedPaths = try withStorage { try projectProtection.load() }
        let excludedItems = try withStorage { try exclusions.loadChecked() }
        let matcher = ExcludedItemMatcher(records: excludedItems, caseInsensitive: platform.pathsAreCaseInsensitive)
        if protectedPaths != scan.protectedPaths || preview.summary.items.contains(where: { matcher.isExcluded($0.url) }) {
            refreshSession(scan, report: scan.rawReport, protectedPaths: protectedPaths, excludedItems: excludedItems)
            throw RPCError.invalidConfirmation
        }

        self.preview = nil
        let result = cleaner.trash(items: preview.summary.items, allowNotRecommendedOverride: acknowledged,
                                   projectCatalog: scan.catalog, projectProtectionStore: projectProtection,
                                   verifyProjectSelection: true, scannedSnapshots: scan.snapshots)
        if !result.trashedItems.isEmpty {
            let report = scan.rawReport.removing(trashedRecords: result.trashedItems)
            refreshSession(scan, report: report, protectedPaths: protectedPaths, excludedItems: excludedItems)
        }
        var reply: [String: RPCValue] = ["result": RPCWire.cleanup(result), "reportRevision": .count(reportRevision)]
        do {
            if let record = try history.record(result: result) { reply["historyRecord"] = try .model(record) }
        } catch {
            // Cleanup already happened. Preserve its result so the client cannot retry the same operation.
            reply["historyError"] = RPCError.storage(error).value
        }
        return .object(reply)
    }

    private func listExclusions() throws -> RPCValue {
        let records = try withStorage { try exclusions.loadChecked() }
        let statuses = Dictionary(records.map { record in
            (record.id.uuidString, RPCValue.bool((try? platform.identity(at: record.url)) != nil))
        }, uniquingKeysWith: { first, _ in first })
        return try .object(["records": .model(records), "statuses": .object(statuses)])
    }

    private func excludeItem(_ params: [String: RPCValue], scan: Session) throws -> RPCValue {
        let id = try requiredString("itemId", in: params)
        let item = try requiredItem(id, in: scan)
        let protectedPaths = try withStorage { try projectProtection.load() }
        let record = ExcludedItemRecord.from(item: item)
        let records = try withStorage { try exclusions.add(record) }
        let canonical = ExcludedItemMatcher.canonicalMatchPath(record.normalizedPath)
        let key = PlatformPath.comparisonKey(canonical, caseInsensitive: platform.pathsAreCaseInsensitive)
        let saved = records.first { candidate in
            PlatformPath.comparisonKey(ExcludedItemMatcher.canonicalMatchPath(candidate.normalizedPath),
                                       caseInsensitive: platform.pathsAreCaseInsensitive) == key
        } ?? record
        refreshSession(scan, report: scan.rawReport, protectedPaths: protectedPaths, excludedItems: records)
        return try .object(["record": .model(saved), "reportRevision": .count(reportRevision)])
    }

    private func restoreExclusions(id: UUID?) throws -> RPCValue {
        let previous = try withStorage { try exclusions.loadChecked() }
        let remaining = id.map { id in previous.filter { $0.id != id } } ?? []
        guard remaining.count != previous.count else { return .object([:]) }
        let paths = try withStorage { try projectProtection.load() }
        try withStorage { try exclusions.save(remaining) }
        if let scan = session {
            refreshSession(scan, report: scan.rawReport, protectedPaths: paths, excludedItems: remaining)
        }
        return .object([:])
    }

    private func listProjects(_ params: [String: RPCValue], scan: Session) throws -> RPCValue {
        let clientID = try optionalString("clientId", in: params)
        let includeAll = try optionalBool("includeAllClients", in: params) ?? false
        let projects = scan.catalog.projects.compactMap { project -> RPCValue? in
            if let clientID, !project.sessions.contains(where: { $0.clientID == clientID }) { return nil }
            let path = project.id.workspacePath
            let isProtected = path.map(scan.protectedPaths.contains) ?? false
            let scope = ProjectScope(project: project, clientID: includeAll && path != nil ? nil : clientID)
            let sessions = projectSessions(scope, scan: scan)
            guard !sessions.isEmpty || isProtected else { return nil }
            var fields: [String: RPCValue] = [
                "projectId": .string(projectID(project.id)), "name": .string(project.id.name),
                "sessionCount": .count(sessions.count), "sizeBytes": .integer(sessions.reduce(0) { $0 + $1.sizeBytes }),
                "isProtected": .bool(isProtected)
            ]
            if let path { fields["workspacePath"] = .string(path) }
            return .object(fields)
        }
        return .object(["projects": .array(projects)])
    }

    private func projectSessions(_ scope: ProjectScope, scan: Session) -> [CleanableItem] {
        scope.project.sessions.compactMap { item in
            guard scope.clientID == nil || item.clientID == scope.clientID else { return nil }
            return scan.itemsByID[item.id]
        }
    }

    private func projectID(_ project: SessionProjectID) -> String {
        project.workspacePath.map { "workspace:\($0)" } ?? "unidentified"
    }

    private func requiredProject(_ id: String, scan: Session) throws -> SessionProject {
        guard let project = scan.catalog.projects.first(where: { projectID($0.id) == id }) else {
            throw RPCError.invalidParams
        }
        return project
    }

    private func setProjectProtection(_ params: [String: RPCValue]) throws -> RPCValue {
        guard let scan = session else { throw RPCError.scanNotFound }
        let project = try requiredProject(requiredString("projectId", in: params), scan: scan)
        guard let path = project.id.workspacePath,
              let enabled = try optionalBool("enabled", in: params) else { throw RPCError.invalidParams }
        var paths = try withStorage { try projectProtection.load() }
        let original = paths
        if enabled { paths.insert(path) } else { paths.remove(path) }
        if paths != scan.protectedPaths || paths != original {
            let records = try withStorage { try exclusions.loadChecked() }
            if paths != original { try withStorage { try projectProtection.save(paths) } }
            refreshSession(scan, report: scan.rawReport, protectedPaths: paths, excludedItems: records)
        }
        return .object(["isProtected": .bool(enabled)])
    }

    private func refreshSession(_ scan: Session, report: ScanReport, protectedPaths: Set<String>,
                                excludedItems: [ExcludedItemRecord]) {
        let next = Session(id: scan.id, report: report, snapshots: scan.snapshots, protectedPaths: protectedPaths,
                           excludedItems: excludedItems, platform: platform)
        session = next
        reportRevision += 1
        preview = nil
        replaceSelection(selectedIDs.filter { id in
            guard let item = next.itemsByID[id] else { return false }
            return item.hardProtectionReason == nil
        })
    }

    private func validateDirectory(_ params: [String: RPCValue]) throws -> RPCValue {
        let url = try directoryURL(params)
        let decision = scanner.safetyGuard.validateCustomDirectoryRoot(url)
        if let reason = decision.blockReason { return .object(["allowed": .bool(false), "reason": .string(reason)]) }
        guard (try? platform.identity(at: url))?.kind == .directory else {
            return .object(["allowed": .bool(false), "reason": .string("目录不存在或不可读取")])
        }
        return .object(["allowed": .bool(true)])
    }

    private func addDirectory(_ params: [String: RPCValue]) throws -> RPCValue {
        let url = try directoryURL(params)
        let title = try optionalString("displayName", in: params)
        let category: ScanCategory = try optionalEnum("category", in: params) ?? .custom
        let mode: ScanTargetMode = try optionalEnum("mode", in: params) ?? .children
        do {
            return try .object(["directory": .model(directories.add(url: url, displayName: title, category: category, mode: mode))])
        } catch CustomDirectoryError.protectedPath(let reason) {
            throw safetyBlocked(reason)
        } catch let error as CustomDirectoryError {
            throw RPCError(-32011, "Invalid path", name: "INVALID_PATH", reason: error.description)
        } catch {
            throw RPCError.storage(error)
        }
    }

    private func directoryURL(_ params: [String: RPCValue]) throws -> URL {
        let path = try requiredString("path", in: params)
        let normalized = PlatformPath.normalize(path)
        let isAbsolute: Bool
        if platform.platform == .windows {
            isAbsolute = normalized.hasPrefix("//") ||
                (path.utf8.count > 2 && PlatformPath.hasWindowsDrivePrefix(normalized))
        } else {
            isAbsolute = path.hasPrefix("/")
        }
        guard isAbsolute, !path.contains("\0") else {
            throw RPCError(-32011, "Invalid path", name: "INVALID_PATH")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func requiredItem(_ id: String, in scan: Session) throws -> CleanableItem {
        guard let item = scan.itemsByID[id] else { throw RPCError.invalidParams }
        return item
    }

    private func requiredIDs(_ key: String, in params: [String: RPCValue]) throws -> [String] {
        guard let values = params[key]?.array, values.count <= 500 else { throw RPCError.invalidParams }
        return try values.map {
            guard let id = $0.string, !id.isEmpty else { throw RPCError.invalidParams }
            return id
        }
    }

    private func requiredUUID(_ key: String, in params: [String: RPCValue]) throws -> UUID {
        guard let id = UUID(uuidString: try requiredString(key, in: params)) else { throw RPCError.invalidParams }
        return id
    }

    private func requiredString(_ key: String, in params: [String: RPCValue]) throws -> String {
        guard let value = params[key]?.string, !value.isEmpty else { throw RPCError.invalidParams }
        return value
    }

    private func optionalString(_ key: String, in params: [String: RPCValue]) throws -> String? {
        guard let value = params[key], value != .null else { return nil }
        guard let string = value.string else { throw RPCError.invalidParams }
        return string
    }

    private func optionalInt(_ key: String, in params: [String: RPCValue]) throws -> Int? {
        guard let value = params[key], value != .null else { return nil }
        guard let int = value.int else { throw RPCError.invalidParams }
        return int
    }

    private func optionalEnum<T: RawRepresentable>(_ key: String, in params: [String: RPCValue]) throws -> T? where T.RawValue == String {
        guard let value = try optionalString(key, in: params) else { return nil }
        guard let decoded = T(rawValue: value) else { throw RPCError.invalidParams }
        return decoded
    }

    private func optionalBool(_ key: String, in params: [String: RPCValue]) throws -> Bool? {
        guard let value = params[key], value != .null else { return nil }
        guard let flag = value.bool else { throw RPCError.invalidParams }
        return flag
    }

    private func withStorage<Value>(_ operation: () throws -> Value) throws -> Value {
        do { return try operation() } catch { throw RPCError.storage(error) }
    }

    private func safetyBlocked(_ reason: String) -> RPCError {
        RPCError(-32010, "Safety check blocked the item", name: "SAFETY_BLOCKED", reason: reason)
    }

    private func response(id: RPCValue, key: String, value: RPCValue) -> RPCValue {
        .object(["jsonrpc": .string("2.0"), "id": id, key: value])
    }

    private func fail(_ error: RPCError, id: RPCValue) {
        emit(response(id: id, key: "error", value: error.value))
    }

    private func notify(_ method: String, params: RPCValue) {
        emit(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }
}
