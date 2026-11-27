import { AlertTriangle, CheckCircle2, Loader2, Trash2, X } from 'lucide-react';
import { useState } from 'react';
import type { CSSProperties } from 'react';
import { formatBytes, trashName } from '../lib/format';
import { RECOMMENDATION_COLORS } from '../lib/theme';
import type { CleanupResultDTO, PlatformKind, SelectionSummaryDTO } from '../rpc/types';

interface BottomActionBarProps {
  visible: boolean;
  selection: SelectionSummaryDTO;
  isScanning: boolean;
  isCleaning: boolean;
  lastCleanupResult: CleanupResultDTO | null;
  celebrationKey: number;
  platform: PlatformKind;
  onClearSelection: () => void;
  onRequestTrash: () => void;
  onDismissResult: () => void;
  onOpenHistory: () => void;
}

const SPARKLE_VECTORS = [
  { dx: '-46px', dy: '-26px', left: '16%', top: '45%', delay: '0ms' },
  { dx: '-24px', dy: '-38px', left: '32%', top: '30%', delay: '40ms' },
  { dx: '8px', dy: '-42px', left: '50%', top: '24%', delay: '80ms' },
  { dx: '30px', dy: '-34px', left: '68%', top: '32%', delay: '30ms' },
  { dx: '48px', dy: '-20px', left: '84%', top: '48%', delay: '70ms' },
  { dx: '-34px', dy: '26px', left: '24%', top: '65%', delay: '50ms' },
  { dx: '36px', dy: '24px', left: '76%', top: '65%', delay: '60ms' },
];

