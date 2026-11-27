import { diskLabel, formatBytes } from '../lib/format';
import type { DiskCapacityDTO, PlatformKind } from '../rpc/types';

interface DiskUsageFooterProps {
  capacity: DiskCapacityDTO | null;
  unavailable: boolean;
  lastScanTime: string;
  platform: PlatformKind;
}

export function DiskUsageFooter({ capacity, unavailable, lastScanTime, platform }: DiskUsageFooterProps) {
  const total = capacity?.total ?? null;
  const available = capacity?.available ?? null;
  const used = total !== null && available !== null ? Math.max(0, total - available) : null;
  const usedFraction = total && total > 0 && used !== null ? Math.min(1, Math.max(0, used / total)) : 0;

  return (
    <footer className="disk-footer mono-num" data-testid="disk-usage-footer">
      <div className="disk-footer-row">
        <span style={{ fontWeight: 600 }}>{diskLabel(platform)}</span>
        <span style={{ color: 'var(--text-secondary)' }}>
          总容量 {total !== null ? formatBytes(total) : '—'}
        </span>
      </div>

      <div className="disk-bar-track" aria-hidden="true">
        <div className="disk-bar-fill" style={{ width: `${(usedFraction * 100).toFixed(1)}%` }} />
      </div>

      <div className="disk-footer-row">
        <span>已用 {used !== null ? formatBytes(used) : '—'}</span>
        <span>剩余 {available !== null ? formatBytes(available) : '—'}</span>
      </div>

      <div className="disk-footer-row" style={{ fontSize: 10.5, color: 'var(--text-secondary)' }}>
        <span>上次扫描 {lastScanTime || '—'}</span>
        {unavailable && <span>暂无法读取</span>}
      </div>
    </footer>
  );
}
