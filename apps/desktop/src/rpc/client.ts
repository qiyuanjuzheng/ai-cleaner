import type {
  AppearanceMode,
  CleanableItemDTO,
  ClientSummaryDTO,
  CleanupHistoryRecordDTO,
  CoreNotification,
  CustomDirValidateResponse,
  CustomScanDirectoryDTO,
  DiskCapacityDTO,
  ExcludedItemRecordDTO,
  ExcludedListResponse,
  FilterDTO,
  HandshakeResult,
  ItemSortOrder,
  ItemsQueryResponse,
  MenuActionId,
  PlatformKind,
  ProjectSummaryDTO,
  ReportSummaryDTO,
  RpcErrorPayload,
  ScanCategory,
  ScanTargetMode,
  ScopeDTO,
  SelectionOp,
  SelectionSummaryDTO,
  SettingsDTO,
  TrashExecuteResponse,
  TrashPreviewResponse,
} from './types';
import { CLIENT_VERSION, PROTOCOL_VERSION } from './types';

export class CoreRpcError extends Error {
  readonly code: number;
  readonly errorName?: string;
  readonly reason?: string;

  constructor(payload: RpcErrorPayload) {
    super(payload.data?.reason || payload.message);
    this.name = 'CoreRpcError';
    this.code = payload.code;
    this.errorName = payload.data?.name;
    this.reason = payload.data?.reason;
  }
}

export interface CoreTransport {
  request<T>(method: string, params?: Record<string, unknown>): Promise<T>;
  onNotification(listener: (notification: CoreNotification) => void): () => void;
  onMenuAction(listener: (action: MenuActionId) => void): () => void;
  revealScanItem(scanId: string, itemId: string): Promise<void>;
  revealExcludedItem(recordId: string): Promise<void>;
  pickDirectory(): Promise<string | null>;
  getHostPlatform(): Promise<PlatformKind>;
}

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown;
    __AI_CLEANER_TRANSPORT__?: CoreTransport;
    __AI_CLEANER_BRIDGE_URL__?: string;
  }
}

function normalizeRpcError(err: unknown): CoreRpcError {
  if (err instanceof CoreRpcError) {
    return err;
  }
  if (typeof err === 'object' && err !== null && 'code' in err && 'message' in err) {
    return new CoreRpcError(err as RpcErrorPayload);
  }
  return new CoreRpcError({
    code: -32603,
    message: typeof err === 'string' ? err : err instanceof Error ? err.message : '未知核心错误',
  });
}

function isTauriRuntime(): boolean {
  return typeof window !== 'undefined' && typeof window.__TAURI_INTERNALS__ !== 'undefined';
}

function detectBrowserPlatform(): PlatformKind {
  if (typeof navigator === 'undefined') return 'macos';
  const ua = `${navigator.platform ?? ''} ${navigator.userAgent ?? ''}`.toLowerCase();
  if (ua.includes('win')) return 'windows';
  if (ua.includes('linux')) return 'linux';
  return 'macos';
}

