import { EyeOff, FolderPlus, Loader2, Shield, Sparkles, TrendingUp, X } from 'lucide-react';
import type { CSSProperties } from 'react';
import { extractCustomDirectoryId, formatBytes } from '../lib/format';
import { accentColorForToken, EXCLUDED_ACCENT_COLOR, RECOMMENDATION_COLORS } from '../lib/theme';
import type {
  ClientSummaryDTO,
  CustomScanDirectoryDTO,
  DiskCapacityDTO,
  PlatformKind,
  ReportSummaryDTO,
  SidebarSelection,
} from '../rpc/types';
import { ClientLogo } from './ClientLogo';
import { DiskUsageFooter } from './DiskUsageFooter';

interface SidebarProps {
  selection: SidebarSelection;
  onSelect: (selection: SidebarSelection) => void;
  isScanning: boolean;
  reportSummary: ReportSummaryDTO | null;
  clients: ClientSummaryDTO[];
  customDirs: CustomScanDirectoryDTO[];
  onRemoveCustomDir: (id: string) => void;
  historicalFreedBytes: number;
  excludedCount: number;
  diskCapacity: DiskCapacityDTO | null;
  diskUnavailable: boolean;
  lastScanTime: string;
  platform: PlatformKind;
  effectiveTheme: 'light' | 'dark';
}

