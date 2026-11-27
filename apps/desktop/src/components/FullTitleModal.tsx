import { Copy, FolderOpen, X } from 'lucide-react';
import {
  categoryDisplayName,
  formatBytes,
  formatDateTime,
  recommendationDisplayName,
  revealActionTitle,
} from '../lib/format';
import type { CleanableItemDTO, PlatformKind } from '../rpc/types';

interface FullTitleModalProps {
  item: CleanableItemDTO;
  platform: PlatformKind;
  onClose: () => void;
  onCopyText: (text: string) => void;
  onReveal: (item: CleanableItemDTO) => void;
}

export function FullTitleModal({ item, platform, onClose, onCopyText, onReveal }: FullTitleModalProps) {
  const fullTitle = item.sessionTitle || item.preferredTitle;

  return (
    <div className="modal-backdrop" onClick={onClose} data-testid="full-title-modal">
      <div className="modal-panel" onClick={(e) => e.stopPropagation()}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
          <h3 style={{ margin: 0, fontSize: 16, fontWeight: 700 }}>条目完整标题与详情</h3>
          <button type="button" className="row-action-btn" onClick={onClose} aria-label="关闭">
            <X size={15} />
          </button>
        </div>

        <div
          className="glass-card"
          style={{
            padding: 14,
            userSelect: 'text',
            fontSize: 13.5,
            fontWeight: 600,
            lineHeight: 1.55,
            wordBreak: 'break-word',
          }}
          data-testid="full-title-content"
        >
          {fullTitle}
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'auto 1fr', gap: '8px 14px', fontSize: 12.5 }}>
          <span style={{ color: 'var(--text-secondary)' }}>所属客户端</span>
          <span>{item.clientName}</span>

          {item.sessionProjectName && (
            <>
              <span style={{ color: 'var(--text-secondary)' }}>所属项目</span>
              <span>{item.sessionProjectName}</span>
            </>
          )}

          <span style={{ color: 'var(--text-secondary)' }}>分类 / 建议</span>
          <span>
            {categoryDisplayName(item.category)} · {recommendationDisplayName(item.recommendation)}
          </span>

          <span style={{ color: 'var(--text-secondary)' }}>体积 / 修改时间</span>
          <span className="mono-num">
            {formatBytes(item.sizeBytes)} · {formatDateTime(item.modifiedAt)}
          </span>

          <span style={{ color: 'var(--text-secondary)' }}>安全说明</span>
          <span style={{ userSelect: 'text' }}>{item.hardProtectionReason || item.safetyNote}</span>

          <span style={{ color: 'var(--text-secondary)' }}>完整路径</span>
          <span className="mono-path" style={{ fontSize: 11.5, wordBreak: 'break-all', userSelect: 'text' }}>
            {item.path}
          </span>
        </div>

        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, paddingTop: 4 }}>
          <button type="button" className="btn-subtle-pill" onClick={() => onCopyText(fullTitle)}>
            <Copy size={13} />
            <span>复制标题</span>
          </button>
          <button type="button" className="btn-subtle-pill" onClick={() => onCopyText(item.path)}>
            <Copy size={13} />
            <span>复制路径</span>
          </button>
          <button type="button" className="btn-subtle-pill" onClick={() => onReveal(item)}>
            <FolderOpen size={13} />
            <span>{revealActionTitle(platform)}</span>
          </button>
          <button type="button" className="btn-glow-primary" onClick={onClose}>
            完成
          </button>
        </div>
      </div>
    </div>
  );
}
