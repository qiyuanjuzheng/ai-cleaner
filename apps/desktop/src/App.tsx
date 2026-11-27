import { AlertTriangle, X } from 'lucide-react';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AddCustomDirectoryModal } from './components/AddCustomDirectoryModal';
import { BottomActionBar } from './components/BottomActionBar';
import { FullTitleModal } from './components/FullTitleModal';
import { RiskConfirmDialog } from './components/RiskConfirmDialog';
import { Sidebar } from './components/Sidebar';
import { Toolbar } from './components/Toolbar';
import { TrashConfirmationModal } from './components/TrashConfirmationModal';
import { formatTimeShort, nextAppearanceMode } from './lib/format';
import { matchShortcutEvent } from './lib/shortcuts';
import { accentColorForToken, EXCLUDED_ACCENT_COLOR } from './lib/theme';
import { ITEMS_PAGE_SIZE } from './lib/virtualRows';
import { CoreClient, CoreRpcError } from './rpc/client';
import type {
  AppearanceMode,
  CleanableItemDTO,
  CleanupHistoryRecordDTO,
  CleanupResultDTO,
  ClientSummaryDTO,
  CustomScanDirectoryDTO,
  DiskCapacityDTO,
  ExcludedItemRecordDTO,
  FilterDTO,
  ItemGroupDTO,
  ItemSortOrder,
  MenuActionId,
  PlatformKind,
  ReportSummaryDTO,
  ScanCategory,
  ScanProgressNotification,
  ScanTargetMode,
  ScopeDTO,
  SelectionSummaryDTO,
  SidebarSelection,
  TrashPreviewResponse,
} from './rpc/types';
import { CleanupHistoryView } from './views/CleanupHistoryView';
import { ExcludedItemsView } from './views/ExcludedItemsView';
import { ItemListView } from './views/ItemListView';
import { ProjectSessionsView } from './views/ProjectSessionsView';

const EMPTY_SELECTION: SelectionSummaryDTO = {
  selectionRevision: 0,
  selectedCount: 0,
  selectedBytes: 0,
  hasNotRecommended: false,
};

interface AppProps {
  client?: CoreClient;
}

