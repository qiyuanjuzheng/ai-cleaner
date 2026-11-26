#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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
/// - 全部经由 `PlatformAdapter` 读取文件身份与目录子项，不修改任何文件或目录属性；
/// - 绝不递归穿透符号链接或 Windows 重解析点/目录联接，避免循环引用、越界与重复计费；
/// - 同步检测内部是否存在受保护的凭据/配置/数据库文件或特殊系统节点。
public struct DirectorySizer: Sendable {
    public let platform: any PlatformAdapter

    public init(platform: any PlatformAdapter = HostPlatformAdapter.shared) {
        self.platform = platform
    }

    public func inspect(
        url: URL,
        safetyGuard: SafetyGuard? = nil,
        fileManager: FileManager = .default,
        descendantValidator: ((URL, FileIdentity) -> String?)? = nil
    ) -> PathInspectionResult? {
        guard let rootIdentity = try? platform.identity(at: url) else {
            return nil
        }

        if safetyGuard != nil, rootIdentity.kind.isSpecialNode {
            return PathInspectionResult(
                sizeBytes: 0,
                fileCount: 0,
                modifiedAt: rootIdentity.modifiedAt,
                isDirectory: false,
                protectedDescendantReason: "\(url.lastPathComponent)：特殊系统节点（Socket/FIFO/设备文件）不允许清理"
            )
        }

        let isDirectory = rootIdentity.kind == .directory
        var latestModified = rootIdentity.modifiedAt

        if !isDirectory {
            return PathInspectionResult(
                sizeBytes: max(0, rootIdentity.size),
                fileCount: 1,
                modifiedAt: latestModified,
                isDirectory: false,
                protectedDescendantReason: nil
            )
        }

        var totalBytes: Int64 = 0
        var totalFiles = 0
        var protectedReason: String?

        var dirStack: [URL] = [url]
        while let currentDir = dirStack.popLast(), protectedReason == nil {
            if Task.isCancelled {
                break
            }
            let children: [URL]
            do {
                children = try withCoreAutoreleasePool {
                    try platform.contentsOfDirectory(at: currentDir)
                }
            } catch {
                if safetyGuard != nil && platform.platform != .macos {
                    protectedReason = "无法检查目录：\(currentDir.lastPathComponent)"
                }
                continue
            }

            for childURL in children {
                if Task.isCancelled {
                    break
                }
                guard let identity = try? platform.identity(at: childURL) else {
                    if safetyGuard != nil && platform.platform != .macos {
                        protectedReason = "无法检查目录内的条目：\(childURL.lastPathComponent)"
                        break
                    }
                    continue
                }

                let childIsLink = identity.kind.isLinkOrReparsePoint
                let childIsDir = identity.kind == .directory

                if let safetyGuard {
                    if platform.platform == .linux && childIsDir && identity.volumeID != rootIdentity.volumeID {
                        protectedReason = "目录内包含其他挂载卷：\(childURL.lastPathComponent)"
                        break
                    }
                    let decision = safetyGuard.validateDescendant(at: childURL, identity: identity)
                    if let reason = decision.blockReason {
                        protectedReason = "\(childURL.lastPathComponent)：\(reason)"
                        break
                    }
                }

                if let descendantValidator, let reason = descendantValidator(childURL, identity) {
                    protectedReason = reason
                    break
                }

                if identity.modifiedAt > latestModified {
                    latestModified = identity.modifiedAt
                }

                if childIsLink {
                    // 绝不跟随符号链接或 Windows 重解析点/目录联接深入子目录，按链接本身大小计入 1 项
                    totalBytes += max(0, identity.size)
                    totalFiles += 1
                    continue
                }

                if identity.kind == .regular {
                    totalBytes += max(0, identity.size)
                    totalFiles += 1
                } else if childIsDir {
                    dirStack.append(childURL)
                }
            }
        }

        return PathInspectionResult(
            sizeBytes: totalBytes,
            fileCount: totalFiles,
            modifiedAt: latestModified,
            isDirectory: true,
            protectedDescendantReason: protectedReason
        )
    }
}
