import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { App } from './App';
import { CoreClient, CoreRpcError } from './rpc/client';
import type { CoreTransport } from './rpc/client';
import type {
  CleanableItemDTO,
  CleanupHistoryRecordDTO,
  CoreNotification,
  MenuActionId,
  PlatformKind,
} from './rpc/types';

function createMockTransport(options?: { platform?: PlatformKind; failHandshake?: boolean }) {
  const platform: PlatformKind = options?.platform ?? 'macos';
  let notificationListener: ((n: CoreNotification) => void) | null = null;
  let menuListener: ((a: MenuActionId) => void) | null = null;

  let selectedIds = new Set<string>();
  let excludedIds = new Set<string>();
  let projectProtected = false;
  let history: CleanupHistoryRecordDTO[] = [];
  let appearance: 'light' | 'dark' | 'system' = 'light';
  let scanCount = 0;
  let currentScanId: string | null = null;

  const items: CleanableItemDTO[] = [
    {
      id: 'item-rec-1',
      clientId: 'codex',
      clientName: 'Codex',
      ruleId: 'codex-tmp',
      displayName: '临时文件',
      preferredTitle: 'stale.tmp',
      fileName: 'stale.tmp',
      path: '/Users/test/.codex/tmp/stale.tmp',
      category: 'temporary',
      recommendation: 'recommended',
      safetyNote: '临时文件，可安全清理。',
      requiresIndividualSelection: false,
      bulkSelectable: true,
      selected: false,
      isRecentlyModified: false,
      isSessionArtifact: false,
      isDirectory: false,
      isCustom: false,
      sizeBytes: 2048,
      fileCount: 1,
      modifiedAt: '2026-11-20T10:00:00Z',
    },
    {
      id: 'item-sess-1',
      clientId: 'codex',
      clientName: 'Codex',
      ruleId: 'codex-sessions',
      displayName: '会话记录',
      preferredTitle: 'Refactor cross-platform Tauri architecture',
      sessionTitle: 'Refactor cross-platform Tauri architecture with full Swift Core sidecar parity',
      sessionProjectName: 'ai-cleaner',
      fileName: 'rollout-1.jsonl',
      path: '/Users/test/.codex/sessions/2026/11/20/rollout-1.jsonl',
      category: 'sessions',
      recommendation: 'reviewSuggested',
      safetyNote: '旧会话记录，建议按需清理。',
      requiresIndividualSelection: false,
      bulkSelectable: true,
      selected: false,
      isRecentlyModified: false,
      isSessionArtifact: false,
      isDirectory: false,
      isCustom: false,
      sizeBytes: 4096,
      fileCount: 1,
      modifiedAt: '2026-11-20T11:00:00Z',
    },
    {
      id: 'item-risk-1',
      clientId: 'codex',
      clientName: 'Codex',
      ruleId: 'codex-risk',
      displayName: '模型缓存',
      preferredTitle: 'local-model.bin',
      fileName: 'local-model.bin',
      path: '/Users/test/.codex/models/local-model.bin',
      category: 'cache',
      recommendation: 'notRecommended',
      safetyNote: '删除后需要重新下载模型。',
      requiresIndividualSelection: true,
      bulkSelectable: false,
      selected: false,
      isRecentlyModified: false,
      isSessionArtifact: false,
      isDirectory: false,
      isCustom: false,
      sizeBytes: 8192,
      fileCount: 1,
      modifiedAt: '2026-11-20T12:00:00Z',
    },
  ];

  const visibleItems = () =>
    items
      .filter((i) => !excludedIds.has(i.id))
      .map((i) => ({
        ...i,
        selected: selectedIds.has(i.id),
        hardProtectionReason:
          projectProtected && i.id === 'item-sess-1' ? '所属项目已受保护' : i.hardProtectionReason,
      }));

  const summaryOfSelection = () => {
    const chosen = visibleItems().filter((i) => selectedIds.has(i.id));
    return {
      selectionRevision: selectedIds.size + 1,
      selectedCount: chosen.length,
      selectedBytes: chosen.reduce((s, i) => s + i.sizeBytes, 0),
      hasNotRecommended: chosen.some((i) => i.recommendation === 'notRecommended'),
    };
  };

  const scanNotFound = new CoreRpcError({
    code: -32002,
    message: 'Scan not found',
    data: { name: 'SCAN_NOT_FOUND' },
  });
  const request = vi.fn(async (method: string, params: Record<string, unknown> = {}) => {
    if (typeof params.scanId === 'string' && params.scanId !== currentScanId) {
      throw scanNotFound;
    }
    if (method === 'core.handshake') {
      if (options?.failHandshake) {
        throw new CoreRpcError({
          code: -32000,
          message: 'Protocol version mismatch',
          data: { name: 'PROTOCOL_VERSION_MISMATCH' },
        });
      }
      return {
        protocolVersion: '1.0',
        coreVersion: '1.0',
        platform,
        capabilities: ['scan', 'items', 'selection', 'trash', 'history', 'excluded', 'projects', 'settings'],
      };
    }
    if (method === 'settings.get') return { appearanceMode: appearance };
    if (method === 'settings.set') {
      appearance = params.appearanceMode as 'light' | 'dark' | 'system';
      return { appearanceMode: appearance };
    }
    if (method === 'history.list') return { records: history };
    if (method === 'excluded.list') {
      const records = items
        .filter((i) => excludedIds.has(i.id))
        .map((i) => ({
          id: `ex-${i.id}`,
          normalizedPath: i.path,
          displayName: i.preferredTitle,
          clientID: i.clientId,
          clientName: i.clientName,
          category: i.category,
          isDirectory: i.isDirectory,
          excludedAt: '2026-11-26T10:00:00Z',
        }));
      return { records, statuses: Object.fromEntries(records.map((r) => [r.id, true])) };
    }
    if (method === 'customDirs.list') return { directories: [] };
    if (method === 'disk.capacity') return { total: 500_000_000_000, available: 200_000_000_000 };
    if (method === 'scan.start') {
      const scanId = `scan-${++scanCount}`;
      currentScanId = scanId;
      selectedIds.clear();
      setTimeout(() => {
        notificationListener?.({
          jsonrpc: '2.0',
          method: 'scan.progress',
          params: {
            scanId,
            stage: 'analyzingCacheFiles',
            scannedFileCount: 3,
            cleanableBytes: 6144,
            clients: [
              {
                id: 'codex',
                name: 'Codex',
                symbolName: 'cpu',
                accentToken: 'codex',
                kind: 'builtInClient',
                state: 'measured',
                cleanableBytes: 6144,
                itemCount: 2,
              },
            ],
          },
        });
        notificationListener?.({
          jsonrpc: '2.0',
          method: 'scan.completed',
          params: {
            scanId,
            status: 'completed',
            reportRevision: 1,
            summary: {
              scannedAt: '2026-11-26T12:00:00Z',
              totalBuiltInProfilesCount: 31,
              detectedBuiltInClientsCount: 1,
              skippedProtectedCount: 0,
              totalSizeBytes: 6144,
              recommendedSizeBytes: 2048,
              reviewSuggestedSizeBytes: 4096,
              protectedSizeBytes: 8192,
              totalDiskFootprintBytes: 14336,
              totalItemCount: 2,
              totalRecommendedCount: 1,
              totalReviewSuggestedCount: 1,
              totalProtectedItemCount: 1,
            },
          },
        });
      }, 0);
      return { scanId };
    }
    if (method === 'report.summary') {
      return {
        scannedAt: '2026-11-26T12:00:00Z',
        totalBuiltInProfilesCount: 31,
        detectedBuiltInClientsCount: 1,
        skippedProtectedCount: 0,
        totalSizeBytes: 6144,
        recommendedSizeBytes: 2048,
        reviewSuggestedSizeBytes: 4096,
        protectedSizeBytes: 8192,
        totalDiskFootprintBytes: 14336,
        totalItemCount: 2,
        totalRecommendedCount: 1,
        totalReviewSuggestedCount: 1,
        totalProtectedItemCount: 1,
      };
    }
    if (method === 'clients.list') {
      return {
        clients: [
          {
            id: 'codex',
            name: 'Codex',
            symbolName: 'cpu',
            accentToken: 'codex',
            kind: 'builtInClient',
            itemCount: visibleItems().length,
            totalSizeBytes: 6144,
            recommendedSizeBytes: 2048,
            reviewSuggestedSizeBytes: 4096,
            protectedSizeBytes: 8192,
          },
        ],
      };
    }
    if (method === 'items.query') {
      const current = visibleItems();
      const recs = current.filter((i) => i.recommendation === 'recommended');
      const revs = current.filter((i) => i.recommendation === 'reviewSuggested');
      const risks = current.filter((i) => i.recommendation === 'notRecommended');
      const groups = [
        { recommendation: 'recommended', itemCount: recs.length, totalBytes: recs.reduce((s, i) => s + i.sizeBytes, 0), allBulkSelected: recs.length > 0 && recs.every((i) => selectedIds.has(i.id)) },
        { recommendation: 'reviewSuggested', itemCount: revs.length, totalBytes: revs.reduce((s, i) => s + i.sizeBytes, 0), allBulkSelected: revs.length > 0 && revs.every((i) => selectedIds.has(i.id)) },
        { recommendation: 'notRecommended', itemCount: risks.length, totalBytes: risks.reduce((s, i) => s + i.sizeBytes, 0), allBulkSelected: false },
      ].filter((g) => g.itemCount > 0);
      return { reportRevision: 1, total: current.length, groups, items: current };
    }
    if (method === 'items.get') {
      const ids = (params.ids as string[]) ?? [];
      return { items: visibleItems().filter((i) => ids.includes(i.id)) };
    }
    if (method === 'selection.apply') {
      const op = params.op as string;
      if (op === 'clearAll') {
        selectedIds = new Set();
      } else if (op === 'selectRecommendedInScope') {
        selectedIds.add('item-rec-1');
      } else if (op === 'toggle') {
        for (const id of (params.itemIds as string[]) ?? []) {
          if (selectedIds.has(id)) selectedIds.delete(id);
          else selectedIds.add(id);
        }
      }
      return summaryOfSelection();
    }
    if (method === 'selection.confirmRisk') {
      selectedIds.add(params.itemId as string);
      return summaryOfSelection();
    }
    if (method === 'trash.preview') {
      const chosen = visibleItems().filter((i) => selectedIds.has(i.id));
      return {
        confirmationToken: 'TOK-123',
        totalBytes: chosen.reduce((s, i) => s + i.sizeBytes, 0),
        hasNotRecommended: chosen.some((i) => i.recommendation === 'notRecommended'),
        items: chosen,
      };
    }
    if (method === 'trash.execute') {
      const chosen = visibleItems().filter((i) => selectedIds.has(i.id));
      const freed = chosen.reduce((s, i) => s + i.sizeBytes, 0);
      selectedIds = new Set();
      const record: CleanupHistoryRecordDTO = {
        id: 'hist-1',
        timestamp: '2026-11-26T12:05:00Z',
        freedBytes: freed,
        trashedCount: chosen.length,
        clientBreakdown: [{ clientID: 'codex', clientName: 'Codex', freedBytes: freed, itemCount: chosen.length }],
        categoryBreakdown: [{ category: 'temporary', freedBytes: freed, itemCount: chosen.length }],
        sampleItemNames: chosen.map((c) => c.preferredTitle),
      };
      history = [record];
      return {
        result: {
          trashedItems: chosen.map((item) => ({ item, resultingTrashPath: '/Trash/x', trashedBytes: item.sizeBytes })),
          skippedProtectedItems: [],
          failedItems: [],
          trashedCount: chosen.length,
          freedBytes: freed,
          completedAt: record.timestamp,
        },
        reportRevision: 2,
        historyRecord: record,
      };
    }
    if (method === 'projects.list') {
      return {
        projects: [
          {
            projectId: 'workspace:/Users/test/ai-cleaner',
            name: 'ai-cleaner',
            workspacePath: '/Users/test/ai-cleaner',
            sessionCount: 1,
            sizeBytes: 4096,
            isProtected: projectProtected,
          },
        ],
      };
    }
    if (method === 'projects.sessions') {
      const sess = visibleItems().filter((i) => i.id === 'item-sess-1');
      return { reportRevision: 1, total: sess.length, groups: [], items: sess };
    }
    if (method === 'projects.setProtection') {
      projectProtected = Boolean(params.enabled);
      return { isProtected: projectProtected };
    }
    if (method === 'customDirs.validate') {
      const p = String(params.path ?? '');
      if (p === '/') return { allowed: false, reason: '不允许添加系统根目录' };
      return { allowed: true };
    }
    return {};
  });

  const transport: CoreTransport = {
    request: request as CoreTransport['request'],
    onNotification: (cb) => {
      notificationListener = cb;
      return () => {
        notificationListener = null;
      };
    },
    onMenuAction: (cb) => {
      menuListener = cb;
      return () => {
        menuListener = null;
      };
    },
    revealScanItem: vi.fn(async () => {}),
    revealExcludedItem: vi.fn(async () => {}),
    pickDirectory: vi.fn(async () => null),
    getHostPlatform: vi.fn(async () => platform),
  };

  return {
    transport,
    request,
    loseScan: () => { currentScanId = null; },
    scanNotFound,
    triggerMenu: (a: MenuActionId) => menuListener?.(a),
  };
}