export function App({ client }: AppProps) {
  const core = useMemo(() => client ?? new CoreClient(), [client]);

  const [platform, setPlatform] = useState<PlatformKind>('macos');
  const [appearanceMode, setAppearanceMode] = useState<AppearanceMode>('light');
  const [systemDark, setSystemDark] = useState<boolean>(() =>
    typeof window !== 'undefined' && typeof window.matchMedia === 'function'
      ? window.matchMedia('(prefers-color-scheme: dark)').matches
      : false
  );

  const [sidebarSelection, setSidebarSelection] = useState<SidebarSelection>({ kind: 'allClients' });
  const [errorBanner, setErrorBanner] = useState<string | null>(null);
  const [toastNotice, setToastNotice] = useState<string | null>(null);

  // Scan state
  const [scanId, setScanId] = useState<string | null>(null);
  const [activeScanId, setActiveScanId] = useState<string | null>(null);
  const [isScanning, setIsScanning] = useState(false);
  const [scanProgress, setScanProgress] = useState<ScanProgressNotification | null>(null);
  const [reportRevision, setReportRevision] = useState(0);
  const [reportSummary, setReportSummary] = useState<ReportSummaryDTO | null>(null);
  const [clients, setClients] = useState<ClientSummaryDTO[]>([]);

  // Items query & virtual pagination state
  const [filter, setFilter] = useState<FilterDTO>({ age: 'all' });
  const [searchInput, setSearchInput] = useState('');
  const [sortOrder, setSortOrder] = useState<ItemSortOrder>('sizeDesc');
  const [groups, setGroups] = useState<ItemGroupDTO[]>([]);
  const [totalItems, setTotalItems] = useState(0);
  const [pageItems, setPageItems] = useState<Map<number, CleanableItemDTO[]>>(() => new Map());
  const [inFlightPages, setInFlightPages] = useState<Set<number>>(() => new Set());
  const [scopeUnfilteredGroups, setScopeUnfilteredGroups] = useState<ItemGroupDTO[] | null>(null);
  const queryEpochRef = useRef(0);

  // Selection & Cleanup state
  const [selectionSummary, setSelectionSummary] = useState<SelectionSummaryDTO>(EMPTY_SELECTION);
  const [pendingRiskItem, setPendingRiskItem] = useState<CleanableItemDTO | null>(null);
  const [trashPreview, setTrashPreview] = useState<TrashPreviewResponse | null>(null);
  const [trashStaleError, setTrashStaleError] = useState<string | null>(null);
  const [isCleaning, setIsCleaning] = useState(false);
  const [lastCleanupResult, setLastCleanupResult] = useState<CleanupResultDTO | null>(null);
  const [celebrationKey, setCelebrationKey] = useState(0);

  // Persisted domain data
  const [historyRecords, setHistoryRecords] = useState<CleanupHistoryRecordDTO[]>([]);
  const [excludedRecords, setExcludedRecords] = useState<ExcludedItemRecordDTO[]>([]);
  const [excludedStatuses, setExcludedStatuses] = useState<Record<string, boolean>>({});
  const [customDirs, setCustomDirs] = useState<CustomScanDirectoryDTO[]>([]);
  const [diskCapacity, setDiskCapacity] = useState<DiskCapacityDTO | null>(null);
  const [diskUnavailable, setDiskUnavailable] = useState(false);

  // Modals
  const [showingAddCustom, setShowingAddCustom] = useState(false);
  const [inspectedItem, setInspectedItem] = useState<CleanableItemDTO | null>(null);

  const effectiveTheme: 'light' | 'dark' =
    appearanceMode === 'system' ? (systemDark ? 'dark' : 'light') : appearanceMode;

  useEffect(() => {
    document.documentElement.dataset.theme = effectiveTheme;
    document.documentElement.dataset.platform = platform;
  }, [effectiveTheme, platform]);

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = (e: MediaQueryListEvent) => setSystemDark(e.matches);
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, []);

  const showToast = useCallback((message: string) => {
    setToastNotice(message);
    window.setTimeout(() => {
      setToastNotice((prev) => (prev === message ? null : prev));
    }, 2200);
  }, []);

  const handleCoreError = useCallback((err: unknown) => {
    if (err instanceof CoreRpcError) {
      if (err.code === -32000 || err.errorName === 'PROTOCOL_VERSION_MISMATCH') {
        setErrorBanner('安装不完整或核心协议版本不匹配，请重新安装 AI Cleaner。');
        return;
      }
      if (err.code === -32021 || err.errorName === 'STORAGE_CORRUPT') {
        setErrorBanner(`检测到本地数据文件损坏，原文件已备份保留：${err.reason ?? err.message}`);
        return;
      }
      setErrorBanner(err.reason || err.message);
      return;
    }
    setErrorBanner(err instanceof Error ? err.message : '操作失败，请稍后重试。');
  }, []);

  const refreshHistory = useCallback(async () => {
    try {
      const res = await core.listHistory();
      setHistoryRecords(res.records);
    } catch (err) {
      handleCoreError(err);
    }
  }, [core, handleCoreError]);

  const refreshExcluded = useCallback(async () => {
    try {
      const res = await core.listExcluded();
      setExcludedRecords(res.records);
      setExcludedStatuses(res.statuses);
    } catch (err) {
      handleCoreError(err);
    }
  }, [core, handleCoreError]);

  const refreshCustomDirs = useCallback(async () => {
    try {
      const res = await core.listCustomDirs();
      setCustomDirs(res.directories);
    } catch (err) {
      handleCoreError(err);
    }
  }, [core, handleCoreError]);

  const refreshDiskCapacity = useCallback(async () => {
    try {
      const cap = await core.getDiskCapacity();
      setDiskCapacity(cap);
      setDiskUnavailable(cap.total === null || cap.available === null);
    } catch {
      setDiskUnavailable(true);
    }
  }, [core]);

  const refreshReportSnapshot = useCallback(
    async (targetScanId: string) => {
      const [summary, clientList] = await Promise.all([
        core.getReportSummary(targetScanId),
        core.listClients(targetScanId),
      ]);
      setReportSummary(summary);
      setClients(clientList.clients);
    },
    [core]
  );

  // Initial handshake and bootstrap
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const hello = await core.handshake();
        if (cancelled) return;
        setPlatform(hello.platform);

        const [settingsRes] = await Promise.allSettled([
          core.getSettings(),
          refreshHistory(),
          refreshExcluded(),
          refreshCustomDirs(),
          refreshDiskCapacity(),
        ]);
        if (!cancelled && settingsRes.status === 'fulfilled') {
          setAppearanceMode(settingsRes.value.appearanceMode);
        }
      } catch (err) {
        if (!cancelled) {
          handleCoreError(err);
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [core, handleCoreError, refreshCustomDirs, refreshDiskCapacity, refreshExcluded, refreshHistory]);

  // 60s heartbeat + disk refresh while visible (ADR 0001 §6.4)
  useEffect(() => {
    const interval = window.setInterval(() => {
      if (document.visibilityState === 'visible') {
        void core.ping().catch(() => {});
        void refreshDiskCapacity();
      }
    }, 60_000);
    return () => window.clearInterval(interval);
  }, [core, refreshDiskCapacity]);

  // Subscribe to sidecar scan notifications
  useEffect(() => {
    return core.transport.onNotification((note) => {
      if (note.method === 'scan.progress') {
        setScanProgress(note.params);
      } else if (note.method === 'scan.completed') {
        const { scanId: completedScanId, status, reportRevision: nextRev, summary, error } = note.params;
        setIsScanning(false);
        setActiveScanId(null);
        setScanProgress(null);

        if (status === 'completed' && summary) {
          setScanId(completedScanId);
          setReportSummary(summary);
          setReportRevision(nextRev);
          setSelectionSummary(EMPTY_SELECTION);
          setLastCleanupResult(null);
          void core
            .listClients(completedScanId)
            .then((res) => setClients(res.clients))
            .catch(handleCoreError);
          void refreshDiskCapacity();
        } else if (status === 'failed' && error) {
          handleCoreError(new CoreRpcError(error));
        }
      }
    });
  }, [core, handleCoreError, refreshDiskCapacity]);

  // Debounce search input -> filter.search
  useEffect(() => {
    const timer = window.setTimeout(() => {
      setFilter((prev) => {
        const nextSearch = searchInput.trim() || null;
        if ((prev.search ?? null) === nextSearch) return prev;
        return { ...prev, search: nextSearch };
      });
    }, 120);
    return () => window.clearTimeout(timer);
  }, [searchInput]);

  const currentScope: ScopeDTO = useMemo(() => {
    if (sidebarSelection.kind === 'client') {
      return { kind: 'client', clientId: sidebarSelection.clientId };
    }
    return { kind: 'all' };
  }, [sidebarSelection]);

  const isListPage = sidebarSelection.kind === 'allClients' || sidebarSelection.kind === 'client';

  // Fetch page 0 and scope stats whenever scanId, scope, filter, sort, reportRevision, or selectionRevision changes
  const fetchPage = useCallback(
    async (
      targetScanId: string,
      pageIndex: number,
      scope: ScopeDTO,
      activeFilter: FilterDTO,
      sort: ItemSortOrder,
      epoch: number
    ) => {
      setInFlightPages((prev) => new Set(prev).add(pageIndex));
      try {
        const res = await core.queryItems({
          scanId: targetScanId,
          scope,
          filter: activeFilter,
          sort,
          offset: pageIndex * ITEMS_PAGE_SIZE,
          limit: ITEMS_PAGE_SIZE,
        });
        if (queryEpochRef.current !== epoch) return;
        setGroups(res.groups);
        setTotalItems(res.total);
        setPageItems((prev) => {
          const next = new Map(prev);
          next.set(pageIndex, res.items);
          return next;
        });
      } catch (err) {
        if (queryEpochRef.current === epoch) {
          handleCoreError(err);
        }
      } finally {
        setInFlightPages((prev) => {
          if (!prev.has(pageIndex)) return prev;
          const next = new Set(prev);
          next.delete(pageIndex);
          return next;
        });
      }
    },
    [core, handleCoreError]
  );

  useEffect(() => {
    if (!scanId || !reportSummary || !isListPage) {
      setGroups([]);
      setTotalItems(0);
      setPageItems(new Map());
      return;
    }
    const epoch = ++queryEpochRef.current;
    setPageItems(new Map());
    setInFlightPages(new Set());
    void fetchPage(scanId, 0, currentScope, filter, sortOrder, epoch);
  }, [scanId, reportSummary, isListPage, currentScope, filter, sortOrder, reportRevision, selectionSummary.selectionRevision, fetchPage]);

  // Keep scope-level unfiltered counts accurate for client dashboard headers
  useEffect(() => {
    if (!scanId || !reportSummary || sidebarSelection.kind !== 'client') {
      setScopeUnfilteredGroups(null);
      return;
    }
    let cancelled = false;
    void core
      .queryItems({
        scanId,
        scope: { kind: 'client', clientId: sidebarSelection.clientId },
        offset: 0,
        limit: 1,
      })
      .then((res) => {
        if (!cancelled) setScopeUnfilteredGroups(res.groups);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [core, scanId, reportSummary, sidebarSelection, reportRevision]);

  const handleRequestPage = useCallback(
    (pageIndex: number) => {
      if (!scanId) return;
      const epoch = queryEpochRef.current;
      void fetchPage(scanId, pageIndex, currentScope, filter, sortOrder, epoch);
    },
    [scanId, currentScope, filter, sortOrder, fetchPage]
  );

  // Actions
  const handleStartScan = useCallback(async () => {
    if (isScanning || isCleaning) return;
    setErrorBanner(null);
    setLastCleanupResult(null);
    setTrashPreview(null);
    setReportSummary(null);
    setScanId(null);
    setClients([]);
    setSelectionSummary(EMPTY_SELECTION);
    setIsScanning(true);
    setScanProgress(null);
    if (sidebarSelection.kind === 'history' || sidebarSelection.kind === 'excluded') {
      setSidebarSelection({ kind: 'allClients' });
    }
    try {
      const res = await core.startScan();
      setActiveScanId(res.scanId);
    } catch (err) {
      setIsScanning(false);
      setActiveScanId(null);
      handleCoreError(err);
    }
  }, [core, handleCoreError, isCleaning, isScanning, sidebarSelection.kind]);

  const handleCancelScan = useCallback(async () => {
    if (!activeScanId) return;
    try {
      await core.cancelScan(activeScanId);
    } catch (err) {
      handleCoreError(err);
    }
  }, [activeScanId, core, handleCoreError]);

  const handleReturnToIdle = useCallback(() => {
    if (isCleaning) return;
    setScanId(null);
    setReportSummary(null);
    setClients([]);
    setGroups([]);
    setTotalItems(0);
    setPageItems(new Map());
    setSelectionSummary(EMPTY_SELECTION);
    setLastCleanupResult(null);
    setSidebarSelection({ kind: 'allClients' });
  }, [isCleaning]);

  const handleCycleAppearance = useCallback(async () => {
    const next = nextAppearanceMode(appearanceMode);
    setAppearanceMode(next);
    try {
      await core.setSettings(next);
    } catch (err) {
      handleCoreError(err);
    }
  }, [appearanceMode, core, handleCoreError]);

  const handleToggleItem = useCallback(
    async (item: CleanableItemDTO) => {
      if (!scanId || item.hardProtectionReason) return;
      if (!item.selected && item.recommendation === 'notRecommended') {
        setPendingRiskItem(item);
        return;
      }
      try {
        const nextSel = await core.applySelection({
          scanId,
          op: 'toggle',
          scope: currentScope,
          filter,
          itemIds: [item.id],
        });
        setSelectionSummary(nextSel);
      } catch (err) {
        if (err instanceof CoreRpcError && err.code === -32005) {
          setPendingRiskItem(item);
        } else {
          handleCoreError(err);
        }
      }
    },
    [core, currentScope, filter, handleCoreError, scanId]
  );

  const handleConfirmRisk = useCallback(async () => {
    if (!scanId || !pendingRiskItem) return;
    const target = pendingRiskItem;
    setPendingRiskItem(null);
    try {
      const nextSel = await core.confirmRisk(scanId, target.id);
      setSelectionSummary(nextSel);
    } catch (err) {
      handleCoreError(err);
    }
  }, [core, handleCoreError, pendingRiskItem, scanId]);

  const handleApplySelectionOp = useCallback(
    async (
      op:
        | 'selectRecommendedInScope'
        | 'toggleSection'
        | 'selectAllVisible'
        | 'invertVisible'
        | 'clearVisible'
        | 'clearAll',
      recommendation?: 'recommended' | 'reviewSuggested'
    ) => {
      if (!scanId) return;
      try {
        const nextSel = await core.applySelection({
          scanId,
          op,
          scope: op === 'clearAll' ? null : currentScope,
          filter: op === 'clearAll' || op === 'selectRecommendedInScope' ? null : filter,
          recommendation,
        });
        setSelectionSummary(nextSel);
      } catch (err) {
        handleCoreError(err);
      }
    },
    [core, currentScope, filter, handleCoreError, scanId]
  );

  const handleRequestTrash = useCallback(async () => {
    if (!scanId || selectionSummary.selectedCount === 0) return;
    setTrashStaleError(null);
    try {
      const preview = await core.previewTrash(scanId);
      setTrashPreview(preview);
    } catch (err) {
      handleCoreError(err);
    }
  }, [core, handleCoreError, scanId, selectionSummary.selectedCount]);

  const handleExecuteTrash = useCallback(
    async (acknowledgedRisk: boolean) => {
      if (!scanId || !trashPreview) return;
      setIsCleaning(true);
      setTrashStaleError(null);
      try {
        const res = await core.executeTrash({
          scanId,
          confirmationToken: trashPreview.confirmationToken,
          acknowledgedNotRecommendedRisk: acknowledgedRisk,
        });
        setTrashPreview(null);
        setReportRevision(res.reportRevision);
        setSelectionSummary(EMPTY_SELECTION);
        setLastCleanupResult(res.result);
        if (res.result.trashedCount > 0 && res.result.failedItems.length === 0 && res.result.skippedProtectedItems.length === 0) {
          setCelebrationKey((k) => k + 1);
        }
        if (res.historyError) {
          handleCoreError(new CoreRpcError(res.historyError));
        }
        await Promise.all([refreshReportSnapshot(scanId), refreshHistory(), refreshDiskCapacity()]);
      } catch (err) {
        if (err instanceof CoreRpcError && (err.code === -32006 || err.errorName === 'CONFIRMATION_TOKEN_INVALID')) {
          setTrashStaleError('所选条目或扫描状态已变化，确认清单已失效，请刷新清单后再次确认。');
        } else {
          setTrashPreview(null);
          handleCoreError(err);
        }
      } finally {
        setIsCleaning(false);
      }
    },
    [core, handleCoreError, refreshDiskCapacity, refreshHistory, refreshReportSnapshot, scanId, trashPreview]
  );

  const handleExcludeItem = useCallback(
    async (item: CleanableItemDTO) => {
      if (!scanId) return;
      try {
        const res = await core.addExcluded(scanId, item.id);
        setReportRevision(res.reportRevision);
        await Promise.all([refreshReportSnapshot(scanId), refreshExcluded()]);
        showToast(`已排除「${item.preferredTitle}」`);
      } catch (err) {
        handleCoreError(err);
      }
    },
    [core, handleCoreError, refreshExcluded, refreshReportSnapshot, scanId, showToast]
  );

  const handleRestoreExcluded = useCallback(
    async (id: string) => {
      try {
        await core.restoreExcluded(id);
        await refreshExcluded();
        if (scanId) {
          setReportRevision((r) => r + 1);
          await refreshReportSnapshot(scanId);
        }
      } catch (err) {
        handleCoreError(err);
      }
    },
    [core, handleCoreError, refreshExcluded, refreshReportSnapshot, scanId]
  );

  const handleRestoreAllExcluded = useCallback(async () => {
    try {
      await core.restoreAllExcluded();
      await refreshExcluded();
      if (scanId) {
        setReportRevision((r) => r + 1);
        await refreshReportSnapshot(scanId);
      }
    } catch (err) {
      handleCoreError(err);
    }
  }, [core, handleCoreError, refreshExcluded, refreshReportSnapshot, scanId]);

  const handleAddCustomDir = useCallback(
    async (params: { path: string; displayName?: string; category: ScanCategory; mode: ScanTargetMode }) => {
      await core.addCustomDir(params);
      await refreshCustomDirs();
      void handleStartScan();
    },
    [core, handleStartScan, refreshCustomDirs]
  );

  const handleRemoveCustomDir = useCallback(
    async (id: string) => {
      try {
        await core.removeCustomDir(id);
        await refreshCustomDirs();
        if (sidebarSelection.kind === 'client' && sidebarSelection.clientId === `custom-${id}`) {
          setSidebarSelection({ kind: 'allClients' });
        }
      } catch (err) {
        handleCoreError(err);
      }
    },
    [core, handleCoreError, refreshCustomDirs, sidebarSelection]
  );

  const handleInspectFullTitle = useCallback(
    async (item: CleanableItemDTO) => {
      setInspectedItem(item);
      if (!scanId) return;
      try {
        const res = await core.getItems(scanId, [item.id]);
        if (res.items[0]) {
          setInspectedItem(res.items[0]);
        }
      } catch {
        // Keep initial snapshot if items.get fails
      }
    },
    [core, scanId]
  );

  const handleRevealItem = useCallback(
    (item: CleanableItemDTO) => {
      if (!scanId) return;
      void core.transport.revealScanItem(scanId, item.id).catch(handleCoreError);
    },
    [core, handleCoreError, scanId]
  );

  const handleRevealExcluded = useCallback(
    (rec: ExcludedItemRecordDTO) => {
      void core.transport.revealExcludedItem(rec.id).catch(handleCoreError);
    },
    [core, handleCoreError]
  );

  const handleCopyText = useCallback(
    (text: string) => {
      if (navigator.clipboard?.writeText) {
        void navigator.clipboard.writeText(text).then(() => showToast('已复制到剪贴板'));
      }
    },
    [showToast]
  );

  const handleToggleProjectSession = useCallback(
    async (item: CleanableItemDTO, projectId: string, showsAllClients: boolean) => {
      if (!scanId || item.hardProtectionReason) return;
      if (!item.selected && item.recommendation === 'notRecommended') {
        setPendingRiskItem(item);
        return;
      }
      try {
        const scope: ScopeDTO = showsAllClients
          ? { kind: 'all' }
          : { kind: 'clientProjects', clientId: item.clientId, projectId };
        const nextSel = await core.applySelection({
          scanId,
          op: 'toggle',
          scope,
          itemIds: [item.id],
        });
        setSelectionSummary(nextSel);
      } catch (err) {
        if (err instanceof CoreRpcError && err.code === -32005) {
          setPendingRiskItem(item);
        } else {
          handleCoreError(err);
        }
      }
    },
    [core, handleCoreError, scanId]
  );

  const handleSelectAllProjectSessions = useCallback(
    async (sessions: CleanableItemDTO[], projectId: string, showsAllClients: boolean) => {
      if (!scanId) return;
      try {
        if (!showsAllClients && sidebarSelection.kind === 'clientProjects') {
          const nextSel = await core.applySelection({
            scanId,
            op: 'selectAllVisible',
            scope: { kind: 'clientProjects', clientId: sidebarSelection.clientId, projectId },
          });
          setSelectionSummary(nextSel);
          return;
        }
        const unchecked = sessions
          .filter((s) => s.bulkSelectable && !s.hardProtectionReason && !s.selected)
          .map((s) => s.id);
        if (unchecked.length === 0) return;
        let latest = selectionSummary;
        for (let i = 0; i < unchecked.length; i += 500) {
          latest = await core.applySelection({
            scanId,
            op: 'toggle',
            scope: { kind: 'all' },
            itemIds: unchecked.slice(i, i + 500),
          });
        }
        setSelectionSummary(latest);
      } catch (err) {
        handleCoreError(err);
      }
    },
    [core, handleCoreError, scanId, selectionSummary, sidebarSelection]
  );

  const handleToggleProjectProtection = useCallback(
    async (projectId: string, nextProtected: boolean) => {
      if (!scanId) return;
      try {
        await core.setProjectProtection(projectId, nextProtected);
        setReportRevision((r) => r + 1);
        await refreshReportSnapshot(scanId);
      } catch (err) {
        handleCoreError(err);
      }
    },
    [core, handleCoreError, refreshReportSnapshot, scanId]
  );

  // Unified menu & keyboard shortcut dispatch
  const handleMenuAction = useCallback(
    (action: MenuActionId) => {
      switch (action) {
        case 'scan.start':
          void handleStartScan();
          break;
        case 'scan.return':
          handleReturnToIdle();
          break;
        case 'customDirs.openAdd':
          setShowingAddCustom(true);
          break;
        case 'nav.history':
          setSidebarSelection({ kind: 'history' });
          break;
        case 'nav.excluded':
          setSidebarSelection({ kind: 'excluded' });
          break;
        case 'selection.recommended':
          if (isListPage) void handleApplySelectionOp('selectRecommendedInScope');
          break;
        case 'selection.selectAll':
          if (isListPage) void handleApplySelectionOp('selectAllVisible');
          break;
        case 'selection.invert':
          if (isListPage) void handleApplySelectionOp('invertVisible');
          break;
        case 'selection.clear':
          void handleApplySelectionOp('clearAll');
          break;
        case 'appearance.cycle':
          void handleCycleAppearance();
          break;
      }
    },
    [handleApplySelectionOp, handleCycleAppearance, handleReturnToIdle, handleStartScan, isListPage]
  );

  useEffect(() => core.transport.onMenuAction(handleMenuAction), [core, handleMenuAction]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const matched = matchShortcutEvent(event, platform);
      if (matched) {
        event.preventDefault();
        handleMenuAction(matched);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [handleMenuAction, platform]);

  // Derived display values
  const activeClient = useMemo(() => {
    if (sidebarSelection.kind === 'client' || sidebarSelection.kind === 'clientProjects') {
      return clients.find((c) => c.id === sidebarSelection.clientId) ?? null;
    }
    return null;
  }, [clients, sidebarSelection]);

  const scopeStats = useMemo(() => {
    if (activeClient) {
      const recGroup = scopeUnfilteredGroups?.find((g) => g.recommendation === 'recommended');
      const revGroup = scopeUnfilteredGroups?.find((g) => g.recommendation === 'reviewSuggested');
      const protGroup = scopeUnfilteredGroups?.find((g) => g.recommendation === 'notRecommended');
      return {
        recommendedBytes: activeClient.recommendedSizeBytes,
        recommendedCount: recGroup?.itemCount ?? (activeClient.recommendedSizeBytes > 0 ? 1 : 0),
        reviewBytes: activeClient.reviewSuggestedSizeBytes,
        reviewCount: revGroup?.itemCount ?? (activeClient.reviewSuggestedSizeBytes > 0 ? 1 : 0),
        protectedBytes: activeClient.protectedSizeBytes,
        protectedCount: protGroup?.itemCount ?? (activeClient.protectedSizeBytes > 0 ? 1 : 0),
      };
    }
    return {
      recommendedBytes: reportSummary?.recommendedSizeBytes ?? 0,
      recommendedCount: reportSummary?.totalRecommendedCount ?? 0,
      reviewBytes: reportSummary?.reviewSuggestedSizeBytes ?? 0,
      reviewCount: reportSummary?.totalReviewSuggestedCount ?? 0,
      protectedBytes: reportSummary?.protectedSizeBytes ?? 0,
      protectedCount: reportSummary?.totalProtectedItemCount ?? 0,
    };
  }, [activeClient, reportSummary, scopeUnfilteredGroups]);

  const historicalFreedBytes = useMemo(
    () => historyRecords.reduce((sum, r) => sum + Math.max(0, r.freedBytes), 0),
    [historyRecords]
  );

  const activeAccent = useMemo(() => {
    if (sidebarSelection.kind === 'excluded') return EXCLUDED_ACCENT_COLOR;
    if (sidebarSelection.kind === 'history') return '#3db8fa';
    if (activeClient) return accentColorForToken(activeClient.accentToken);
    return '#29cc99';
  }, [activeClient, sidebarSelection.kind]);

  const viewportKey = `${sidebarSelection.kind}-${'clientId' in sidebarSelection ? sidebarSelection.clientId : ''}-${filter.category ?? ''}-${filter.recommendation ?? ''}-${filter.age ?? ''}-${filter.search ?? ''}-${sortOrder}`;

  return (
    <div className="app-shell">
      <Sidebar
        selection={sidebarSelection}
        onSelect={(next) => {
          setSidebarSelection(next);
          if (next.kind === 'excluded') void refreshExcluded();
          if (next.kind === 'history') void refreshHistory();
        }}
        isScanning={isScanning}
        reportSummary={reportSummary}
        clients={clients}
        customDirs={customDirs}
        onRemoveCustomDir={(id) => void handleRemoveCustomDir(id)}
        historicalFreedBytes={historicalFreedBytes}
        excludedCount={excludedRecords.length}
        diskCapacity={diskCapacity}
        diskUnavailable={diskUnavailable}
        lastScanTime={formatTimeShort(reportSummary?.scannedAt)}
        platform={platform}
        effectiveTheme={effectiveTheme}
      />

      <main className="detail-pane">
        <div
          className="aurora-backdrop"
          style={{
            background: `radial-gradient(640px 320px at 85% -10%, color-mix(in srgb, ${activeAccent} calc(var(--aurora-opacity) * 100%), transparent), transparent 72%)`,
          }}
          aria-hidden="true"
        />

        <div className="detail-content">
          <Toolbar
            appearanceMode={appearanceMode}
            onCycleAppearance={() => void handleCycleAppearance()}
            onOpenAddCustom={() => setShowingAddCustom(true)}
            onStartScan={() => void handleStartScan()}
            hasScanResults={reportSummary !== null}
            isScanning={isScanning}
            isCleaning={isCleaning}
            platform={platform}
          />

          {errorBanner && (
            <div className="error-banner" role="alert" data-testid="error-banner">
              <AlertTriangle size={15} style={{ color: 'var(--accent-review)', flexShrink: 0 }} />
              <span style={{ flex: 1 }}>{errorBanner}</span>
              <button
                type="button"
                className="row-action-btn"
                onClick={() => setErrorBanner(null)}
                aria-label="关闭错误提示"
              >
                <X size={13} />
              </button>
            </div>
          )}

          {toastNotice && (
            <div
              style={{
                position: 'fixed',
                top: 56,
                right: 22,
                zIndex: 90,
                padding: '7px 14px',
                borderRadius: 999,
                background: 'var(--elevated-bg)',
                border: '1px solid var(--border-rim)',
                boxShadow: 'var(--shadow-card)',
                fontSize: 12,
                fontWeight: 500,
              }}
              role="status"
            >
              {toastNotice}
            </div>
          )}

          <ItemListView
            visible={isListPage}
            selection={sidebarSelection}
            reportSummary={reportSummary}
            activeClient={activeClient}
            scopeStats={scopeStats}
            isScanning={isScanning}
            isCleaning={isCleaning}
            scanProgress={scanProgress}
            historicalFreedBytes={historicalFreedBytes}
            excludedCount={excludedRecords.length}
            filter={filter}
            searchInput={searchInput}
            sortOrder={sortOrder}
            groups={groups}
            total={totalItems}
            pageItems={pageItems}
            inFlightPages={inFlightPages}
            platform={platform}
            effectiveTheme={effectiveTheme}
            viewportKey={viewportKey}
            onStartScan={() => void handleStartScan()}
            onCancelScan={() => void handleCancelScan()}
            onReturnToIdle={handleReturnToIdle}
            onOpenHistory={() => setSidebarSelection({ kind: 'history' })}
            onOpenExcluded={() => {
              setSidebarSelection({ kind: 'excluded' });
              void refreshExcluded();
            }}
            onOpenClientProjects={(clientId) => setSidebarSelection({ kind: 'clientProjects', clientId })}
            onSelectRecommendedInScope={() => void handleApplySelectionOp('selectRecommendedInScope')}
            onSelectAllVisible={() => void handleApplySelectionOp('selectAllVisible')}
            onInvertVisible={() => void handleApplySelectionOp('invertVisible')}
            onClearVisible={() => void handleApplySelectionOp('clearVisible')}
            onClearAllSelection={() => void handleApplySelectionOp('clearAll')}
            onChangeFilter={(patch) => setFilter((prev) => ({ ...prev, ...patch }))}
            onChangeSearchInput={setSearchInput}
            onChangeSortOrder={setSortOrder}
            onResetFilters={() => {
              setSearchInput('');
              setFilter({ age: 'all' });
              setSortOrder('sizeDesc');
            }}
            onRequestPage={handleRequestPage}
            onToggleItem={(item) => void handleToggleItem(item)}
            onToggleSection={(rec) => void handleApplySelectionOp('toggleSection', rec)}
            onExcludeItem={(item) => void handleExcludeItem(item)}
            onRevealItem={handleRevealItem}
            onCopyPath={handleCopyText}
            onInspectFullTitle={(item) => void handleInspectFullTitle(item)}
          />

          {sidebarSelection.kind === 'clientProjects' && (
            <ProjectSessionsView
              core={core}
              scanId={scanId}
              client={activeClient}
              reportRevision={reportRevision}
              selectionRevision={selectionSummary.selectionRevision}
              isBusy={isCleaning || isScanning}
              platform={platform}
              onBackToClient={() => setSidebarSelection({ kind: 'client', clientId: sidebarSelection.clientId })}
              onToggleSessionItem={handleToggleProjectSession}
              onSelectAllSessions={handleSelectAllProjectSessions}
              onToggleProtection={handleToggleProjectProtection}
              onInspectFullTitle={(item) => void handleInspectFullTitle(item)}
              onRevealItem={handleRevealItem}
              onStartScan={() => void handleStartScan()}
            />
          )}

          <CleanupHistoryView
            visible={sidebarSelection.kind === 'history'}
            records={historyRecords}
            platform={platform}
            effectiveTheme={effectiveTheme}
            onDeleteRecord={async (id) => {
              try {
                await core.deleteHistory(id);
                await refreshHistory();
              } catch (err) {
                handleCoreError(err);
              }
            }}
            onClearAll={async () => {
              try {
                await core.clearHistory();
                await refreshHistory();
              } catch (err) {
                handleCoreError(err);
              }
            }}
          />

          <ExcludedItemsView
            visible={sidebarSelection.kind === 'excluded'}
            records={excludedRecords}
            statuses={excludedStatuses}
            hasScanResults={reportSummary !== null}
            platform={platform}
            effectiveTheme={effectiveTheme}
            onRestore={handleRestoreExcluded}
            onRestoreAll={handleRestoreAllExcluded}
            onReveal={handleRevealExcluded}
            onCopyPath={handleCopyText}
            onBackToOverview={() => setSidebarSelection({ kind: 'allClients' })}
          />
        </div>

        <BottomActionBar
          visible={isListPage || sidebarSelection.kind === 'clientProjects'}
          selection={selectionSummary}
          isScanning={isScanning}
          isCleaning={isCleaning}
          lastCleanupResult={lastCleanupResult}
          celebrationKey={celebrationKey}
          platform={platform}
          onClearSelection={() => void handleApplySelectionOp('clearAll')}
          onRequestTrash={() => void handleRequestTrash()}
          onDismissResult={() => setLastCleanupResult(null)}
          onOpenHistory={() => setSidebarSelection({ kind: 'history' })}
        />
      </main>

      {pendingRiskItem && (
        <RiskConfirmDialog
          item={pendingRiskItem}
          platform={platform}
          onCancel={() => setPendingRiskItem(null)}
          onConfirm={() => void handleConfirmRisk()}
        />
      )}

      {trashPreview && (
        <TrashConfirmationModal
          preview={trashPreview}
          platform={platform}
          isExecuting={isCleaning}
          staleError={trashStaleError}
          onCancel={() => {
            setTrashPreview(null);
            setTrashStaleError(null);
          }}
          onConfirm={(ack) => void handleExecuteTrash(ack)}
          onRefreshPreview={() => void handleRequestTrash()}
        />
      )}

      {showingAddCustom && (
        <AddCustomDirectoryModal
          platform={platform}
          onClose={() => setShowingAddCustom(false)}
          onPickDirectory={() => core.transport.pickDirectory()}
          onValidate={(path) => core.validateCustomDir(path)}
          onSubmit={handleAddCustomDir}
        />
      )}

      {inspectedItem && (
        <FullTitleModal
          item={inspectedItem}
          platform={platform}
          onClose={() => setInspectedItem(null)}
          onCopyText={handleCopyText}
          onReveal={handleRevealItem}
        />
      )}
    </div>
  );
}
