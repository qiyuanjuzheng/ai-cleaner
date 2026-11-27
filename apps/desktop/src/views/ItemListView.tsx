import {
  ChevronLeft,
  FolderKanban,
  Search,
  ShieldCheck,
  SlidersHorizontal,
  Sparkles,
  X,
} from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import type { CSSProperties } from 'react';
import {
  ageFilterDisplayName,
  categoryShortTitle,
  formatBytes,
  recommendationDisplayName,
  sortOrderDisplayName,
} from '../lib/format';
import { RECOMMENDATION_COLORS } from '../lib/theme';
import type {
  CleanableItemDTO,
  CleanupRecommendation,
  ClientSummaryDTO,
  FilterDTO,
  ItemAgeFilter,
  ItemGroupDTO,
  ItemSortOrder,
  PlatformKind,
  ReportSummaryDTO,
  ScanCategory,
  ScanProgressNotification,
  SidebarSelection,
} from '../rpc/types';
import { OrbitalScannerHero } from '../components/OrbitalScannerHero';
import { ScanReadyHero } from '../components/ScanReadyHero';
import { HairlineStorageBar, StorageRingGauge } from '../components/StorageRingGauge';
import { VirtualizedItemList } from '../components/VirtualizedItemList';

interface ScopeStats {
  recommendedBytes: number;
  recommendedCount: number;
  reviewBytes: number;
  reviewCount: number;
  protectedBytes: number;
  protectedCount: number;
}

interface ItemListViewProps {
  visible: boolean;
  selection: SidebarSelection;
  reportSummary: ReportSummaryDTO | null;
  activeClient: ClientSummaryDTO | null;
  scopeStats: ScopeStats;
  isScanning: boolean;
  isCleaning: boolean;
  scanProgress: ScanProgressNotification | null;
  historicalFreedBytes: number;
  excludedCount: number;
  filter: FilterDTO;
  searchInput: string;
  sortOrder: ItemSortOrder;
  groups: ItemGroupDTO[];
  total: number;
  pageItems: Map<number, CleanableItemDTO[]>;
  inFlightPages: ReadonlySet<number>;
  platform: PlatformKind;
  effectiveTheme: 'light' | 'dark';
  viewportKey: string;
  onStartScan: () => void;
  onCancelScan: () => void;
  onReturnToIdle: () => void;
  onOpenHistory: () => void;
  onOpenExcluded: () => void;
  onOpenClientProjects: (clientId: string) => void;
  onSelectRecommendedInScope: () => void;
  onSelectAllVisible: () => void;
  onInvertVisible: () => void;
  onClearVisible: () => void;
  onClearAllSelection: () => void;
  onChangeFilter: (patch: Partial<FilterDTO>) => void;
  onChangeSearchInput: (value: string) => void;
  onChangeSortOrder: (sort: ItemSortOrder) => void;
  onResetFilters: () => void;
  onRequestPage: (pageIndex: number) => void;
  onToggleItem: (item: CleanableItemDTO) => void;
  onToggleSection: (recommendation: 'recommended' | 'reviewSuggested') => void;
  onExcludeItem: (item: CleanableItemDTO) => void;
  onRevealItem: (item: CleanableItemDTO) => void;
  onCopyPath: (path: string) => void;
  onInspectFullTitle: (item: CleanableItemDTO) => void;
}

const ALL_CATEGORIES: ScanCategory[] = ['sessions', 'cache', 'temporary', 'logs', 'custom', 'protectedData'];
const AGE_OPTIONS: ItemAgeFilter[] = ['all', 'olderThan7Days', 'olderThan30Days', 'olderThan90Days'];
const SORT_OPTIONS: ItemSortOrder[] = ['sizeDesc', 'sizeAsc', 'modifiedDesc', 'modifiedAsc', 'nameAsc'];

