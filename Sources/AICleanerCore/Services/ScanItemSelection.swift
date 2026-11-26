public enum ScanItemSelection {
    public enum Toggle: Equatable, Sendable {
        case blocked, select, deselect, confirmRisk
    }

    public static func toggle(_ item: CleanableItem, isSelected: Bool) -> Toggle {
        guard item.hardProtectionReason == nil else { return .blocked }
        if isSelected { return .deselect }
        return item.isCleanable ? .select : .confirmRisk
    }

    public static func selecting(
        _ items: [CleanableItem],
        from selectedIDs: Set<String>,
        recommendation: CleanupRecommendation? = nil
    ) -> Set<String> {
        selectedIDs.union(items.lazy.filter {
            $0.isBulkSelectable && (recommendation == nil || $0.recommendation == recommendation)
        }.map(\.id))
    }

    /// Deselecting a visible section also clears items that were selected individually.
    public static func deselecting(
        _ items: [CleanableItem],
        from selectedIDs: Set<String>,
        recommendation: CleanupRecommendation? = nil
    ) -> Set<String> {
        selectedIDs.subtracting(items.lazy.filter {
            recommendation == nil || $0.recommendation == recommendation
        }.map(\.id))
    }

    public static func inverting(_ items: [CleanableItem], from selectedIDs: Set<String>) -> Set<String> {
        selectedIDs.symmetricDifference(items.lazy.filter(\.isBulkSelectable).map(\.id))
    }

    public static func fullySelectedSections(
        in items: [CleanableItem],
        selectedIDs: Set<String>
    ) -> Set<CleanupRecommendation> {
        guard !selectedIDs.isEmpty else { return [] }
        var seen: Set<CleanupRecommendation> = []
        var incomplete: Set<CleanupRecommendation> = []
        for item in items where item.isBulkSelectable {
            seen.insert(item.recommendation)
            if !selectedIDs.contains(item.id) { incomplete.insert(item.recommendation) }
        }
        return seen.subtracting(incomplete)
    }
}

public struct CleanupSelectionSummary: Sendable {
    public struct ClientGroup: Identifiable, Sendable {
        public let id: String
        public let clientName: String
        public let items: [CleanableItem]
        public let totalBytes: Int64
    }

    public let items: [CleanableItem]
    public let totalBytes: Int64
    public let riskItems: [CleanableItem]
    public let riskBytes: Int64
    public let clientGroups: [ClientGroup]

    public init(selectedIDs: Set<String>, itemsByID: [String: CleanableItem]) {
        let resolved = selectedIDs.compactMap { itemsByID[$0] }
            .filter { $0.hardProtectionReason == nil }
            .sorted { lhs, rhs in
                let lhsIsRisk = !lhs.isCleanable
                let rhsIsRisk = !rhs.isCleanable
                if lhsIsRisk != rhsIsRisk { return lhsIsRisk }
                if lhs.clientName != rhs.clientName {
                    return CoreTextCompare.caseInsensitiveAscending(lhs.clientName, rhs.clientName)
                }
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.id < rhs.id
            }

        var totalBytes: Int64 = 0
        var riskItems: [CleanableItem] = []
        var riskBytes: Int64 = 0
        var byClient: [String: (name: String, items: [CleanableItem], bytes: Int64)] = [:]
        for item in resolved {
            totalBytes += item.sizeBytes
            if !item.isCleanable {
                riskItems.append(item)
                riskBytes += item.sizeBytes
            }
            byClient[item.clientID, default: (item.clientName, [], 0)].items.append(item)
            byClient[item.clientID, default: (item.clientName, [], 0)].bytes += item.sizeBytes
        }

        self.items = resolved
        self.totalBytes = totalBytes
        self.riskItems = riskItems
        self.riskBytes = riskBytes
        self.clientGroups = byClient.map { clientID, client in
            ClientGroup(id: clientID, clientName: client.name, items: client.items, totalBytes: client.bytes)
        }.sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.id < rhs.id
        }
    }
}