export function Sidebar({
  selection,
  onSelect,
  isScanning,
  reportSummary,
  clients,
  customDirs,
  onRemoveCustomDir,
  historicalFreedBytes,
  excludedCount,
  diskCapacity,
  diskUnavailable,
  lastScanTime,
  platform,
  effectiveTheme,
}: SidebarProps) {
  const builtInClients = clients.filter((c) => c.kind === 'builtInClient');
  const tempClients = clients.filter((c) => c.kind === 'otherAITemp' || c.kind === 'unattributedTemp');
  const customClients = clients.filter((c) => c.kind === 'customDirectory');

  const overviewBytesText = reportSummary
    ? reportSummary.totalSizeBytes > 0
      ? formatBytes(reportSummary.totalSizeBytes)
      : reportSummary.protectedSizeBytes > 0
        ? ''
        : '0 B'
    : '待扫描';

  const overviewProtectedOnly = Boolean(
    reportSummary && reportSummary.totalSizeBytes === 0 && reportSummary.protectedSizeBytes > 0
  );

  return (
    <aside className="sidebar" aria-label="主导航侧栏">
      <div className="sidebar-header" data-tauri-drag-region>
        <div className={`brand-emblem ${isScanning ? 'scanning' : ''}`} aria-hidden="true">
          <Sparkles size={13} />
        </div>
        <span className="brand-title">AI Cleaner</span>
        <span style={{ flex: 1 }} />
        {isScanning && <Loader2 size={14} className="spin-icon" style={{ color: 'var(--text-secondary)' }} />}
      </div>

      <nav className="sidebar-scroll">
        <div className="sidebar-section-header">
          <span>总览</span>
        </div>

        <button
          type="button"
          className={`sidebar-tile ${selection.kind === 'allClients' ? 'selected' : ''}`}
          style={{ '--tile-tint': '#29cc99' } as CSSProperties}
          onClick={() => onSelect({ kind: 'allClients' })}
          data-testid="nav-all-clients"
        >
          <Sparkles size={16} style={{ color: '#29cc99', flexShrink: 0 }} />
          <span className="sidebar-tile-title">空间总览</span>
          {overviewProtectedOnly ? (
            <Shield size={13} style={{ color: 'var(--accent-risk)' }} aria-label="仅受保护数据" />
          ) : (
            <span className="sidebar-tile-meta mono-num">{overviewBytesText}</span>
          )}
        </button>

        <button
          type="button"
          className={`sidebar-tile ${selection.kind === 'history' ? 'selected' : ''}`}
          style={{ '--tile-tint': '#3db8fa' } as CSSProperties}
          onClick={() => onSelect({ kind: 'history' })}
          data-testid="nav-history"
          title={`累计已清理 ${formatBytes(historicalFreedBytes)}`}
        >
          <TrendingUp size={16} style={{ color: '#3db8fa', flexShrink: 0 }} />
          <span className="sidebar-tile-title">清理记录</span>
          <span
            className="sidebar-tile-meta mono-num"
            style={historicalFreedBytes > 0 ? { color: RECOMMENDATION_COLORS.recommended, fontWeight: 600 } : undefined}
          >
            {historicalFreedBytes > 0 ? formatBytes(historicalFreedBytes) : '暂无'}
          </span>
        </button>

        <button
          type="button"
          className={`sidebar-tile ${selection.kind === 'excluded' ? 'selected' : ''}`}
          style={{ '--tile-tint': EXCLUDED_ACCENT_COLOR } as CSSProperties}
          onClick={() => onSelect({ kind: 'excluded' })}
          data-testid="nav-excluded"
          title={excludedCount > 0 ? `已排除 ${excludedCount} 项，扫描时自动跳过` : '查看已排除的清理条目'}
        >
          <EyeOff size={16} style={{ color: EXCLUDED_ACCENT_COLOR, flexShrink: 0 }} />
          <span className="sidebar-tile-title">已排除</span>
          <span
            className="sidebar-tile-meta mono-num"
            style={excludedCount > 0 ? { color: EXCLUDED_ACCENT_COLOR, fontWeight: 600 } : undefined}
          >
            {excludedCount > 0 ? `${excludedCount} 项` : '0'}
          </span>
        </button>

        <div className="sidebar-section-header">
          <span>AI 客户端</span>
          <span className="mono-num">
            {isScanning
              ? '扫描中'
              : reportSummary
                ? `${reportSummary.detectedBuiltInClientsCount}`
                : '待扫描'}
          </span>
        </div>

        {reportSummary && !isScanning && builtInClients.length === 0 ? (
          <div className="sidebar-empty-hint">未检测到已安装的 AI 客户端</div>
        ) : (
          builtInClients.map((client) => {
            const isSelected =
              (selection.kind === 'client' || selection.kind === 'clientProjects') &&
              selection.clientId === client.id;
            const tint = accentColorForToken(client.accentToken);
            const protectedOnly = client.totalSizeBytes === 0 && client.protectedSizeBytes > 0;
            return (
              <button
                key={client.id}
                type="button"
                className={`sidebar-tile ${isSelected ? 'selected' : ''}`}
                style={{ '--tile-tint': tint } as CSSProperties}
                onClick={() => onSelect({ kind: 'client', clientId: client.id })}
                data-testid={`nav-client-${client.id}`}
              >
                <ClientLogo clientId={client.id} effectiveTheme={effectiveTheme} size={18} />
                <span className="sidebar-tile-title">{client.name}</span>
                {protectedOnly ? (
                  <Shield size={13} style={{ color: 'var(--accent-risk)' }} aria-label="仅受保护数据" />
                ) : (
                  <span className="sidebar-tile-meta mono-num">
                    {formatBytes(client.totalSizeBytes)}
                  </span>
                )}
              </button>
            );
          })
        )}

        {tempClients.length > 0 && (
          <>
            <div className="sidebar-section-header">
              <span>系统临时目录</span>
            </div>
            {tempClients.map((client) => {
              const isSelected = selection.kind === 'client' && selection.clientId === client.id;
              const tint = accentColorForToken(client.accentToken);
              return (
                <button
                  key={client.id}
                  type="button"
                  className={`sidebar-tile ${isSelected ? 'selected' : ''}`}
                  style={{ '--tile-tint': tint } as CSSProperties}
                  onClick={() => onSelect({ kind: 'client', clientId: client.id })}
                  data-testid={`nav-client-${client.id}`}
                >
                  <ClientLogo clientId={client.id} effectiveTheme={effectiveTheme} size={18} />
                  <span className="sidebar-tile-title">{client.name}</span>
                  <span className="sidebar-tile-meta mono-num">{formatBytes(client.totalSizeBytes)}</span>
                </button>
              );
            })}
          </>
        )}

        <div className="sidebar-section-header">
          <span>自定义目录</span>
          {customDirs.length > 0 && <span className="mono-num">{customDirs.length}</span>}
        </div>

        {customClients.length > 0 ? (
          customClients.map((client) => {
            const isSelected = selection.kind === 'client' && selection.clientId === client.id;
            const customId = extractCustomDirectoryId(client.id);
            return (
              <div key={client.id} className="sidebar-tile-row">
                <button
                  type="button"
                  className={`sidebar-tile ${isSelected ? 'selected' : ''}`}
                  style={{ '--tile-tint': '#14b8a6' } as CSSProperties}
                  onClick={() => onSelect({ kind: 'client', clientId: client.id })}
                  data-testid={`nav-client-${client.id}`}
                >
                  <FolderPlus size={16} style={{ color: '#14b8a6', flexShrink: 0 }} />
                  <span className="sidebar-tile-title">{client.name}</span>
                  <span className="sidebar-tile-meta mono-num">{formatBytes(client.totalSizeBytes)}</span>
                </button>
                {customId && (
                  <button
                    type="button"
                    className="sidebar-tile-remove"
                    title="从扫描列表移除目录（保留文件）"
                    aria-label={`移除自定义目录 ${client.name}`}
                    onClick={() => onRemoveCustomDir(customId)}
                  >
                    <X size={12} />
                  </button>
                )}
              </div>
            );
          })
        ) : customDirs.length > 0 ? (
          customDirs.map((dir) => (
            <div key={dir.id} className="sidebar-tile-row">
              <div className="sidebar-tile" style={{ cursor: 'default' }}>
                <FolderPlus size={15} style={{ color: '#14b8a6', flexShrink: 0 }} />
                <span className="sidebar-tile-title">{dir.displayName}</span>
                <span className="sidebar-tile-meta">待扫描</span>
              </div>
              <button
                type="button"
                className="sidebar-tile-remove"
                title="从扫描列表移除目录（保留文件）"
                aria-label={`移除自定义目录 ${dir.displayName}`}
                onClick={() => onRemoveCustomDir(dir.id)}
              >
                <X size={12} />
              </button>
            </div>
          ))
        ) : (
          <div className="sidebar-empty-hint">点击右上角添加自定义目录</div>
        )}
      </nav>

      <DiskUsageFooter
        capacity={diskCapacity}
        unavailable={diskUnavailable}
        lastScanTime={lastScanTime}
        platform={platform}
      />
    </aside>
  );
}
