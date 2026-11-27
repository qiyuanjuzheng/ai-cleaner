import { ShieldAlert } from 'lucide-react';
import { formatBytes, trashName } from '../lib/format';
import { RECOMMENDATION_COLORS } from '../lib/theme';
import type { CleanableItemDTO, PlatformKind } from '../rpc/types';

interface RiskConfirmDialogProps {
  item: CleanableItemDTO;
  platform: PlatformKind;
  onCancel: () => void;
  onConfirm: () => void;
}

export function RiskConfirmDialog({ item, platform, onCancel, onConfirm }: RiskConfirmDialogProps) {
  return (
    <div className="modal-backdrop" onClick={onCancel} data-testid="risk-confirm-dialog">
      <div className="modal-panel" style={{ maxWidth: 440 }} onClick={(e) => e.stopPropagation()}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <ShieldAlert size={22} style={{ color: RECOMMENDATION_COLORS.notRecommended }} />
          <h3 style={{ margin: 0, fontSize: 16, fontWeight: 700 }}>这项不建议清理，仍要勾选吗？</h3>
        </div>

        <div style={{ fontSize: 13, lineHeight: 1.55, color: 'var(--text-secondary)' }}>
          <div style={{ fontWeight: 600, color: 'var(--text-primary)', marginBottom: 6 }}>
            {item.clientName} · {item.preferredTitle}（{formatBytes(item.sizeBytes)}）
          </div>
          <p style={{ margin: '0 0 8px' }}>{item.safetyNote}</p>
          <p style={{ margin: 0, fontSize: 12 }}>移入{trashName(platform)}前还需再次确认。</p>
        </div>

        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
          <button type="button" className="btn-subtle-pill" onClick={onCancel}>
            取消
          </button>
          <button
            type="button"
            className="btn-glow-danger"
            onClick={onConfirm}
            data-testid="confirm-risk-select-btn"
          >
            仍要勾选
          </button>
        </div>
      </div>
    </div>
  );
}
