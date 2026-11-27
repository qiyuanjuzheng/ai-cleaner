import { useVirtualizer } from '@tanstack/react-virtual';
import {
  Check,
  Copy,
  EyeOff,
  FileText,
  Folder,
  FolderOpen,
  Lock,
  MessageSquareText,
  MoreHorizontal,
  ShieldAlert,
} from 'lucide-react';
import { useEffect, useMemo, useRef, useState } from 'react';
import {
  abbreviatePath,
  categoryDisplayName,
  formatBytes,
  formatDateTime,
  recommendationDisplayName,
  revealActionTitle,
} from '../lib/format';
import { CATEGORY_COLORS, RECOMMENDATION_COLORS } from '../lib/theme';
import { buildVirtualRows, computeNeededPages, ITEMS_PAGE_SIZE } from '../lib/virtualRows';
import type {
  CleanableItemDTO,
  CleanupRecommendation,
  ItemGroupDTO,
  PlatformKind,
} from '../rpc/types';

interface VirtualizedItemListProps {
  groups: ItemGroupDTO[];
  total: number;
  pageItems: Map<number, CleanableItemDTO[]>;
  inFlightPages: ReadonlySet<number>;
  onRequestPage: (pageIndex: number) => void;
  onToggleItem: (item: CleanableItemDTO) => void;
  onToggleSection: (recommendation: 'recommended' | 'reviewSuggested') => void;
  onExcludeItem: (item: CleanableItemDTO) => void;
  onRevealItem: (item: CleanableItemDTO) => void;
  onCopyPath: (path: string) => void;
  onInspectFullTitle: (item: CleanableItemDTO) => void;
  isBusy: boolean;
  platform: PlatformKind;
  hasActiveFilters: boolean;
  excludedCount: number;
  onResetFilters: () => void;
  onRescan: () => void;
  onOpenExcluded: () => void;
  viewportKey: string;
}

interface ContextMenuState {
  item: CleanableItemDTO;
  x: number;
  y: number;
}

