#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum ScanItemAge: String, CaseIterable, Codable, Sendable {
    case all, olderThan7Days, olderThan30Days, olderThan90Days

    public func cutoffDate(relativeTo now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let days: Int
        switch self {
        case .all: return nil
        case .olderThan7Days: days = 7
        case .olderThan30Days: days = 30
        case .olderThan90Days: days = 90
        }
        return calendar.date(byAdding: .day, value: -days, to: now)
    }
}

public enum ScanItemSort: String, CaseIterable, Codable, Sendable {
    case sizeDescending = "sizeDesc"
    case sizeAscending = "sizeAsc"
    case modifiedDescending = "modifiedDesc"
    case modifiedAscending = "modifiedAsc"
    case nameAscending = "nameAsc"

    public func sorting(_ items: [CleanableItem]) -> [CleanableItem] {
        items.sorted { lhs, rhs in
            switch self {
            case .sizeDescending:
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.modifiedAt > rhs.modifiedAt
            case .sizeAscending:
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
                return lhs.modifiedAt < rhs.modifiedAt
            case .modifiedDescending:
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.sizeBytes > rhs.sizeBytes
            case .modifiedAscending:
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
                return lhs.sizeBytes > rhs.sizeBytes
            case .nameAscending:
                return CoreTextCompare.naturalAscending(lhs.preferredDisplayTitle, rhs.preferredDisplayTitle)
            }
        }
    }
}

public struct ScanItemFilter: Sendable {
    public let search: String
    public let category: ScanCategory?
    public let recommendation: CleanupRecommendation?
    public let age: ScanItemAge

    public init(
        search: String = "",
        category: ScanCategory? = nil,
        recommendation: CleanupRecommendation? = nil,
        age: ScanItemAge = .all
    ) {
        self.search = search.trimmedWhitespaceAndNewlines().lowercased()
        self.category = category
        self.recommendation = recommendation
        self.age = age
    }

    /// Filtering preserves input order, including when the caller caches a sorted list.
    public func applying(
        to items: [CleanableItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        modificationDate: (CleanableItem) -> Date? = { $0.isCleanable ? $0.modifiedAt : nil },
        searchIndex: (String) -> String? = { _ in nil }
    ) -> [CleanableItem] {
        let cutoff = age.cutoffDate(relativeTo: now, calendar: calendar)
        guard !search.isEmpty || category != nil || recommendation != nil || cutoff != nil else { return items }
        return items.filter { item in
            if let recommendation, item.recommendation != recommendation { return false }
            if let category, item.category != category { return false }
            if let cutoff {
                guard let date = modificationDate(item), date < cutoff else { return false }
            }
            if search.isEmpty { return true }
            return (searchIndex(item.id) ?? Self.searchableText(for: item)).contains(search)
        }
    }

    public static func searchableText(for item: CleanableItem) -> String {
        let fields: [String?] = [
            item.preferredDisplayTitle, item.sessionTitle, item.sessionProjectName, item.displayName,
            item.fileName, item.url.path, item.clientName, item.category.displayName,
            item.recommendation.displayName, item.safetyNote, item.sourceBadge,
            item.isRecentlyModified ? "近期修改" : nil
        ]
        return fields.compactMap { $0 }.joined(separator: "\u{1F}").lowercased()
    }
}

public struct ScanItemBuckets: Sendable {
    public struct Section: Identifiable, Sendable {
        public let recommendation: CleanupRecommendation
        public let items: [CleanableItem]
        public let totalBytes: Int64

        public var id: CleanupRecommendation { recommendation }
    }

    public let sections: [Section]
    public let bulkSelectable: [CleanableItem]
    public let maximumBytes: Int64

    /// The items retain their original order within each recommendation section.
    public init(items: [CleanableItem]) {
        var buckets: [CleanupRecommendation: (items: [CleanableItem], bytes: Int64)] = [:]
        var bulkSelectable: [CleanableItem] = []
        bulkSelectable.reserveCapacity(items.count)
        var maximumBytes: Int64 = 0
        for item in items {
            maximumBytes = max(maximumBytes, item.sizeBytes)
            if item.isBulkSelectable { bulkSelectable.append(item) }
            buckets[item.recommendation, default: ([], 0)].items.append(item)
            buckets[item.recommendation, default: ([], 0)].bytes += item.sizeBytes
        }
        self.sections = CleanupRecommendation.allCases.compactMap { recommendation in
            guard let bucket = buckets[recommendation] else { return nil }
            return Section(recommendation: recommendation, items: bucket.items, totalBytes: bucket.bytes)
        }
        self.bulkSelectable = bulkSelectable
        self.maximumBytes = maximumBytes
    }
}
