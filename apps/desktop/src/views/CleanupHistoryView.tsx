import { ChevronLeft, ChevronRight, MoreHorizontal, Trash2 } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import {
  formatBytes,
  formatDateTime,
  formatFullDate,
  formatShortMonthDay,
  trashName,
} from '../lib/format';
import {
  addLocalDays,
  paginateRecentRecords,
  summarizeCleanupHistory,
  TREND_RANGE_OPTIONS,
} from '../lib/historyAnalytics';
import type { CleanupTrendMetricMode, CleanupTrendPoint, CleanupTrendRange } from '../lib/historyAnalytics';
import { clientAccentById, RECOMMENDATION_COLORS } from '../lib/theme';
import type { CleanupHistoryRecordDTO, PlatformKind } from '../rpc/types';
import { ClientLogo } from '../components/ClientLogo';

interface CleanupHistoryViewProps {
  visible: boolean;
  records: CleanupHistoryRecordDTO[];
  platform: PlatformKind;
  effectiveTheme: 'light' | 'dark';
  onDeleteRecord: (id: string) => Promise<void>;
  onClearAll: () => Promise<void>;
}

export function CleanupHistoryView({
  visible,
  records,
  platform,
  effectiveTheme,
  onDeleteRecord,
  onClearAll,
}: CleanupHistoryViewProps) {
  const [range, setRange] = useState<CleanupTrendRange>('days30');
  const [metricMode, setMetricMode] = useState<CleanupTrendMetricMode>('cumulative');
  const [recentPageNumber, setRecentPageNumber] = useState(1);
  const [hoveredIndex, setHoveredIndex] = useState<number | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmClearOpen, setConfirmClearOpen] = useState(false);

  const summary = useMemo(() => summarizeCleanupHistory(records, range), [records, range]);
  const pagedRecent = useMemo(
    () => paginateRecentRecords(summary.recentRecords, recentPageNumber, 5),
    [summary.recentRecords, recentPageNumber]
  );

  useEffect(() => {
    setRecentPageNumber(1);
    setHoveredIndex(null);
  }, [range]);

  useEffect(() => {
    if (!menuOpen) return;
    const close = () => setMenuOpen(false);
    window.addEventListener('click', close);
    return () => window.removeEventListener('click', close);
  }, [menuOpen]);

  const tickIndices = useMemo(() => {
    const pts = summary.points;
    if (pts.length <= 1) return pts.map((_, i) => i);
    const desired = Math.min(6, pts.length);
    const out: number[] = [];
    for (let k = 0; k < desired; k += 1) {
      const idx = Math.round((k * (pts.length - 1)) / (desired - 1));
      if (!out.includes(idx)) out.push(idx);
    }
    return out;
  }, [summary.points]);

  if (!visible) return null;

  const trash = trashName(platform);
  const rangeLabel = TREND_RANGE_OPTIONS.find((r) => r.id === range)?.label ?? '全部';
  const points = summary.points;

  // SVG chart dimensions
  const width = 760;
  const height = 210;
  const padLeft = 64;
  const padRight = 18;
  const padTop = 18;
  const padBottom = 30;
  const plotW = width - padLeft - padRight;
  const plotH = height - padTop - padBottom;

  const metricValues = points.map((p) => (metricMode === 'cumulative' ? p.cumulativeFreedBytes : p.dailyFreedBytes));
  const rawMax = metricValues.reduce((m, v) => Math.max(m, v), 0);
  const yMax = rawMax > 0 ? rawMax * 1.12 : 1024;

  const xForIndex = (idx: number): number => {
    if (points.length <= 1) return padLeft + plotW / 2;
    return padLeft + (idx / (points.length - 1)) * plotW;
  };

  const yForValue = (val: number): number => {
    const ratio = Math.min(1, Math.max(0, val / yMax));
    return padTop + plotH * (1 - ratio);
  };

  const linePath = points
    .map((p, i) => `${i === 0 ? 'M' : 'L'} ${xForIndex(i).toFixed(1)} ${yForValue(metricMode === 'cumulative' ? p.cumulativeFreedBytes : p.dailyFreedBytes).toFixed(1)}`)
    .join(' ');

  const areaPath =
    points.length > 0
      ? `${linePath} L ${xForIndex(points.length - 1).toFixed(1)} ${(padTop + plotH).toFixed(1)} L ${xForIndex(0).toFixed(1)} ${(padTop + plotH).toFixed(1)} Z`
      : '';

  const hoveredPoint: CleanupTrendPoint | null =
    hoveredIndex !== null && hoveredIndex >= 0 && hoveredIndex < points.length ? points[hoveredIndex] : null;

  const handleSvgMouseMove = (e: React.MouseEvent<SVGSVGElement>) => {
    if (points.length === 0) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const relX = ((e.clientX - rect.left) / rect.width) * width;
    const clamped = Math.max(padLeft, Math.min(padLeft + plotW, relX));
    if (points.length === 1) {
      setHoveredIndex(0);
      return;
    }
    const idx = Math.round(((clamped - padLeft) / plotW) * (points.length - 1));
    setHoveredIndex(Math.max(0, Math.min(points.length - 1, idx)));
  };

  const barWidth = points.length > 0 ? Math.max(4, Math.min(28, (plotW / points.length) * 0.62)) : 12;

  return (
    <div className="page-scroll" data-testid="cleanup-history-view">
      <div className="page-scroll-header history-header">
        <h1 style={{ margin: 0, fontSize: 20, fontWeight: 700 }}>清理记录</h1>
        <span style={{ flex: 1 }} />

        <div className="segmented-track" role="tablist" aria-label="时间范围">
          {TREND_RANGE_OPTIONS.map((opt) => (
            <button
              key={opt.id}
              type="button"
              className={`segmented-btn ${range === opt.id ? 'active' : ''}`}
              onClick={() => setRange(opt.id)}
              data-testid={`history-range-${opt.id}`}
            >
              {opt.label}
            </button>
          ))}
        </div>

        {!summary.isEmpty && (
          <div style={{ position: 'relative' }}>
            <button
              type="button"
              className="toolbar-btn icon-only"
              aria-label="清理记录选项"
              onClick={(e) => {
                e.stopPropagation();
                setMenuOpen((v) => !v);
              }}
              data-testid="history-options-btn"
            >
              <MoreHorizontal size={14} />
            </button>
            {menuOpen && (
              <div
                className="popover-menu"
                style={{ position: 'absolute', right: 0, top: 36, minWidth: 168 }}
                onClick={(e) => e.stopPropagation()}
              >
                <button
                  type="button"
                  className="popover-menu-item danger"
                  onClick={() => {
                    setMenuOpen(false);
                    setConfirmClearOpen(true);
                  }}
                  data-testid="history-clear-menu-btn"
                >
                  <Trash2 size={13} />
                  <span>清空清理记录…</span>
                </button>
              </div>
            )}
          </div>
        )}
      </div>

      <div className="history-content">
        <div className="glass-hero-card kpi-grid">
          <div className="kpi-cell">
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--text-secondary)' }}>
              <span className="tier-dot" style={{ background: RECOMMENDATION_COLORS.recommended }} />
              <span>累计已清理</span>
            </div>
            <div className="mono-num" style={{ fontSize: 24, fontWeight: 700 }} data-testid="history-kpi-total">
              {formatBytes(summary.totalFreedBytes)}
            </div>
            <div className="mono-num" style={{ fontSize: 11, color: 'var(--text-tertiary)' }}>
              {summary.totalRuns > 0 ? `共 ${summary.totalRuns} 次清理 · ${summary.totalTrashedItems} 项` : '暂无记录'}
            </div>
          </div>

          <div className="kpi-cell">
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--text-secondary)' }}>
              <span className="tier-dot" style={{ background: '#3db8fa' }} />
              <span>{range === 'allTime' ? '全部时间已清理' : `${rangeLabel}已清理`}</span>
            </div>
            <div className="mono-num" style={{ fontSize: 24, fontWeight: 700 }}>
              {formatBytes(summary.rangeFreedBytes)}
            </div>
            <div className="mono-num" style={{ fontSize: 11, color: 'var(--text-tertiary)' }}>
              {summary.rangeRuns > 0
                ? `周期内 ${summary.rangeRuns} 次清理 · ${summary.rangeTrashedItems} 项`
                : '此时间范围内暂无记录'}
            </div>
          </div>

          <div className="kpi-cell">
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--text-secondary)' }}>
              <span className="tier-dot" style={{ background: '#9980fa' }} />
              <span>单次清理最大值</span>
            </div>
            <div className="mono-num" style={{ fontSize: 24, fontWeight: 700 }}>
              {formatBytes(summary.largestSingleRunBytes)}
            </div>
            <div className="mono-num" style={{ fontSize: 11, color: 'var(--text-tertiary)' }}>
              {summary.totalRuns > 0
                ? `平均每次 ${formatBytes(summary.averagePerRunBytes)}`
                : '按单次清理统计'}
            </div>
          </div>
        </div>

        <div className="glass-card" style={{ padding: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12 }}>
            <strong style={{ fontSize: 14 }}>空间清理趋势</strong>
            {summary.usesWeeklyBuckets && (
              <span
                className="badge-pill"
                style={{ background: 'rgba(59, 130, 246, 0.14)', color: 'var(--accent-blue)' }}
                data-testid="weekly-bucket-badge"
              >
                按周汇总（跨度超过 180 天）
              </span>
            )}
            <span style={{ flex: 1 }} />
            <div className="segmented-track" role="tablist" aria-label="图表指标">
              <button
                type="button"
                className={`segmented-btn ${metricMode === 'cumulative' ? 'active' : ''}`}
                onClick={() => setMetricMode('cumulative')}
                data-testid="history-metric-cumulative"
              >
                累计
              </button>
              <button
                type="button"
                className={`segmented-btn ${metricMode === 'daily' ? 'active' : ''}`}
                onClick={() => setMetricMode('daily')}
                data-testid="history-metric-daily"
              >
                {summary.usesWeeklyBuckets ? '每周' : '单日'}
              </button>
            </div>
          </div>

          <div style={{ position: 'relative' }}>
            {summary.isEmpty ? (
              <div style={{ height: 190, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', color: 'var(--text-secondary)', gap: 4 }}>
                <strong>暂无清理记录</strong>
                <span style={{ fontSize: 12 }}>将条目移入{trash}后，这里会自动绘制累计与单日清理趋势。</span>
              </div>
            ) : (
              <>
                <svg
                  viewBox={`0 0 ${width} ${height}`}
                  style={{ width: '100%', height: 210, display: 'block' }}
                  onMouseMove={handleSvgMouseMove}
                  onMouseLeave={() => setHoveredIndex(null)}
                  data-testid="history-trend-chart"
                >
                  <defs>
                    <linearGradient id="historyAreaGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stopColor="#29d18a" stopOpacity="0.34" />
                      <stop offset="100%" stopColor="#29d18a" stopOpacity="0.02" />
                    </linearGradient>
                  </defs>

                  {[0, 0.5, 1].map((frac) => {
                    const y = padTop + plotH * (1 - frac);
                    return (
                      <g key={frac}>
                        <line
                          x1={padLeft}
                          y1={y}
                          x2={padLeft + plotW}
                          y2={y}
                          stroke="var(--divider)"
                          strokeDasharray={frac === 0 ? undefined : '3 3'}
                        />
                        <text
                          x={padLeft - 8}
                          y={y + 4}
                          textAnchor="end"
                          fill="var(--text-tertiary)"
                          fontSize="10.5"
                          className="mono-num"
                        >
                          {formatBytes(yMax * frac)}
                        </text>
                      </g>
                    );
                  })}

                  {metricMode === 'cumulative' ? (
                    <>
                      <path d={areaPath} fill="url(#historyAreaGrad)" />
                      <path d={linePath} fill="none" stroke="#29d18a" strokeWidth="2.4" strokeLinejoin="round" strokeLinecap="round" />
                    </>
                  ) : (
                    points.map((pt, idx) => {
                      const cx = xForIndex(idx);
                      const y = yForValue(pt.dailyFreedBytes);
                      const barH = Math.max(0, padTop + plotH - y);
                      const isHovered = hoveredIndex === idx;
                      return (
                        <rect
                          key={pt.key}
                          x={cx - barWidth / 2}
                          y={y}
                          width={barWidth}
                          height={barH}
                          rx={Math.min(4, barWidth / 2)}
                          fill={isHovered ? '#29d18a' : '#3db8fa'}
                          opacity={isHovered ? 1 : 0.82}
                        />
                      );
                    })
                  )}

                  {hoveredPoint && hoveredIndex !== null && (
                    <g>
                      <line
                        x1={xForIndex(hoveredIndex)}
                        y1={padTop}
                        x2={xForIndex(hoveredIndex)}
                        y2={padTop + plotH}
                        stroke="var(--text-tertiary)"
                        strokeDasharray="3 3"
                      />
                      <circle
                        cx={xForIndex(hoveredIndex)}
                        cy={yForValue(metricMode === 'cumulative' ? hoveredPoint.cumulativeFreedBytes : hoveredPoint.dailyFreedBytes)}
                        r="4.5"
                        fill="#29d18a"
                        stroke="var(--elevated-bg)"
                        strokeWidth="2"
                      />
                    </g>
                  )}

                  {tickIndices.map((idx) => (
                    <text
                      key={idx}
                      x={xForIndex(idx)}
                      y={height - 8}
                      textAnchor="middle"
                      fill="var(--text-tertiary)"
                      fontSize="10.5"
                      className="mono-num"
                    >
                      {formatShortMonthDay(points[idx].date)}
                    </text>
                  ))}
                </svg>

                {hoveredPoint && (
                  <div
                    className="glass-card"
                    style={{
                      position: 'absolute',
                      top: 8,
                      right: 12,
                      padding: '8px 12px',
                      background: 'var(--elevated-bg)',
                      fontSize: 11.5,
                      pointerEvents: 'none',
                    }}
                  >
                    <div style={{ fontWeight: 600, marginBottom: 2 }}>
                      {summary.usesWeeklyBuckets
                        ? `${formatFullDate(hoveredPoint.date)} ~ ${formatShortMonthDay(addLocalDays(hoveredPoint.date, 6))}`
                        : formatFullDate(hoveredPoint.date)}
                    </div>
                    <div className="mono-num">
                      {metricMode === 'cumulative'
                        ? `累计：${formatBytes(hoveredPoint.cumulativeFreedBytes)}`
                        : `${summary.usesWeeklyBuckets ? '本周' : '当日'}：${formatBytes(hoveredPoint.dailyFreedBytes)}`}
                    </div>
                    <div className="mono-num" style={{ color: 'var(--text-secondary)' }}>
                      {hoveredPoint.cleanupRuns} 次清理 · {hoveredPoint.trashedCount} 项
                    </div>
                  </div>
                )}
              </>
            )}
          </div>
        </div>

        {!summary.isEmpty && (
          <div className="history-bottom-grid">
            <div className="glass-card" style={{ padding: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 10 }}>
                <strong style={{ fontSize: 13.5 }}>客户端清理排行</strong>
                <span style={{ fontSize: 11, color: 'var(--text-tertiary)' }}>{rangeLabel}</span>
              </div>

              {summary.topClients.length === 0 ? (
                <div style={{ padding: 14, textAlign: 'center', color: 'var(--text-tertiary)', fontSize: 12 }}>
                  暂无客户端统计
                </div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }} data-testid="history-client-ranking">
                  {summary.topClients.slice(0, 8).map((client) => {
                    const tint = clientAccentById(client.clientId);
                    return (
                      <div key={client.clientId} style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                          <ClientLogo clientId={client.clientId} effectiveTheme={effectiveTheme} size={18} />
                          <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontWeight: 500 }}>
                            {client.clientName}
                          </span>
                          <span className="mono-num" style={{ fontWeight: 600, fontSize: 12 }}>
                            {formatBytes(client.totalFreedBytes)}
                          </span>
                          <span className="mono-num" style={{ fontSize: 11, color: 'var(--text-tertiary)', width: 32, textAlign: 'right' }}>
                            {Math.round(client.share * 100)}%
                          </span>
                        </div>
                        <div className="disk-bar-track" style={{ height: 4 }}>
                          <div
                            style={{
                              height: '100%',
                              width: `${Math.max(4, client.share * 100)}%`,
                              borderRadius: 999,
                              background: tint,
                            }}
                          />
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </div>

            <div className="glass-card" style={{ padding: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
                <strong style={{ fontSize: 13.5 }}>最近清理记录</strong>
                {pagedRecent.totalPages > 1 && (
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 11.5 }}>
                    <button
                      type="button"
                      className="row-action-btn"
                      disabled={pagedRecent.page <= 1}
                      onClick={() => setRecentPageNumber((p) => Math.max(1, p - 1))}
                      aria-label="上一页"
                    >
                      <ChevronLeft size={13} />
                    </button>
                    <span className="mono-num">
                      {pagedRecent.page} / {pagedRecent.totalPages}
                    </span>
                    <button
                      type="button"
                      className="row-action-btn"
                      disabled={pagedRecent.page >= pagedRecent.totalPages}
                      onClick={() => setRecentPageNumber((p) => Math.min(pagedRecent.totalPages, p + 1))}
                      aria-label="下一页"
                    >
                      <ChevronRight size={13} />
                    </button>
                  </div>
                )}
              </div>

              {pagedRecent.slice.length === 0 ? (
                <div style={{ padding: 16, textAlign: 'center', color: 'var(--text-tertiary)', fontSize: 12 }}>
                  所选时间范围内暂无清理记录
                </div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column' }} data-testid="history-recent-list">
                  {pagedRecent.slice.map((rec, idx) => (
                    <div
                      key={rec.id}
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        gap: 10,
                        padding: '10px 4px',
                        borderBottom: idx < pagedRecent.slice.length - 1 ? '1px solid var(--divider)' : 'none',
                      }}
                    >
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                          <span className="mono-num" style={{ fontWeight: 700, color: RECOMMENDATION_COLORS.recommended }}>
                            {formatBytes(rec.freedBytes)}
                          </span>
                          <span style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
                            {rec.trashedCount} 项
                          </span>
                          <span className="mono-num" style={{ fontSize: 11.5, color: 'var(--text-tertiary)' }}>
                            {formatDateTime(rec.timestamp)}
                          </span>
                        </div>
                        <div
                          style={{
                            fontSize: 11.5,
                            color: 'var(--text-secondary)',
                            overflow: 'hidden',
                            textOverflow: 'ellipsis',
                            whiteSpace: 'nowrap',
                            marginTop: 2,
                          }}
                        >
                          {rec.clientBreakdown.map((c) => c.clientName).join(' · ') || rec.sampleItemNames.join('、')}
                        </div>
                      </div>

                      <button
                        type="button"
                        className="row-action-btn"
                        title={`删除这条清理记录（保留${trash}文件）`}
                        aria-label="删除清理记录"
                        onClick={() => void onDeleteRecord(rec.id)}
                      >
                        <Trash2 size={13} />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        )}
      </div>

      {confirmClearOpen && (
        <div className="modal-backdrop" onClick={() => setConfirmClearOpen(false)}>
          <div className="modal-panel" style={{ maxWidth: 400 }} onClick={(e) => e.stopPropagation()}>
            <h3 style={{ margin: 0, fontSize: 16 }}>清空清理记录？</h3>
            <p style={{ margin: 0, color: 'var(--text-secondary)', fontSize: 13 }}>
              此操作会清空清理记录和排行，{trash}中的文件会保留。
            </p>
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
              <button type="button" className="btn-subtle-pill" onClick={() => setConfirmClearOpen(false)}>
                取消
              </button>
              <button
                type="button"
                className="btn-glow-danger"
                onClick={() => {
                  setConfirmClearOpen(false);
                  void onClearAll();
                }}
                data-testid="confirm-clear-history-btn"
              >
                清空清理记录
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
