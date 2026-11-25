import Foundation

/// 单次目录/文件只读体积与安全检测的统计结果
public struct PathInspectionResult: Sendable {
    public let sizeBytes: Int64
    public let fileCount: Int
    public let modifiedAt: Date
    public let isDirectory: Bool
    /// 若在目录内发现受保护文件/目录，记录首个命中信息以触发安全拦截
    public let protectedDescendantReason: String?

    public init(
        sizeBytes: Int64,
        fileCount: Int,
        modifiedAt: Date,
        isDirectory: Bool,
        protectedDescendantReason: String? = nil
    ) {
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.protectedDescendantReason = protectedDescendantReason
    }
}

/// 严格只读的目录体积与元数据计算器：
/// - 不修改任何文件或目录属性；
/// - 不递归穿透符号链接，避免循环引用与重复计费；
/// - 同步检测内部是否存在受保护的凭据/配置/数据库文件。
public struct DirectorySizer: Sendable {
    public init() {}

    public func inspect(
        url: URL,
        safetyGuard: SafetyGuard? = nil,
        fileManager: FileManager = .default,
        descendantValidator: ((URL, URLResourceValues) -> String?)? = nil
    ) -> PathInspectionResult? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileResourceTypeKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .contentModificationDateKey
        ]

        guard let rootValues = try? url.resourceValues(forKeys: keys) else {
            return nil
        }

        if safetyGuard != nil,
           let rootType = rootValues.fileResourceType,
           rootType == .socket || rootType == .namedPipe || rootType == .characterSpecial || rootType == .blockSpecial {
            return PathInspectionResult(
                sizeBytes: 0,
                fileCount: 0,
                modifiedAt: rootValues.contentModificationDate ?? Date(),
                isDirectory: false,
                protectedDescendantReason: "\(url.lastPathComponent)：特殊系统节点（Socket/FIFO/设备文件）不允许清理"
            )
        }

        let isSymlink = rootValues.isSymbolicLink ?? false
        let isDirectory = (rootValues.isDirectory ?? false) && !isSymlink
        var latestModified = rootValues.contentModificationDate ?? .distantPast

        if !isDirectory {
            let size = Int64(rootValues.totalFileSize ?? rootValues.fileSize ?? 0)
            return PathInspectionResult(
                sizeBytes: max(0, size),
                fileCount: 1,
                modifiedAt: latestModified == .distantPast ? Date() : latestModified,
                isDirectory: false,
                protectedDescendantReason: nil
            )
        }

        var totalBytes: Int64 = 0
        var totalFiles = 0
        var protectedReason: String?

        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) {
            while let childURL = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                if Task.isCancelled {
                    break
                }

                guard let values = try? childURL.resourceValues(forKeys: keys) else {
                    continue
                }

                let childIsSymlink = values.isSymbolicLink ?? false
                let childIsDir = (values.isDirectory ?? false) && !childIsSymlink

                if safetyGuard != nil,
                   let resourceType = values.fileResourceType,
                   resourceType == .socket || resourceType == .namedPipe || resourceType == .characterSpecial || resourceType == .blockSpecial {
                    protectedReason = "\(childURL.lastPathComponent)：特殊系统节点（Socket/FIFO/设备文件）不允许清理"
                    break
                }

                if let safetyGuard {
                    let decision = safetyGuard.validateEntry(url: childURL, isDirectory: childIsDir)
                    if let reason = decision.blockReason {
                        protectedReason = "\(childURL.lastPathComponent)：\(reason)"
                        break
                    }
                }

                if let descendantValidator, let reason = descendantValidator(childURL, values) {
                    protectedReason = reason
                    break
                }

                if let modDate = values.contentModificationDate, modDate > latestModified {
                    latestModified = modDate
                }

                if childIsSymlink {
                    // 不跟随符号链接深入子目录，且按链接本身大小计入 1 项
                    let linkSize = Int64(values.fileSize ?? 0)
                    totalBytes += max(0, linkSize)
                    totalFiles += 1
                    continue
                }

                if values.isRegularFile == true {
                    let size = Int64(values.totalFileSize ?? values.fileSize ?? 0)
                    totalBytes += max(0, size)
                    totalFiles += 1
                }
            }
        }

        return PathInspectionResult(
            sizeBytes: totalBytes,
            fileCount: totalFiles,
            modifiedAt: latestModified == .distantPast ? Date() : latestModified,
            isDirectory: true,
            protectedDescendantReason: protectedReason
        )
    }
}
