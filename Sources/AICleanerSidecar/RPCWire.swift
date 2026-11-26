import AICleanerCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Wire names belong to the RPC v1 contract. Persisted model keys stay unchanged.
enum RPCWire {
    static func item(_ item: CleanableItem, selected: Set<String>) -> RPCValue {
        var fields: [String: RPCValue] = [
            "id": .string(item.id), "clientId": .string(item.clientID), "clientName": .string(item.clientName),
            "ruleId": .string(item.ruleID), "displayName": .string(item.displayName),
            "preferredTitle": .string(item.preferredDisplayTitle), "fileName": .string(item.fileName),
            "path": .string(PlatformPath.fileSystemPath(for: item.url)), "category": .string(item.category.rawValue),
            "recommendation": .string(item.recommendation.rawValue), "safetyNote": .string(item.safetyNote),
            "requiresIndividualSelection": .bool(item.requiresIndividualSelection),
            "bulkSelectable": .bool(item.isBulkSelectable), "selected": .bool(selected.contains(item.id)),
            "isRecentlyModified": .bool(item.isRecentlyModified), "isSessionArtifact": .bool(item.isSessionArtifact),
            "isDirectory": .bool(item.isDirectory), "isCustom": .bool(item.isCustom),
            "sizeBytes": .integer(item.sizeBytes), "fileCount": .count(item.fileCount),
            "modifiedAt": timestamp(item.modifiedAt)
        ]
        if let title = item.sessionTitle { fields["sessionTitle"] = .string(title) }
        if let project = item.sessionProjectName { fields["sessionProjectName"] = .string(project) }
        if let reason = item.hardProtectionReason { fields["hardProtectionReason"] = .string(reason) }
        if let badge = item.sourceBadge { fields["sourceBadge"] = .string(badge) }
        return .object(fields)
    }

    static func summary(_ report: ScanReport) -> RPCValue {
        .object([
            "scannedAt": timestamp(report.scannedAt),
            "totalBuiltInProfilesCount": .count(report.totalBuiltInProfilesCount),
            "detectedBuiltInClientsCount": .count(report.detectedBuiltInClientsCount),
            "skippedProtectedCount": .count(report.skippedProtectedCount),
            "totalSizeBytes": .integer(report.totalSizeBytes),
            "recommendedSizeBytes": .integer(report.recommendedSizeBytes),
            "reviewSuggestedSizeBytes": .integer(report.reviewSuggestedSizeBytes),
            "protectedSizeBytes": .integer(report.protectedSizeBytes),
            "totalDiskFootprintBytes": .integer(report.totalDiskFootprintBytes),
            "totalItemCount": .count(report.totalItemCount),
            "totalRecommendedCount": .count(report.totalRecommendedCount),
            "totalReviewSuggestedCount": .count(report.totalReviewSuggestedCount),
            "totalProtectedItemCount": .count(report.totalProtectedItemCount)
        ])
    }

    static func client(_ client: ClientScanSummary) -> RPCValue {
        .object([
            "id": .string(client.id), "name": .string(client.profile.name),
            "symbolName": .string(client.profile.symbolName), "accentToken": .string(client.profile.accentToken),
            "kind": .string(client.profile.kind.rawValue), "itemCount": .count(client.itemCount),
            "totalSizeBytes": .integer(client.totalSizeBytes), "recommendedSizeBytes": .integer(client.recommendedSizeBytes),
            "reviewSuggestedSizeBytes": .integer(client.reviewSuggestedSizeBytes),
            "protectedSizeBytes": .integer(client.protectedSizeBytes)
        ])
    }

    static func progress(_ event: ScanProgressEvent, scanID: String) -> RPCValue {
        .object([
            "scanId": .string(scanID), "stage": .string(event.stage.rawValue),
            "scannedFileCount": .count(event.scannedFileCount), "cleanableBytes": .integer(event.cleanableBytes),
            "clients": .array(event.clients.map { client in
                .object([
                    "id": .string(client.id), "name": .string(client.name),
                    "symbolName": .string(client.symbolName), "accentToken": .string(client.accentToken),
                    "kind": .string(client.kind.rawValue), "state": .string(client.state.rawValue),
                    "cleanableBytes": .integer(client.cleanableBytes), "itemCount": .count(client.itemCount)
                ])
            })
        ])
    }

    static func selection(_ summary: CleanupSelectionSummary, revision: Int) -> RPCValue {
        .object([
            "selectionRevision": .count(revision), "selectedCount": .count(summary.items.count),
            "selectedBytes": .integer(summary.totalBytes), "hasNotRecommended": .bool(!summary.riskItems.isEmpty)
        ])
    }

    static func cleanup(_ result: CleanupResult) -> RPCValue {
        .object([
            "trashedItems": .array(result.trashedItems.map { record in
                .object([
                    "item": item(record.item, selected: []),
                    "resultingTrashPath": record.resultingTrashURL.map { .string(PlatformPath.fileSystemPath(for: $0)) } ?? .null,
                    "trashedBytes": .integer(record.trashedBytes)
                ])
            }),
            "skippedProtectedItems": .array(result.skippedProtectedItems.map(failure)),
            "failedItems": .array(result.failedItems.map(failure)),
            "trashedCount": .count(result.trashedCount), "freedBytes": .integer(result.freedBytes),
            "completedAt": timestamp(result.completedAt)
        ])
    }

    private static func failure(_ failure: CleanupFailure) -> RPCValue {
        .object(["item": item(failure.item, selected: []), "reason": .string(failure.reason)])
    }

    private static func timestamp(_ date: Date) -> RPCValue {
        .string(Date.ISO8601FormatStyle().format(date))
    }
}