class TauriCoreTransport implements CoreTransport {
  async request<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const { invoke } = await import('@tauri-apps/api/core');
    try {
      return await invoke<T>('core_request', { method, params });
    } catch (err) {
      throw normalizeRpcError(err);
    }
  }

  onNotification(listener: (notification: CoreNotification) => void): () => void {
    let unlisten: (() => void) | null = null;
    let disposed = false;
    void import('@tauri-apps/api/event').then(async ({ listen }) => {
      const fn = await listen<CoreNotification>('core://notification', (event) => {
        listener(event.payload);
      });
      if (disposed) {
        fn();
      } else {
        unlisten = fn;
      }
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }

  onMenuAction(listener: (action: MenuActionId) => void): () => void {
    let unlisten: (() => void) | null = null;
    let disposed = false;
    void import('@tauri-apps/api/event').then(async ({ listen }) => {
      const fn = await listen<{ action: MenuActionId }>('menu://action', (event) => {
        if (event.payload?.action) {
          listener(event.payload.action);
        }
      });
      if (disposed) {
        fn();
      } else {
        unlisten = fn;
      }
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }

  async revealScanItem(scanId: string, itemId: string): Promise<void> {
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('reveal_scan_item', { scanId, itemId });
  }

  async revealExcludedItem(recordId: string): Promise<void> {
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('reveal_excluded_item', { recordId });
  }

  async pickDirectory(): Promise<string | null> {
    const { open } = await import('@tauri-apps/plugin-dialog');
    const selected = await open({
      directory: true,
      multiple: false,
      title: '选择要扫描的文件夹',
    });
    return typeof selected === 'string' ? selected : null;
  }

  async getHostPlatform(): Promise<PlatformKind> {
    const { invoke } = await import('@tauri-apps/api/core');
    return invoke<PlatformKind>('host_platform');
  }
}

class HttpBridgeTransport implements CoreTransport {
  private readonly baseUrl: string;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl.replace(/\/$/, '');
  }

  async request<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const res = await fetch(`${this.baseUrl}/rpc`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ method, params }),
    });
    const payload = (await res.json()) as { result?: T; error?: RpcErrorPayload };
    if (payload.error) {
      throw new CoreRpcError(payload.error);
    }
    return payload.result as T;
  }

  onNotification(listener: (notification: CoreNotification) => void): () => void {
    const source = new EventSource(`${this.baseUrl}/events`);
    source.onmessage = (event) => {
      try {
        const parsed = JSON.parse(event.data) as CoreNotification;
        listener(parsed);
      } catch {
        // ignore malformed bridge event
      }
    };
    return () => source.close();
  }

  onMenuAction(_listener: (action: MenuActionId) => void): () => void {
    return () => {};
  }

  async revealScanItem(scanId: string, itemId: string): Promise<void> {
    await fetch(`${this.baseUrl}/reveal-scan`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ scanId, itemId }),
    });
  }

  async revealExcludedItem(recordId: string): Promise<void> {
    await fetch(`${this.baseUrl}/reveal-excluded`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ recordId }),
    });
  }

  async pickDirectory(): Promise<string | null> {
    return null;
  }

  async getHostPlatform(): Promise<PlatformKind> {
    try {
      const res = await fetch(`${this.baseUrl}/platform`);
      const data = (await res.json()) as { platform?: PlatformKind };
      return data.platform ?? detectBrowserPlatform();
    } catch {
      return detectBrowserPlatform();
    }
  }
}

export function createDefaultTransport(): CoreTransport {
  if (typeof window !== 'undefined') {
    if (window.__AI_CLEANER_TRANSPORT__) {
      return window.__AI_CLEANER_TRANSPORT__;
    }
    if (isTauriRuntime()) {
      return new TauriCoreTransport();
    }
    const bridgeUrl =
      window.__AI_CLEANER_BRIDGE_URL__ ||
      (import.meta.env?.VITE_BRIDGE_URL as string | undefined) ||
      new URLSearchParams(window.location.search).get('bridge');
    if (bridgeUrl) {
      return new HttpBridgeTransport(bridgeUrl);
    }
  }
  return new TauriCoreTransport();
}

export class CoreClient {
  readonly transport: CoreTransport;

  constructor(transport: CoreTransport = createDefaultTransport()) {
    this.transport = transport;
  }

  handshake(): Promise<HandshakeResult> {
    return this.transport.request<HandshakeResult>('core.handshake', {
      protocolVersion: PROTOCOL_VERSION,
      clientVersion: CLIENT_VERSION,
      locale: typeof navigator !== 'undefined' ? navigator.language || 'zh-Hans' : 'zh-Hans',
    });
  }

  ping(): Promise<Record<string, never>> {
    return this.transport.request('core.ping', {});
  }

  startScan(): Promise<{ scanId: string }> {
    return this.transport.request('scan.start', {});
  }

  cancelScan(scanId: string): Promise<Record<string, never>> {
    return this.transport.request('scan.cancel', { scanId });
  }

  getReportSummary(scanId: string): Promise<ReportSummaryDTO> {
    return this.transport.request('report.summary', { scanId });
  }

  listClients(scanId: string): Promise<{ clients: ClientSummaryDTO[] }> {
    return this.transport.request('clients.list', { scanId });
  }