describe('App integration with CoreClient', () => {
  it('shows reinstall banner when handshake returns PROTOCOL_VERSION_MISMATCH (-32000)', async () => {
    const { transport } = createMockTransport({ failHandshake: true });
    render(<App client={new CoreClient(transport)} />);

    const banner = await screen.findByTestId('error-banner');
    expect(banner).toHaveTextContent('安装不完整');
  });

  it('runs scan -> select recommended -> preview -> execute -> celebration -> history & appearance toggle', async () => {
    const { transport, request } = createMockTransport({ platform: 'windows' });
    render(<App client={new CoreClient(transport)} />);

    // Disk footer rendered
    await waitFor(() => {
      expect(screen.getByTestId('disk-usage-footer')).toHaveTextContent('500 GB');
    });

    // Click Start Scan
    fireEvent.click(screen.getByTestId('start-scan-button'));

    // Space overview appears after scan completes
    await screen.findByTestId('item-list-view');
    expect(screen.getByTestId('dashboard-title')).toHaveTextContent('空间总览');

    // Select recommended items via Hero button
    fireEvent.click(screen.getByTestId('select-recommended-btn'));
    const dock = await screen.findByTestId('selection-dock');
    expect(dock).toHaveTextContent('已选 1 项');
    expect(dock).toHaveTextContent('回收站');

    // Open trash confirmation modal and execute
    fireEvent.click(screen.getByTestId('open-trash-confirm-btn'));
    await screen.findByTestId('trash-confirm-modal');
    fireEvent.click(screen.getByTestId('confirm-trash-execute-btn'));

    // Celebration pill appears
    const resultPill = await screen.findByTestId('cleanup-result-pill');
    expect(resultPill).toHaveTextContent('已移入回收站');

    // Navigate to History and verify KPI updated
    fireEvent.click(screen.getByTestId('nav-history'));
    await screen.findByTestId('cleanup-history-view');
    expect(screen.getByTestId('history-kpi-total')).toHaveTextContent('2.05 KB');

    // Cycle appearance light -> system -> dark
    fireEvent.click(screen.getByTestId('toolbar-appearance'));
    await waitFor(() => {
      expect(request).toHaveBeenCalledWith('settings.set', { appearanceMode: 'system' });
    });

    // Open Add Custom Directory modal and verify live SafetyGuard rejection for "/"
    fireEvent.click(screen.getByTestId('toolbar-add-custom'));
    const pathInput = await screen.findByTestId('custom-dir-path-input');
    fireEvent.change(pathInput, { target: { value: '/' } });
    const errBox = await screen.findByTestId('custom-dir-validation-error');
    expect(errBox).toHaveTextContent('不允许添加系统根目录');
    expect(screen.getByTestId('submit-custom-dir-btn')).toBeDisabled();
  });

  it('clears expired results and selection and lets the user run a new scan', async () => {
    const { transport, request, loseScan } = createMockTransport();
    render(<App client={new CoreClient(transport)} />);

    fireEvent.click(screen.getByTestId('start-scan-button'));
    fireEvent.click(await screen.findByTestId('select-recommended-btn'));
    await screen.findByTestId('selection-dock');
    await screen.findByTestId('nav-client-codex');

    let finishSelection!: () => void;
    request.mockImplementationOnce(() => new Promise((resolve) => {
      finishSelection = () => resolve({
        selectionRevision: 3,
        selectedCount: 1,
        selectedBytes: 2048,
        hasNotRecommended: false,
      });
    }));
    fireEvent.click(screen.getByTestId('select-recommended-btn'));
    await waitFor(() => expect(finishSelection).toBeDefined());

    loseScan();
    fireEvent.click(screen.getByTestId('cat-filter-temporary'));
    expect(await screen.findByTestId('error-banner')).toHaveTextContent('请重新扫描');
    expect(screen.getByTestId('scan-ready-hero')).toBeVisible();
    expect(screen.queryByTestId('nav-client-codex')).not.toBeInTheDocument();
    await act(async () => finishSelection());
    expect(screen.queryByTestId('selection-dock')).not.toBeInTheDocument();
    expect(request.mock.calls.filter(([method]) => method === 'scan.start')).toHaveLength(1);

    fireEvent.click(screen.getByTestId('start-scan-button'));
    await screen.findByTestId('nav-client-codex');
    expect(screen.queryByTestId('error-banner')).not.toBeInTheDocument();
  });

  it('ignores a missing-scan reply for the previous scan after a new one completes', async () => {
    const { transport, request, scanNotFound } = createMockTransport();
    render(<App client={new CoreClient(transport)} />);

    fireEvent.click(screen.getByTestId('start-scan-button'));
    await screen.findByTestId('nav-client-codex');

    let rejectOldSelection!: (error: CoreRpcError) => void;
    request.mockImplementationOnce(() => new Promise((_, reject) => { rejectOldSelection = reject; }));
    fireEvent.click(screen.getByTestId('select-recommended-btn'));
    await waitFor(() => expect(rejectOldSelection).toBeDefined());
    fireEvent.click(screen.getByTestId('toolbar-scan'));
    await waitFor(() => expect(request).toHaveBeenCalledWith('clients.list', { scanId: 'scan-2' }));
    await screen.findByTestId('nav-client-codex');

    await act(async () => rejectOldSelection(scanNotFound));
    expect(screen.getByTestId('nav-client-codex')).toBeVisible();
    expect(screen.queryByTestId('error-banner')).not.toBeInTheDocument();
  });

  it('navigates into client project sessions and toggles project protection', async () => {
    const { transport } = createMockTransport({ platform: 'macos' });
    render(<App client={new CoreClient(transport)} />);

    await act(async () => {
      fireEvent.keyDown(window, { key: 'r', metaKey: true });
    });

    await screen.findByTestId('nav-client-codex');
    fireEvent.click(screen.getByTestId('nav-client-codex'));
    fireEvent.click(await screen.findByTestId('open-project-sessions-btn'));

    await screen.findByTestId('project-sessions-view');
    fireEvent.click(await screen.findByTestId('toggle-project-protection-btn'));

    await screen.findByTestId('project-protected-banner');
  });
});
