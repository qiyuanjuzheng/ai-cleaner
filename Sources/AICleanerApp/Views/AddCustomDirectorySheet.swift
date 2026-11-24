import AICleanerCore
import AppKit
import SwiftUI

struct AddCustomDirectorySheet: View {
    @Bindable var viewModel: CleanerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pathText: String = ""
    @State private var displayName: String = ""
    @State private var category: ScanCategory = .custom
    @State private var scanMode: ScanTargetMode = .children
    @State private var submitError: String?

    private var resolvedURL: URL? {
        let trimmed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private var liveValidation: SafetyDecision? {
        guard let url = resolvedURL else { return nil }
        return viewModel.validateCustomDirectory(url)
    }

    private var directoryExists: Bool {
        guard let url = resolvedURL else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private var canSubmit: Bool {
        guard resolvedURL != nil, directoryExists else { return false }
        return liveValidation?.isAllowed == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("添加自定义扫描目录")
                    .font(.title3.weight(.semibold))
                Text("将自定义 AI 缓存、导出或日志目录加入侧边栏扫描列表。扫描严格只读，且仍会自动排除敏感凭据与数据库文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("目录路径")
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 8) {
                        TextField("例如：~/Library/Caches/my-ai-tool", text: $pathText)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: pathText) { _, _ in
                                submitError = nil
                            }

                        Button("选择文件夹…") {
                            pickDirectory()
                        }
                    }
                }

                if let url = resolvedURL {
                    validationBanner(url: url)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("显示名称（可选）")
                        .font(.subheadline.weight(.medium))
                    TextField("默认使用文件夹名称", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("默认类别标签")
                            .font(.subheadline.weight(.medium))
                        Picker("类别", selection: $category) {
                            ForEach(ScanCategory.userSelectableCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("扫描粒度")
                            .font(.subheadline.weight(.medium))
                        Picker("扫描粒度", selection: $scanMode) {
                            Text("展开一级子项（推荐）").tag(ScanTargetMode.children)
                            Text("作为整体目录").tag(ScanTargetMode.directory)
                        }
                        .labelsHidden()
                    }
                }

                if let submitError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(submitError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("添加并扫描") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    @ViewBuilder
    private func validationBanner(url: URL) -> some View {
        if let decision = liveValidation, let reason = decision.blockReason {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shield.slash.fill")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.red.opacity(0.08))
            )
        } else if !directoryExists {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.questionmark")
                    .foregroundStyle(.orange)
                Text("未找到该文件夹，请检查路径是否正确：\(url.path)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("已通过安全路径校验，扫描时将自动跳过目录内的凭据、配置与数据库文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.green.opacity(0.08))
            )
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择目录"
        panel.message = "请选择要纳入只读扫描的缓存或临时文件夹"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            pathText = selectedURL.path
            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = selectedURL.lastPathComponent
            }
            submitError = nil
        }
    }

    private func submit() {
        guard let url = resolvedURL else { return }
        do {
            try viewModel.addCustomDirectory(
                url: url,
                displayName: displayName,
                category: category,
                mode: scanMode
            )
            dismiss()
        } catch {
            submitError = error.localizedDescription
        }
    }
}
