import AICleanerCore
import AppKit
import SwiftUI

struct AddCustomDirectorySheet: View {
    @Bindable var viewModel: CleanerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

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
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(AppTheme.brandGradient.opacity(0.22))
                        .frame(width: 42, height: 42)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Color(red: 0.16, green: 0.78, blue: 0.64).opacity(0.45), lineWidth: 0.9)
                        )
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 0.16, green: 0.80, blue: 0.62))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("添加自定义目录")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("可添加缓存、导出文件或日志所在的文件夹。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

                if resolvedURL != nil {
                    validationBanner
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("显示名称（可选）")
                        .font(.subheadline.weight(.medium))
                    TextField("默认使用文件夹名称", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("类别")
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
                        Text("扫描方式")
                            .font(.subheadline.weight(.medium))
                        Picker("扫描方式", selection: $scanMode) {
                            Text("显示文件夹中的一级条目").tag(ScanTargetMode.children)
                            Text("将整个文件夹作为一项").tag(ScanTargetMode.directory)
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
                .buttonStyle(
                    GlowingPillButtonStyle(
                        gradient: AppTheme.brandGradient,
                        glowColor: Color(red: 0.16, green: 0.78, blue: 0.64),
                        isEnabled: canSubmit
                    )
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(AppTheme.canvasBackground(for: colorScheme))
    }

    @ViewBuilder
    private var validationBanner: some View {
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
                Text("找不到文件夹，请检查路径。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择文件夹"
        panel.message = "选择要扫描的文件夹"

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