  queryItems(params: {
    scanId: string;
    scope?: ScopeDTO | null;
    filter?: FilterDTO | null;
    sort?: ItemSortOrder | null;
    offset?: number;
    limit?: number;
  }): Promise<ItemsQueryResponse> {
    return this.transport.request('items.query', params);
  }

  getItems(scanId: string, ids: string[]): Promise<{ items: CleanableItemDTO[] }> {
    return this.transport.request('items.get', { scanId, ids });
  }

  applySelection(params: {
    scanId: string;
    op: SelectionOp;
    scope?: ScopeDTO | null;
    filter?: FilterDTO | null;
    itemIds?: string[];
    recommendation?: 'recommended' | 'reviewSuggested';
  }): Promise<SelectionSummaryDTO> {
    return this.transport.request('selection.apply', params);
  }

  confirmRisk(scanId: string, itemId: string): Promise<SelectionSummaryDTO> {
    return this.transport.request('selection.confirmRisk', { scanId, itemId });
  }

  previewTrash(scanId: string): Promise<TrashPreviewResponse> {
    return this.transport.request('trash.preview', { scanId });
  }

  executeTrash(params: {
    scanId: string;
    confirmationToken: string;
    acknowledgedNotRecommendedRisk: boolean;
  }): Promise<TrashExecuteResponse> {
    return this.transport.request('trash.execute', params);
  }

  listHistory(): Promise<{ records: CleanupHistoryRecordDTO[] }> {
    return this.transport.request('history.list', {});
  }

  deleteHistory(id: string): Promise<Record<string, never>> {
    return this.transport.request('history.delete', { id });
  }

  clearHistory(): Promise<Record<string, never>> {
    return this.transport.request('history.clear', {});
  }

  listExcluded(): Promise<ExcludedListResponse> {
    return this.transport.request('excluded.list', {});
  }

  addExcluded(scanId: string, itemId: string): Promise<{ record: ExcludedItemRecordDTO; reportRevision: number }> {
    return this.transport.request('excluded.add', { scanId, itemId });
  }

  restoreExcluded(id: string): Promise<Record<string, never>> {
    return this.transport.request('excluded.restore', { id });
  }

  restoreAllExcluded(): Promise<Record<string, never>> {
    return this.transport.request('excluded.restoreAll', {});
  }

  listCustomDirs(): Promise<{ directories: CustomScanDirectoryDTO[] }> {
    return this.transport.request('customDirs.list', {});
  }

  validateCustomDir(path: string): Promise<CustomDirValidateResponse> {
    return this.transport.request('customDirs.validate', { path });
  }

  addCustomDir(params: {
    path: string;
    displayName?: string;
    category: ScanCategory;
    mode: ScanTargetMode;
  }): Promise<{ directory: CustomScanDirectoryDTO }> {
    return this.transport.request('customDirs.add', params);
  }

  removeCustomDir(id: string): Promise<Record<string, never>> {
    return this.transport.request('customDirs.remove', { id });
  }

  listProjects(params: {
    scanId: string;
    clientId?: string;
    includeAllClients?: boolean;
  }): Promise<{ projects: ProjectSummaryDTO[] }> {
    return this.transport.request('projects.list', params);
  }

  queryProjectSessions(params: {
    scanId: string;
    projectId: string;
    clientId?: string | null;
    filter?: FilterDTO | null;
    sort?: ItemSortOrder | null;
    offset?: number;
    limit?: number;
  }): Promise<ItemsQueryResponse> {
    return this.transport.request('projects.sessions', params);
  }

  setProjectProtection(projectId: string, enabled: boolean): Promise<{ isProtected: boolean }> {
    return this.transport.request('projects.setProtection', { projectId, enabled });
  }

  getDiskCapacity(): Promise<DiskCapacityDTO> {
    return this.transport.request('disk.capacity', {});
  }

  getSettings(): Promise<SettingsDTO> {
    return this.transport.request('settings.get', {});
  }

  setSettings(appearanceMode: AppearanceMode): Promise<SettingsDTO> {
    return this.transport.request('settings.set', { appearanceMode });
  }
}