export function VirtualizedItemList({
  groups,
  total,
  pageItems,
  inFlightPages,
  onRequestPage,
  onToggleItem,
  onToggleSection,
  onExcludeItem,
  onRevealItem,
  onCopyPath,
  onInspectFullTitle,
  isBusy,
  platform,
  hasActiveFilters,
  excludedCount,
  onResetFilters,
  onRescan,
  onOpenExcluded,
  viewportKey,
}: VirtualizedItemListProps) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);

  const rows = useMemo(() => buildVirtualRows(groups), [groups]);

  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: (index) => (rows[index]?.kind === 'sectionHeader' ? 40 : 62),
    overscan: 12,
  });

  // Scroll back to top when viewport scope/filter changes
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = 0;
    }
  }, [viewportKey]);

  const virtualItems = virtualizer.getVirtualItems();

  // Trigger lazy 200-item page loads for visible range + lookahead
  useEffect(() => {
    if (rows.length === 0) return;
    const loadedPages = new Set(pageItems.keys());
    const startIdx = virtualItems.length > 0 ? virtualItems[0].index : 0;
    const endIdx = virtualItems.length > 0 ? virtualItems[virtualItems.length - 1].index : Math.min(rows.length - 1, 30);
    const needed = computeNeededPages(rows, startIdx, endIdx, loadedPages, inFlightPages, ITEMS_PAGE_SIZE);
    for (const page of needed) {
      onRequestPage(page);
    }
  }, [rows, virtualItems, pageItems, inFlightPages, onRequestPage]);

  // Close context menu on outside click / Escape
  useEffect(() => {
    if (!contextMenu) return;
    const close = () => setContextMenu(null);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setContextMenu(null);
    };
    window.addEventListener('click', close);
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('click', close);
      window.removeEventListener('keydown', onKey);
    };
  }, [contextMenu]);

  const lookupItem = (globalIndex: number): CleanableItemDTO | undefined => {
    const page = Math.floor(globalIndex / ITEMS_PAGE_SIZE);
    const offsetInPage = globalIndex % ITEMS_PAGE_SIZE;
    return pageItems.get(page)?.[offsetInPage];
  };

  if (total === 0 || rows.length === 0) {
    return (
      <div className="hero-center-stage" data-testid="empty-items-state">
        {hasActiveFilters ? (
          <>
            <h3 style={{ margin: 0, fontSize: 16 }}>没有匹配的条目</h3>
            <p style={{ margin: 0, color: 'var(--text-secondary)' }}>调整搜索词或筛选条件后重试。</p>
            <button type="button" className="btn-glow-primary" onClick={onResetFilters}>
              重置筛选
            </button>
          </>
        ) : (
          <>
            <h3 style={{ margin: 0, fontSize: 16 }}>未找到可清理条目</h3>
            {excludedCount > 0 && (
              <p style={{ margin: 0, color: 'var(--text-secondary)' }}>
                当前有 {excludedCount} 项在已排除列表中被自动跳过。
              </p>
            )}
            <div style={{ display: 'flex', gap: 10 }}>
              <button type="button" className="btn-subtle-pill" onClick={onRescan}>
                重新扫描
              </button>
              {excludedCount > 0 && (
                <button type="button" className="btn-subtle-pill" onClick={onOpenExcluded}>
                  查看已排除（{excludedCount}）
                </button>
              )}
            </div>
          </>
        )}
      </div>
    );
  }

  const openContextMenu = (item: CleanableItemDTO, x: number, y: number) => {
    const menuWidth = 220;
    const menuHeight = 200;
    const safeX = Math.min(x, Math.max(12, window.innerWidth - menuWidth - 12));
    const safeY = Math.min(y, Math.max(12, window.innerHeight - menuHeight - 12));
    setContextMenu({ item, x: safeX, y: safeY });
  };

  return (
    <div ref={scrollRef} className="virtual-list-viewport" data-testid="virtual-item-list">
      <div
        style={{
          height: `${virtualizer.getTotalSize()}px`,
          width: '100%',
          position: 'relative',
        }}
      >
        {virtualItems.map((vRow) => {
          const desc = rows[vRow.index];
          if (!desc) return null;

          if (desc.kind === 'sectionHeader') {
            const rec: CleanupRecommendation = desc.recommendation;
            const tint = RECOMMENDATION_COLORS[rec];
            const canBulk = rec === 'recommended' || rec === 'reviewSuggested';

            return (
              <div
                key={desc.key}
                style={{
                  position: 'absolute',
                  top: 0,
                  left: 0,
                  width: '100%',
                  transform: `translateY(${vRow.start}px)`,
                }}
              >
                <div className="section-header-row" data-testid={`section-header-${rec}`}>
                  <div className="section-header-left">
                    {canBulk ? (
                      <button
                        type="button"
                        className={`check-btn ${desc.allBulkSelected ? 'checked' : ''}`}
                        style={{ '--check-color': tint } as React.CSSProperties}
                        disabled={isBusy}
                        aria-label={`${desc.allBulkSelected ? '取消全选' : '全选'}${recommendationDisplayName(rec)}`}
                        onClick={() => onToggleSection(rec)}
                        data-testid={`section-toggle-${rec}`}
                      >
                        {desc.allBulkSelected && <Check size={12} strokeWidth={3} />}
                      </button>
                    ) : (
                      <ShieldAlert size={15} style={{ color: tint }} />
                    )}
                    <span style={{ fontWeight: 700, fontSize: 12.5, color: tint }}>
                      {recommendationDisplayName(rec)}
                    </span>
                    <span className="mono-num" style={{ fontSize: 11.5, color: 'var(--text-tertiary)' }}>
                      {desc.itemCount} 项
                    </span>
                  </div>
                  <span className="mono-num" style={{ fontSize: 12, fontWeight: 600, color: 'var(--text-secondary)' }}>
                    {formatBytes(desc.totalBytes)}
                  </span>
                </div>
              </div>
            );
          }

          const item = lookupItem(desc.globalItemIndex);
          const cornerClasses = `${desc.isFirstInSection ? 'first' : ''} ${desc.isLastInSection ? 'last' : ''}`;

          if (!item) {
            return (
              <div
                key={desc.key}
                style={{
                  position: 'absolute',
                  top: 0,
                  left: 0,
                  width: '100%',
                  transform: `translateY(${vRow.start}px)`,
                }}
              >
                <div className={`item-row-card ${cornerClasses}`}>
                  <div style={{ width: 19, height: 19, borderRadius: 6, background: 'var(--surface-muted)' }} />
                  <div className="item-row-main">
                    <div style={{ width: '40%', height: 12, borderRadius: 4, background: 'var(--surface-muted)' }} />
                    <div style={{ width: '68%', height: 10, borderRadius: 4, background: 'var(--surface-muted)' }} />
                  </div>
                </div>
              </div>
            );
          }

          const isLocked = Boolean(item.hardProtectionReason);
          const recColor = RECOMMENDATION_COLORS[item.recommendation];
          const catColor = CATEGORY_COLORS[item.category];
          const abbrPath = abbreviatePath(item.path, platform);
          const subtitle = item.hardProtectionReason
            ? `${abbrPath} · ${item.hardProtectionReason}`
            : `${abbrPath} · ${item.safetyNote}`;
          const hasLongOrSessionTitle = Boolean(item.sessionTitle) || item.preferredTitle.length > 42;

          return (
            <div
              key={desc.key}
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                width: '100%',
                transform: `translateY(${vRow.start}px)`,
              }}
            >
              <div
                className={`item-row-card ${cornerClasses} ${item.selected ? `selected-${item.recommendation}` : ''}`}
                data-testid="scan-item-row"
                data-item-id={item.id}
                data-row-index={desc.globalItemIndex}
                onContextMenu={(e) => {
                  e.preventDefault();
                  openContextMenu(item, e.clientX, e.clientY);
                }}
              >
                {isLocked ? (
                  <span
                    className="check-btn locked"
                    title={item.hardProtectionReason}
                    aria-label="已锁定，不可清理"
                    data-testid="item-locked-badge"
                  >
                    <Lock size={11} />
                  </span>
                ) : (
                  <button
                    type="button"
                    className={`check-btn ${item.selected ? 'checked' : ''}`}
                    style={{ '--check-color': recColor } as React.CSSProperties}
                    disabled={isBusy}
                    aria-label={`${item.selected ? '取消勾选' : '勾选'} ${item.preferredTitle}`}
                    aria-checked={item.selected}
                    role="checkbox"
                    onClick={() => onToggleItem(item)}
                    data-testid="item-checkbox"
                  >
                    {item.selected && <Check size={12} strokeWidth={3} />}
                  </button>
                )}

                <span style={{ color: 'var(--text-tertiary)', display: 'inline-flex', flexShrink: 0 }}>
                  {item.isDirectory ? <Folder size={15} /> : <FileText size={15} />}
                </span>

                <div className="item-row-main">
                  <div className="item-row-top">
                    <span className="item-row-title" title={item.preferredTitle}>
                      {item.preferredTitle}
                    </span>

                    <span
                      className="badge-pill"
                      style={{
                        background: `color-mix(in srgb, ${catColor} 14%, transparent)`,
                        color: catColor,
                      }}
                    >
                      {categoryDisplayName(item.category)}
                    </span>

                    {item.sessionProjectName && (
                      <span
                        className="badge-pill"
                        style={{ background: 'var(--surface-muted)', color: 'var(--text-secondary)' }}
                      >
                        {item.sessionProjectName}
                      </span>
                    )}

                    {item.sourceBadge && (
                      <span
                        className="badge-pill"
                        style={{ background: 'var(--surface-muted)', color: 'var(--text-secondary)' }}
                      >
                        {item.sourceBadge}
                      </span>
                    )}

                    {item.isRecentlyModified && (
                      <span
                        className="badge-pill"
                        style={{ background: 'rgba(250, 168, 56, 0.16)', color: 'var(--accent-review)' }}
                      >
                        近期活跃
                      </span>
                    )}

                    {isLocked && (
                      <span
                        className="badge-pill"
                        style={{ background: 'rgba(224, 107, 122, 0.16)', color: 'var(--accent-risk)' }}
                      >
                        已锁定
                      </span>
                    )}
                  </div>

                  <div className="item-row-detail" title={`${item.safetyNote}\n路径：${item.path}`}>
                    <span className="mono-path">{subtitle}</span>
                  </div>
                </div>

                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 4,
                    flexShrink: 0,
                  }}
                >
                  {hasLongOrSessionTitle && (
                    <button
                      type="button"
                      className="row-action-btn"
                      title="查看完整标题与详情"
                      aria-label="查看完整标题"
                      onClick={() => onInspectFullTitle(item)}
                      data-testid="item-full-title-btn"
                    >
                      <MessageSquareText size={14} />
                    </button>
                  )}

                  <button
                    type="button"
                    className="row-action-btn"
                    title={`${revealActionTitle(platform)}：${abbrPath}`}
                    aria-label={revealActionTitle(platform)}
                    onClick={() => onRevealItem(item)}
                    data-testid="item-reveal-btn"
                  >
                    <FolderOpen size={14} />
                  </button>

                  <button
                    type="button"
                    className="row-action-btn"
                    title="更多操作"
                    aria-label="更多操作"
                    onClick={(e) => {
                      e.stopPropagation();
                      const rect = e.currentTarget.getBoundingClientRect();
                      openContextMenu(item, rect.left - 180, rect.bottom + 4);
                    }}
                    data-testid="item-more-btn"
                  >
                    <MoreHorizontal size={14} />
                  </button>

                  <div style={{ textAlign: 'right', minWidth: 74, marginLeft: 4 }}>
                    <div className="mono-num" style={{ fontWeight: 700, fontSize: 12.5 }}>
                      {formatBytes(item.sizeBytes)}
                    </div>
                    <div className="mono-num" style={{ fontSize: 10.5, color: 'var(--text-tertiary)' }}>
                      {formatDateTime(item.modifiedAt).slice(5, 16)}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          );
        })}
      </div>

      {contextMenu && (
        <div
          className="popover-menu"
          style={{ left: contextMenu.x, top: contextMenu.y }}
          onClick={(e) => e.stopPropagation()}
          data-testid="item-context-menu"
        >
          {!contextMenu.item.hardProtectionReason && (
            <>
              <button
                type="button"
                className="popover-menu-item"
                onClick={() => {
                  onToggleItem(contextMenu.item);
                  setContextMenu(null);
                }}
              >
                <Check size={13} />
                <span>{contextMenu.item.selected ? '取消勾选' : '勾选此条目'}</span>
              </button>
              <div className="popover-menu-sep" />
            </>
          )}

          <button
            type="button"
            className="popover-menu-item"
            onClick={() => {
              onInspectFullTitle(contextMenu.item);
              setContextMenu(null);
            }}
          >
            <MessageSquareText size={13} />
            <span>查看完整标题与详情</span>
          </button>

          <button
            type="button"
            className="popover-menu-item"
            onClick={() => {
              onExcludeItem(contextMenu.item);
              setContextMenu(null);
            }}
            data-testid="ctx-exclude-item"
          >
            <EyeOff size={13} />
            <span>排除此条目（不再显示）</span>
          </button>

          <div className="popover-menu-sep" />

          <button
            type="button"
            className="popover-menu-item"
            onClick={() => {
              onRevealItem(contextMenu.item);
              setContextMenu(null);
            }}
          >
            <FolderOpen size={13} />
            <span>{revealActionTitle(platform)}</span>
          </button>

          <button
            type="button"
            className="popover-menu-item"
            onClick={() => {
              onCopyPath(contextMenu.item.path);
              setContextMenu(null);
            }}
          >
            <Copy size={13} />
            <span>复制完整路径</span>
          </button>
        </div>
      )}
    </div>
  );
}
