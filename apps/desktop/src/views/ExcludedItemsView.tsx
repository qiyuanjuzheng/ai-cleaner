import { Copy, EyeOff, FolderOpen, RotateCcw, Search, Sparkles, X } from 'lucide-react';
import { useMemo, useState } from 'react';
import {
  abbreviatePath,
  categoryDisplayName,
  formatDateTime,
  revealActionTitle,
} from '../lib/format';
import { CATEGORY_COLORS, EXCLUDED_ACCENT_COLOR } from '../lib/theme';
import type { ExcludedItemRecordDTO, PlatformKind } from '../rpc/types';
import { ClientLogo } from '../components/ClientLogo';

interface ExcludedItemsViewProps {
  visible: boolean;
  records: ExcludedItemRecordDTO[];
  statuses: Record<string, boolean>;
  hasScanResults: boolean;
  platform: PlatformKind;
  effectiveTheme: 'light' | 'dark';
  onRestore: (id: string) => Promise<void>;
  onRestoreAll: () => Promise<void>;
  onReveal: (record: ExcludedItemRecordDTO) => void;
  onCopyPath: (path: string) => void;
  onBackToOverview: () => void;
}

export function ExcludedItemsView({
  visible,
  records,
  statuses,
  hasScanResults,
  platform,
  effectiveTheme,
  onRestore,
  onRestoreAll,
  onReveal,
  onCopyPath,
  onBackToOverview,
}: ExcludedItemsViewProps) {
  const [search, setSearch] = useState('');

  const missingCount = useMemo(
    () => records.filter((rec) => statuses[rec.id] === false).length,
    [records, statuses]
  );

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return records;
    return records.filter(
      (rec) =>
        rec.displayName.toLowerCase().includes(q) ||
        rec.clientName.toLowerCase().includes(q) ||
        rec.normalizedPath.toLowerCase().includes(q) ||
        categoryDisplayName(rec.category).toLowerCase().includes(q) ||
        (rec.sessionProjectName?.toLowerCase().includes(q) ?? false)
    );
  }, [records, search]);

  if (!visible) return null;

  const subtitle =
    records.length === 0
      ? '右键任意扫描条目即可将其排除，后续扫描将自动跳过'
      : missingCount > 0
        ? `共 ${records.length} 项在扫描时自动跳过 · ${missingCount} 项路径已不存在`
        : `共 ${records.length} 项在扫描时自动跳过`;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 }} data-testid="excluded-items-view">
      <div style={{ padding: '4px 20px 12px', display: 'flex', alignItems: 'center', gap: 12, flexShrink: 0 }}>
        <div>
          <h1 style={{ margin: '0 0 2px', fontSize: 20, fontWeight: 700 }}>已排除</h1>
          <div className="mono-num" style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
            {subtitle}
          </div>
        </div>

        <span style={{ flex: 1 }} />

        {records.length > 0 && (
          <div className="search-box">
            <Search size={13} style={{ color: 'var(--text-tertiary)', flexShrink: 0 }} />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="搜索已排除条目或路径…"
              aria-label="搜索已排除条目"
            />
            {search && (
              <button
                type="button"
                style={{ border: 'none', background: 'transparent', padding: 0, color: 'var(--text-tertiary)' }}
                onClick={() => setSearch('')}
                aria-label="清空搜索"
              >
                <X size={13} />
              </button>
            )}
          </div>
        )}

        {records.length > 1 && (
          <button
            type="button"
            className="btn-subtle-pill"
            style={{
              color: EXCLUDED_ACCENT_COLOR,
              borderColor: 'rgba(143, 128, 245, 0.36)',
              background: 'rgba(143, 128, 245, 0.12)',
            }}
            onClick={() => {
              setSearch('');
              void onRestoreAll();
            }}
            data-testid="restore-all-excluded-btn"
          >
            <RotateCcw size={13} />
            <span>全部恢复</span>
          </button>
        )}
      </div>

      {records.length === 0 ? (
        <div className="hero-center-stage" data-testid="excluded-empty-state">
          <div
            style={{
              width: 54,
              height: 54,
              borderRadius: '50%',
              background: 'rgba(143, 128, 245, 0.14)',
              color: EXCLUDED_ACCENT_COLOR,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <EyeOff size={22} />
          </div>
          <h3 style={{ margin: 0 }}>暂无已排除条目</h3>
          <p style={{ margin: 0, maxWidth: 400, textAlign: 'center', color: 'var(--text-secondary)' }}>
            在待清理列表中右键点击任意条目并选择「排除此条目（不再显示）」，即可将其从扫描结果与统计中隐藏。
          </p>
          <button type="button" className="btn-glow-primary" onClick={onBackToOverview}>
            <Sparkles size={13} />
            <span>{hasScanResults ? '查看扫描结果' : '返回扫描'}</span>
          </button>
        </div>
      ) : filtered.length === 0 ? (
        <div className="hero-center-stage">
          <h3 style={{ margin: 0 }}>没有匹配的已排除条目</h3>
          <button type="button" className="btn-glow-primary" onClick={() => setSearch('')}>
            清空搜索
          </button>
        </div>
      ) : (
        <div style={{ flex: 1, overflowY: 'auto', padding: '0 20px 24px' }}>
          <div className="glass-card" style={{ overflow: 'hidden' }}>
            {filtered.map((rec, idx) => {
              const exists = statuses[rec.id] !== false;
              const catColor = CATEGORY_COLORS[rec.category];
              return (
                <div
                  key={rec.id}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 10,
                    padding: '11px 14px',
                    borderBottom: idx < filtered.length - 1 ? '1px solid var(--divider)' : 'none',
                  }}
                  data-testid="excluded-row"
                >
                  <ClientLogo clientId={rec.clientID} effectiveTheme={effectiveTheme} size={20} />

                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
                      <span style={{ fontWeight: 600 }}>{rec.displayName}</span>
                      <span
                        className="badge-pill"
                        style={{
                          background: `color-mix(in srgb, ${catColor} 14%, transparent)`,
                          color: catColor,
                        }}
                      >
                        {categoryDisplayName(rec.category)}
                      </span>
                      <span className="badge-pill" style={{ background: 'var(--surface-muted)', color: 'var(--text-secondary)' }}>
                        {rec.clientName}
                      </span>
                      {!exists && (
                        <span
                          className="badge-pill"
                          style={{ background: 'rgba(250, 168, 56, 0.16)', color: 'var(--accent-review)' }}
                        >
                          路径不存在
                        </span>
                      )}
                    </div>
                    <div
                      className="mono-path"
                      style={{
                        fontSize: 11.5,
                        color: 'var(--text-secondary)',
                        overflow: 'hidden',
                        textOverflow: 'ellipsis',
                        whiteSpace: 'nowrap',
                        marginTop: 2,
                      }}
                    >
                      {abbreviatePath(rec.normalizedPath, platform)} · 排除于 {formatDateTime(rec.excludedAt)}
                    </div>
                  </div>

                  <button
                    type="button"
                    className="row-action-btn"
                    title={revealActionTitle(platform)}
                    onClick={() => onReveal(rec)}
                  >
                    <FolderOpen size={14} />
                  </button>
                  <button
                    type="button"
                    className="row-action-btn"
                    title="复制完整路径"
                    onClick={() => onCopyPath(rec.normalizedPath)}
                  >
                    <Copy size={14} />
                  </button>
                  <button
                    type="button"
                    className="btn-subtle-pill"
                    style={{ height: 28, color: EXCLUDED_ACCENT_COLOR }}
                    onClick={() => void onRestore(rec.id)}
                    data-testid="restore-excluded-btn"
                  >
                    <RotateCcw size={12} />
                    <span>恢复</span>
                  </button>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
