import AICleanerCore
import SwiftUI

struct DiskUsageFooterView: View {
    let state: DiskUsageRefreshCoordinator.State
    let lastScanTime: String

    var body: some View {
        let snapshot = state.snapshot

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("启动磁盘")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text("总容量 \(capacityText(snapshot?.totalBytes))")
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * (snapshot?.usedFraction ?? 0))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                Text("已用 \(capacityText(snapshot?.usedBytes))")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("剩余 \(capacityText(snapshot?.availableBytes))")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                Text("上次扫描 \(lastScanTime.isEmpty ? "—" : lastScanTime)")
                Spacer(minLength: 0)
                if state == .unavailable {
                    Text("暂无法读取")
                } else if case .stale = state {
                    Text("暂未更新")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 16)
        .frame(height: 80)
        .overlay(alignment: .top) { Divider() }
    }

    private func capacityText(_ bytes: Int64?) -> String {
        bytes.map(CleanerFormatting.formatBytes) ?? "—"
    }
}