export function BottomActionBar({
  visible,
  selection,
  isScanning,
  isCleaning,
  lastCleanupResult,
  celebrationKey,
  platform,
  onClearSelection,
  onRequestTrash,
  onDismissResult,
  onOpenHistory,
}: BottomActionBarProps) {
  const [showFailureDetails, setShowFailureDetails] = useState(false);

  if (!visible) return null;

  const trash = trashName(platform);
  const hasFailures = Boolean(
    lastCleanupResult &&
      (lastCleanupResult.skippedProtectedItems.length > 0 || lastCleanupResult.failedItems.length > 0)
  );
  const isPureSuccess = Boolean(lastCleanupResult && !hasFailures && lastCleanupResult.trashedCount > 0);
  const hasSelection = selection.selectedCount > 0;

  if (!hasSelection && !lastCleanupResult) {
    return null;
  }

  return (
    <div className="bottom-dock-layer">
      {lastCleanupResult && (
        <div
          className="floating-pill"
          style={{
            paddingRight: 12,
            borderColor: isPureSuccess
              ? 'rgba(41, 209, 138, 0.42)'
              : 'rgba(250, 168, 56, 0.45)',
          }}
          data-testid="cleanup-result-pill"
        >
          {isPureSuccess && celebrationKey > 0 && (
            <div key={celebrationKey} className="sparkle-burst" aria-hidden="true">
              {SPARKLE_VECTORS.map((dot, idx) => (
                <span
                  key={idx}
                  className="sparkle-dot"
                  style={
                    {
                      left: dot.left,
                      top: dot.top,
                      animationDelay: dot.delay,
                      '--dx': dot.dx,
                      '--dy': dot.dy,
                    } as CSSProperties
                  }
                />
              ))}
            </div>
          )}

          {isPureSuccess ? (
            <CheckCircle2 size={17} style={{ color: RECOMMENDATION_COLORS.recommended, flexShrink: 0 }} />
          ) : (
            <AlertTriangle size={17} style={{ color: RECOMMENDATION_COLORS.reviewSuggested, flexShrink: 0 }} />
          )}

          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            {lastCleanupResult.trashedCount > 0 ? (
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12.5 }}>
                <span style={{ fontWeight: 600 }}>已移入{trash}</span>
                <span
                  className="mono-num"
                  style={{
                    fontWeight: 700,
                    color: isPureSuccess
                      ? RECOMMENDATION_COLORS.recommended
                      : RECOMMENDATION_COLORS.reviewSuggested,
                  }}
                >
                  {formatBytes(lastCleanupResult.freedBytes)}
                </span>
                <span style={{ color: 'var(--text-secondary)', fontSize: 12 }}>
                  （{lastCleanupResult.trashedCount} 项）
                </span>
                <button
                  type="button"
                  style={{
                    border: 'none',
                    background: 'transparent',
                    color: 'var(--accent-blue)',
                    fontWeight: 600,
                    fontSize: 12,
                    padding: 0,
                  }}
                  onClick={() => {
                    onDismissResult();
                    onOpenHistory();
                  }}
                >
                  查看清理记录
                </button>
              </div>
            ) : (
              <span style={{ fontWeight: 600, fontSize: 12.5 }}>未移入{trash}</span>
            )}

            {lastCleanupResult.skippedProtectedItems.length > 0 && (
              <span style={{ fontSize: 11, color: 'var(--text-secondary)' }}>
                已跳过 {lastCleanupResult.skippedProtectedItems.length} 项受保护条目
              </span>
            )}
            {lastCleanupResult.failedItems.length > 0 && (
              <span style={{ fontSize: 11, color: 'var(--text-secondary)' }}>
                移入失败 {lastCleanupResult.failedItems.length} 项 · {lastCleanupResult.failedItems[0].reason}
              </span>
            )}
          </div>

          {hasFailures && (
            <button
              type="button"
              className="btn-subtle-pill"
              style={{ height: 24, fontSize: 11 }}
              onClick={() => setShowFailureDetails((v) => !v)}
            >
              查看详情
            </button>
          )}

          <button
            type="button"
            className="row-action-btn"
            onClick={() => {
              setShowFailureDetails(false);
              onDismissResult();
            }}
            aria-label="关闭提示"
          >
            <X size={13} />
          </button>

          {showFailureDetails && hasFailures && (
            <div
              className="glass-card"
              style={{
                position: 'absolute',
                bottom: 'calc(100% + 10px)',
                right: 0,
                width: 360,
                maxHeight: 240,
                overflowY: 'auto',
                padding: 14,
                background: 'var(--elevated-bg)',
                boxShadow: 'var(--shadow-elevated)',
              }}
            >
              <div style={{ fontWeight: 700, marginBottom: 8 }}>未移入{trash}的条目</div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                {[...lastCleanupResult.skippedProtectedItems, ...lastCleanupResult.failedItems].map((f, idx) => (
                  <div key={`${f.item.id}-${idx}`} style={{ fontSize: 12 }}>
                    <div style={{ fontWeight: 600 }}>{f.item.preferredTitle}</div>
                    <div style={{ color: 'var(--text-secondary)', fontSize: 11 }}>{f.reason}</div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {hasSelection && (
        <div className="floating-pill" data-testid="selection-dock">
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span
              style={{
                width: 8,
                height: 8,
                borderRadius: '50%',
                background: selection.hasNotRecommended
                  ? RECOMMENDATION_COLORS.notRecommended
                  : RECOMMENDATION_COLORS.recommended,
                boxShadow: `0 0 8px ${
                  selection.hasNotRecommended
                    ? RECOMMENDATION_COLORS.notRecommended
                    : RECOMMENDATION_COLORS.recommended
                }`,
              }}
            />
            <span className="mono-num" style={{ fontWeight: 600 }}>
              已选 {selection.selectedCount} 项
            </span>

            {selection.hasNotRecommended && (
              <span
                className="badge-pill"
                style={{
                  background: 'rgba(224, 107, 122, 0.18)',
                  color: RECOMMENDATION_COLORS.notRecommended,
                }}
              >
                含高风险项
              </span>
            )}

            <span style={{ color: 'var(--text-tertiary)' }}>·</span>

            <span
              className="mono-num"
              style={{
                fontWeight: 700,
                color: selection.hasNotRecommended
                  ? RECOMMENDATION_COLORS.reviewSuggested
                  : RECOMMENDATION_COLORS.recommended,
              }}
            >
              拟移入{trash} {formatBytes(selection.selectedBytes)}
            </span>
          </div>

          <span style={{ width: 1, height: 16, background: 'var(--divider)' }} />

          <button
            type="button"
            style={{
              border: 'none',
              background: 'transparent',
              color: 'var(--text-secondary)',
              fontSize: 12.5,
              padding: '4px 6px',
            }}
            disabled={isCleaning}
            onClick={onClearSelection}
            data-testid="clear-selection-btn"
          >
            清空选择
          </button>

          <button
            type="button"
            className="btn-glow-danger"
            disabled={isCleaning || isScanning}
            onClick={onRequestTrash}
            data-testid="open-trash-confirm-btn"
          >
            {isCleaning ? <Loader2 size={14} className="spin-icon" /> : <Trash2 size={14} />}
            <span>{isCleaning ? '正在移入…' : `移入${trash}…`}</span>
          </button>
        </div>
      )}
    </div>
  );
}