export function ItemListView({
  visible,
  selection,
  reportSummary,
  activeClient,
  scopeStats,
  isScanning,
  isCleaning,
  scanProgress,
  historicalFreedBytes,
  excludedCount,
  filter,
  searchInput,
  sortOrder,
  groups,
  total,
  pageItems,
  inFlightPages,
  platform,
  effectiveTheme,
  viewportKey,
  onStartScan,
  onCancelScan,
  onReturnToIdle,
  onOpenHistory,
  onOpenExcluded,
  onOpenClientProjects,
  onSelectRecommendedInScope,
  onSelectAllVisible,
  onInvertVisible,
  onClearVisible,
  onClearAllSelection,
  onChangeFilter,
  onChangeSearchInput,
  onChangeSortOrder,
  onResetFilters,
  onRequestPage,
  onToggleItem,
  onToggleSection,
  onExcludeItem,
  onRevealItem,
  onCopyPath,
  onInspectFullTitle,
}: ItemListViewProps) {
  const [hoveredTier, setHoveredTier] = useState<CleanupRecommendation | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuAnchorRef = useRef<HTMLButtonElement | null>(null);
  const [menuPos, setMenuPos] = useState<{ left: number; top: number }>({ left: 0, top: 0 });

  useEffect(() => {
    if (!menuOpen) return;
    const close = () => setMenuOpen(false);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setMenuOpen(false);
    };
    window.addEventListener('click', close);
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('click', close);
      window.removeEventListener('keydown', onKey);
    };
  }, [menuOpen]);

  if (!visible) return null;

  if (!reportSummary) {
    return isScanning ? (
      <OrbitalScannerHero progress={scanProgress} effectiveTheme={effectiveTheme} onCancel={onCancelScan} />
    ) : (
      <ScanReadyHero
        historicalFreedBytes={historicalFreedBytes}
        platform={platform}
        onStartScan={onStartScan}
        onOpenHistory={onOpenHistory}
      />
    );
  }

  const highlightedTier = hoveredTier ?? filter.recommendation ?? null;
  const hasActiveFilters = Boolean(
    searchInput.trim() ||
      filter.category ||
      filter.recommendation ||
      (filter.age && filter.age !== 'all')
  );
  const hasCustomOptions = Boolean((filter.age && filter.age !== 'all') || sortOrder !== 'sizeDesc');

  const headerTitle = activeClient ? activeClient.name : '空间总览';
  const totalCleanableCount = scopeStats.recommendedCount + scopeStats.reviewCount;
  const headerSubtitle = activeClient
    ? `共 ${totalCleanableCount} 项可清理${scopeStats.protectedCount > 0 ? ` · ${scopeStats.protectedCount} 项已锁定保护` : ''}`
    : `已检测 ${reportSummary.detectedBuiltInClientsCount} / ${reportSummary.totalBuiltInProfilesCount} 款客户端 · 共 ${reportSummary.totalItemCount} 项可清理`;

  const noticeText =
    activeClient?.kind === 'unattributedTemp'
      ? '系统临时目录未归属项已跳过其他用户文件、符号链接与活跃锁文件，所有条目均需手动单选确认。'
      : !activeClient && reportSummary.skippedProtectedCount > 0
        ? `SafetyGuard 已自动跳过 ${reportSummary.skippedProtectedCount} 项系统/敏感路径；受保护数据仅只读展示，禁止清理。`
        : null;

  const tiers: Array<{ tier: CleanupRecommendation; bytes: number; count: number }> = [
    { tier: 'recommended', bytes: scopeStats.recommendedBytes, count: scopeStats.recommendedCount },
    { tier: 'reviewSuggested', bytes: scopeStats.reviewBytes, count: scopeStats.reviewCount },
    { tier: 'notRecommended', bytes: scopeStats.protectedBytes, count: scopeStats.protectedCount },
  ];

  const openOptionsMenu = (e: React.MouseEvent<HTMLButtonElement>) => {
    e.stopPropagation();
    const rect = e.currentTarget.getBoundingClientRect();
    setMenuPos({
      left: Math.max(12, rect.right - 220),
      top: rect.bottom + 6,
    });
    setMenuOpen((prev) => !prev);
  };

  const header = (
    <>
      <div className="dashboard-wrap">
        <div className="glass-hero-card">
          <div className="dashboard-inner">
            <div className="dashboard-top">
              <StorageRingGauge
                recommendedBytes={scopeStats.recommendedBytes}
                reviewBytes={scopeStats.reviewBytes}
                protectedBytes={scopeStats.protectedBytes}
                highlightedTier={highlightedTier}
              />

              <div className="dashboard-right">
                <div className="dashboard-title-row">
                  <div style={{ minWidth: 0, flex: 1 }}>
                    <h1 className="dashboard-title" data-testid="dashboard-title">
                      {headerTitle}
                    </h1>
                    <div className="dashboard-subtitle mono-num">{headerSubtitle}</div>
                  </div>

                  <button
                    type="button"
                    className="btn-subtle-pill"
                    disabled={isCleaning}
                    onClick={onReturnToIdle}
                    title="返回扫描并清空本次结果"
                    data-testid="return-to-idle-btn"
                  >
                    <ChevronLeft size={13} />
                    <span>返回扫描</span>
                  </button>

                  {scopeStats.recommendedCount > 0 && (
                    <button
                      type="button"
                      className="btn-glow-primary"
                      disabled={isCleaning || isScanning}
                      onClick={onSelectRecommendedInScope}
                      data-testid="select-recommended-btn"
                    >
                      <Sparkles size={13} />
                      <span className="mono-num">
                        勾选建议清理项 · {formatBytes(scopeStats.recommendedBytes)}
                      </span>
                    </button>
                  )}
                </div>

                <div className="tier-strip">
                  {tiers.map(({ tier, bytes, count }) => {
                    const isSelected = filter.recommendation === tier;
                    const tint = RECOMMENDATION_COLORS[tier];
                    return (
                      <button
                        key={tier}
                        type="button"
                        className={`tier-segment ${isSelected ? 'active' : ''}`}
                        style={{ '--tier-tint': tint } as CSSProperties}
                        onMouseEnter={() => setHoveredTier(tier)}
                        onMouseLeave={() => setHoveredTier((prev) => (prev === tier ? null : prev))}
                        onClick={() =>
                          onChangeFilter({
                            recommendation: isSelected ? null : tier,
                          })
                        }
                        data-testid={`tier-filter-${tier}`}
                      >
                        <span className="tier-dot" style={{ background: tint }} />
                        <div style={{ minWidth: 0 }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11.5 }}>
                            <span style={{ color: isSelected ? 'var(--text-primary)' : 'var(--text-secondary)', fontWeight: isSelected ? 600 : 500 }}>
                              {recommendationDisplayName(tier)}
                            </span>
                            <span className="mono-num" style={{ fontSize: 10.5, color: 'var(--text-tertiary)' }}>
                              {count}
                            </span>
                          </div>
                          <div
                            className="mono-num"
                            style={{
                              fontSize: 13.5,
                              fontWeight: 700,
                              color: bytes > 0 ? (isSelected || hoveredTier === tier ? tint : 'var(--text-primary)') : 'var(--text-tertiary)',
                            }}
                          >
                            {formatBytes(bytes)}
                          </div>
                        </div>
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>

            <HairlineStorageBar
              recommendedBytes={scopeStats.recommendedBytes}
              reviewBytes={scopeStats.reviewBytes}
              protectedBytes={scopeStats.protectedBytes}
              highlightedTier={highlightedTier}
            />
          </div>
        </div>
      </div>

      <div className="control-bar">
        <div className="segmented-track" role="tablist" aria-label="按类别筛选">
          <button
            type="button"
            className={`segmented-btn ${!filter.category ? 'active' : ''}`}
            onClick={() => onChangeFilter({ category: null })}
            data-testid="cat-filter-all"
          >
            全部
          </button>
          {ALL_CATEGORIES.map((category) => (
            <button
              key={category}
              type="button"
              className={`segmented-btn ${filter.category === category ? 'active' : ''}`}
              onClick={() => onChangeFilter({ category })}
              data-testid={`cat-filter-${category}`}
            >
              {categoryShortTitle(category)}
            </button>
          ))}
        </div>

        <span style={{ flex: 1 }} />

        {hasActiveFilters && (
          <button
            type="button"
            style={{
              border: 'none',
              background: 'transparent',
              color: 'var(--accent-blue)',
              fontSize: 12,
              fontWeight: 500,
            }}
            onClick={onResetFilters}
            data-testid="reset-filters-btn"
          >
            重置筛选
          </button>
        )}

        {selection.kind === 'client' && activeClient?.kind === 'builtInClient' && (
          <button
            type="button"
            className="toolbar-btn"
            onClick={() => onOpenClientProjects(selection.clientId)}
            title="查看当前客户端的项目会话"
            data-testid="open-project-sessions-btn"
          >
            <FolderKanban size={13} />
            <span>项目会话</span>
          </button>
        )}

        <div className="search-box">
          <Search size={13} style={{ color: 'var(--text-tertiary)', flexShrink: 0 }} />
          <input
            type="text"
            value={searchInput}
            onChange={(e) => onChangeSearchInput(e.target.value)}
            placeholder="搜索条目、项目或路径…"
            aria-label="搜索条目"
            data-testid="items-search-input"
          />
          {searchInput && (
            <button
              type="button"
              style={{ border: 'none', background: 'transparent', padding: 0, color: 'var(--text-tertiary)' }}
              onClick={() => onChangeSearchInput('')}
              aria-label="清空搜索"
            >
              <X size={13} />
            </button>
          )}
        </div>

        <button
          ref={menuAnchorRef}
          type="button"
          className="toolbar-btn icon-only"
          style={{ position: 'relative' }}
          onClick={openOptionsMenu}
          aria-label="排序、时间筛选与批量操作"
          title="排序、时间筛选与批量操作"
          data-testid="control-options-btn"
        >
          <SlidersHorizontal size={14} />
          {hasCustomOptions && (
            <span
              style={{
                position: 'absolute',
                top: 5,
                right: 5,
                width: 6,
                height: 6,
                borderRadius: '50%',
                background: 'var(--accent-blue)',
              }}
            />
          )}
        </button>

        {menuOpen && (
          <div
            className="popover-menu"
            style={{ left: menuPos.left, top: menuPos.top }}
            onClick={(e) => e.stopPropagation()}
            data-testid="control-options-menu"
          >
            <div className="popover-menu-label">修改时间筛选</div>
            {AGE_OPTIONS.map((age) => (
              <button
                key={age}
                type="button"
                className="popover-menu-item"
                onClick={() => {
                  onChangeFilter({ age });
                  setMenuOpen(false);
                }}
              >
                <span style={{ width: 12 }}>{(filter.age ?? 'all') === age ? '✓' : ''}</span>
                <span>{ageFilterDisplayName(age)}</span>
              </button>
            ))}

            <div className="popover-menu-sep" />
            <div className="popover-menu-label">排序方式</div>
            {SORT_OPTIONS.map((sort) => (
              <button
                key={sort}
                type="button"
                className="popover-menu-item"
                onClick={() => {
                  onChangeSortOrder(sort);
                  setMenuOpen(false);
                }}
              >
                <span style={{ width: 12 }}>{sortOrder === sort ? '✓' : ''}</span>
                <span>{sortOrderDisplayName(sort)}</span>
              </button>
            ))}

            <div className="popover-menu-sep" />
            <div className="popover-menu-label">批量选择</div>
            <button
              type="button"
              className="popover-menu-item"
              onClick={() => {
                onSelectAllVisible();
                setMenuOpen(false);
              }}
            >
              全选可批量勾选项
            </button>
            <button
              type="button"
              className="popover-menu-item"
              onClick={() => {
                onInvertVisible();
                setMenuOpen(false);
              }}
            >
              反选可批量勾选项
            </button>
            <button
              type="button"
              className="popover-menu-item"
              onClick={() => {
                onClearVisible();
                setMenuOpen(false);
              }}
            >
              清空当前可见选择
            </button>
            <button
              type="button"
              className="popover-menu-item"
              onClick={() => {
                onClearAllSelection();
                setMenuOpen(false);
              }}
            >
              清空全部选择
            </button>
          </div>
        )}
      </div>

      {noticeText && (
        <div className="scope-notice-banner">
          <ShieldCheck size={14} style={{ color: 'var(--accent-recommended)', flexShrink: 0 }} />
          <span>{noticeText}</span>
        </div>
      )}
    </>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 }} data-testid="item-list-view">
      <VirtualizedItemList
        header={header}
        groups={groups}
        total={total}
        pageItems={pageItems}
        inFlightPages={inFlightPages}
        onRequestPage={onRequestPage}
        onToggleItem={onToggleItem}
        onToggleSection={onToggleSection}
        onExcludeItem={onExcludeItem}
        onRevealItem={onRevealItem}
        onCopyPath={onCopyPath}
        onInspectFullTitle={onInspectFullTitle}
        isBusy={isCleaning || isScanning}
        platform={platform}
        hasActiveFilters={hasActiveFilters}
        excludedCount={excludedCount}
        onResetFilters={onResetFilters}
        onRescan={onStartScan}
        onOpenExcluded={onOpenExcluded}
        viewportKey={viewportKey}
      />
    </div>
  );
}
