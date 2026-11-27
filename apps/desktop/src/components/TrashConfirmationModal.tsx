import { AlertTriangle, Check, FileText, Folder, Loader2, ShieldAlert, ShieldCheck, Trash2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import { abbreviatePath, formatBytes, trashName, trashRestoreHint } from '../lib/format';
import { RECOMMENDATION_COLORS } from '../lib/theme';
import type { CleanableItemDTO, PlatformKind, TrashPreviewResponse } from '../rpc/types';

interface TrashConfirmationModalProps {
  preview: TrashPreviewResponse;
  platform: PlatformKind;
  isExecuting: boolean;
  staleError: string | null;
  onCancel: () => void;
  onConfirm: (acknowledgedRisk: boolean) => void;
  onRefreshPreview: () => void;
}

export function TrashConfirmationModal({
  preview,
  platform,
  isExecuting,
  staleError,
  onCancel,
  onConfirm,
  onRefreshPreview,
}: TrashConfirmationModalProps) {
  const [acknowledgedRisk, setAcknowledgedRisk] = useState(false);

  const trash = trashName(platform);
  const riskItems = useMemo(
    () => preview.items.filter((item) => item.recommendation === 'notRecommended'),
    [preview.items]
  );
  const riskTotalBytes = useMemo(
    () => riskItems.reduce((sum, item) => sum + item.sizeBytes, 0),
    [riskItems]
  );

  const groupedByClient = useMemo(() => {
    const map = new Map<string, { clientName: string; totalBytes: number; items: CleanableItemDTO[] }>();
    for (const item of preview.items) {
      const existing = map.get(item.clientId) ?? {
        clientName: item.clientName,
        totalBytes: 0,
        items: [],
      };
      existing.totalBytes += item.sizeBytes;
      existing.items.push(item);
      map.set(item.clientId, existing);
    }
    return Array.from(map.entries()).map(([clientId, value]) => ({ clientId, ...value }));
  }, [preview.items]);

  const canConfirm = !isExecuting && preview.items.length > 0 && (!preview.hasNotRecommended || acknowledgedRisk);

  return (
    <div className="modal-backdrop" onClick={() => !isExecuting && onCancel()} data-testid="trash-confirm-modal">
      <div className="modal-panel" onClick={(e) => e.stopPropagation()}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <div
            style={{
              width: 46,
              height: 46,
              borderRadius: '50%',
              background: 'rgba(245, 87, 102, 0.16)',
              border: '1px solid rgba(245, 87, 102, 0.38)',
              color: '#f55766',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              flexShrink: 0,
            }}
          >
            {preview.hasNotRecommended ? <AlertTriangle size={20} /> : <Trash2 size={20} />}
          </div>

          <div>
            <h3 style={{ margin: '0 0 3px', fontSize: 17, fontWeight: 700 }}>
              {preview.hasNotRecommended ? `确认移入${trash}（含高风险项）` : `确认移入${trash}`}
            </h3>
            <div style={{ fontSize: 13, color: 'var(--text-secondary)' }}>
              拟移入 <strong className="mono-num">{preview.items.length}</strong> 项，共{' '}
              <strong className="mono-num" style={{ color: RECOMMENDATION_COLORS.recommended }}>
                {formatBytes(preview.totalBytes)}
              </strong>
            </div>
          </div>
        </div>

        {staleError && (
          <div
            style={{
              padding: '10px 12px',
              borderRadius: 10,
              background: 'rgba(250, 168, 56, 0.14)',
              border: '1px solid rgba(250, 168, 56, 0.4)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: 10,
              fontSize: 12,
            }}
          >
            <span>{staleError}</span>
            <button type="button" className="btn-subtle-pill" onClick={onRefreshPreview}>
              刷新清单
            </button>
          </div>
        )}

        {preview.hasNotRecommended ? (
          <div
            style={{
              padding: 12,
              borderRadius: 11,
              background: 'rgba(224, 107, 122, 0.13)',
              border: '1px solid rgba(224, 107, 122, 0.42)',
              display: 'flex',
              gap: 9,
              alignItems: 'flex-start',
            }}
          >
            <ShieldAlert size={16} style={{ color: RECOMMENDATION_COLORS.notRecommended, flexShrink: 0, marginTop: 1 }} />
            <div style={{ fontSize: 12 }}>
              <div style={{ fontWeight: 700, color: RECOMMENDATION_COLORS.notRecommended, marginBottom: 3 }}>
                包含 {riskItems.length} 项「不建议清理」条目（{formatBytes(riskTotalBytes)}）
              </div>
              <div style={{ color: 'var(--text-secondary)' }}>
                移入这些条目可能导致配置、登录或历史状态丢失，也可能需要重新下载插件或模型。{trashRestoreHint(platform)}
              </div>
            </div>
          </div>
        ) : (
          <div
            style={{
              padding: 10,
              borderRadius: 10,
              background: 'rgba(41, 209, 138, 0.11)',
              border: '1px solid rgba(41, 209, 138, 0.28)',
              display: 'flex',
              gap: 8,
              alignItems: 'center',
              fontSize: 12,
              color: 'var(--text-secondary)',
            }}
          >
            <ShieldCheck size={15} style={{ color: RECOMMENDATION_COLORS.recommended, flexShrink: 0 }} />
            <span>{trashRestoreHint(platform)}</span>
          </div>
        )}

        <div style={{ maxHeight: 280, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 12 }}>
          {groupedByClient.map((group) => (
            <div key={group.clientId} style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12.5 }}>
                <strong>{group.clientName}</strong>
                <span className="mono-num" style={{ color: 'var(--text-secondary)' }}>
                  {group.items.length} 项 · {formatBytes(group.totalBytes)}
                </span>
              </div>

              <div className="glass-card" style={{ borderRadius: 10, overflow: 'hidden' }}>
                {group.items.map((item, idx) => {
                  const isRisk = item.recommendation === 'notRecommended';
                  return (
                    <div
                      key={item.id}
                      style={{
                        display: 'flex',
                        alignItems: 'flex-start',
                        gap: 8,
                        padding: '8px 10px',
                        borderBottom: idx < group.items.length - 1 ? '1px solid var(--divider)' : 'none',
                        background: isRisk ? 'rgba(224, 107, 122, 0.08)' : 'transparent',
                      }}
                    >
                      <span
                        style={{
                          color: isRisk ? RECOMMENDATION_COLORS.notRecommended : 'var(--text-secondary)',
                          marginTop: 2,
                          flexShrink: 0,
                        }}
                      >
                        {isRisk ? <ShieldAlert size={13} /> : item.isDirectory ? <Folder size={13} /> : <FileText size={13} />}
                      </span>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                          <span
                            style={{
                              fontWeight: isRisk ? 600 : 500,
                              color: isRisk ? RECOMMENDATION_COLORS.notRecommended : 'var(--text-primary)',
                              overflow: 'hidden',
                              textOverflow: 'ellipsis',
                              whiteSpace: 'nowrap',
                            }}
                          >
                            {item.preferredTitle}
                          </span>
                          {isRisk && (
                            <span
                              className="badge-pill"
                              style={{
                                background: 'rgba(224, 107, 122, 0.18)',
                                color: RECOMMENDATION_COLORS.notRecommended,
                              }}
                            >
                              不建议清理
                            </span>
                          )}
                        </div>
                        {isRisk && (
                          <div style={{ fontSize: 11, color: RECOMMENDATION_COLORS.notRecommended, marginTop: 2 }}>
                            {item.safetyNote}
                          </div>
                        )}
                        <div
                          className="mono-path"
                          style={{
                            fontSize: 11,
                            color: 'var(--text-secondary)',
                            overflow: 'hidden',
                            textOverflow: 'ellipsis',
                            whiteSpace: 'nowrap',
                          }}
                        >
                          {abbreviatePath(item.path, platform)}
                        </div>
                      </div>
                      <span className="mono-num" style={{ fontSize: 12, color: 'var(--text-secondary)', flexShrink: 0 }}>
                        {formatBytes(item.sizeBytes)}
                      </span>
                    </div>
                  );
                })}
              </div>
            </div>
          ))}
        </div>

        {preview.hasNotRecommended && (
          <button
            type="button"
            onClick={() => setAcknowledgedRisk((v) => !v)}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 9,
              padding: '10px 12px',
              borderRadius: 10,
              border: `1px solid ${acknowledgedRisk ? 'rgba(224, 107, 122, 0.55)' : 'var(--border-rim)'}`,
              background: acknowledgedRisk ? 'rgba(224, 107, 122, 0.12)' : 'var(--surface-muted)',
              textAlign: 'left',
            }}
            data-testid="risk-ack-checkbox"
          >
            <span
              className={`check-btn ${acknowledgedRisk ? 'checked' : ''}`}
              style={{ '--check-color': RECOMMENDATION_COLORS.notRecommended } as React.CSSProperties}
            >
              {acknowledgedRisk && <Check size={12} strokeWidth={3} />}
            </span>
            <span style={{ fontSize: 12.5, fontWeight: 500 }}>
              我已知晓上述高风险项的影响，确认移入系统{trash}
            </span>
          </button>
        )}

        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10, paddingTop: 4 }}>
          <button type="button" className="btn-subtle-pill" disabled={isExecuting} onClick={onCancel}>
            取消
          </button>
          <button
            type="button"
            className="btn-glow-danger"
            disabled={!canConfirm}
            onClick={() => onConfirm(acknowledgedRisk)}
            data-testid="confirm-trash-execute-btn"
          >
            {isExecuting ? <Loader2 size={14} className="spin-icon" /> : <Trash2 size={14} />}
            <span>{isExecuting ? `正在移入${trash}…` : `移入${trash}`}</span>
          </button>
        </div>
      </div>
    </div>
  );
}
