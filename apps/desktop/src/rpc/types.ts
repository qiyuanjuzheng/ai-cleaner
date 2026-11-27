export type PlatformKind = 'macos' | 'windows' | 'linux';
export type AppearanceMode = 'light' | 'dark' | 'system';

export type ScanCategory =
  | 'sessions'
  | 'cache'
  | 'temporary'
  | 'logs'
  | 'custom'
  | 'protectedData';

export type CleanupRecommendation =
  | 'recommended'
  | 'reviewSuggested'
  | 'notRecommended';

export type ClientKind =
  | 'builtInClient'
  | 'otherAITemp'
  | 'unattributedTemp'
  | 'customDirectory';

export type ScanTargetMode = 'directory' | 'children' | 'projectSessions' | 'recursiveFiles';

export type ItemAgeFilter = 'all' | 'olderThan7Days' | 'olderThan30Days' | 'olderThan90Days';

export type ItemSortOrder = 'sizeDesc' | 'sizeAsc' | 'modifiedDesc' | 'modifiedAsc' | 'nameAsc';

export type ScanStage = 'scanningClients' | 'analyzingCacheFiles' | 'tallyingCleanableSpace';

export type ScanClientDetectionState = 'detecting' | 'measured';

export type SelectionOp =
  | 'toggle'
  | 'selectRecommendedInScope'
  | 'selectSection'
  | 'deselectSection'
  | 'toggleSection'
  | 'selectAllVisible'
  | 'invertVisible'
  | 'clearVisible'
  | 'clearAll';

export type ScopeDTO =
  | { kind: 'all' }
  | { kind: 'client'; clientId: string }
  | { kind: 'clientProjects'; clientId: string; projectId: string };

export interface FilterDTO {
  search?: string | null;
  category?: ScanCategory | null;
  recommendation?: CleanupRecommendation | null;
  age?: ItemAgeFilter | null;
}

export interface RpcErrorData {
  name: string;
  reason?: string;
  itemId?: string;
  path?: string;
}

export interface RpcErrorPayload {
  code: number;
  message: string;
  data?: RpcErrorData;
}

export interface HandshakeResult {
  protocolVersion: string;
  coreVersion: string;
  platform: PlatformKind;
  capabilities: string[];
}

export interface ScanProgressClientDTO {
  id: string;
  name: string;
  symbolName: string;
  accentToken: string;
  kind: ClientKind;
  state: ScanClientDetectionState;
  cleanableBytes: number;
  itemCount: number;
}

export interface ScanProgressNotification {
  scanId: string;
  stage: ScanStage;
  scannedFileCount: number;
  cleanableBytes: number;
  clients: ScanProgressClientDTO[];
}

export interface ReportSummaryDTO {
  scannedAt: string;
  totalBuiltInProfilesCount: number;
  detectedBuiltInClientsCount: number;
  skippedProtectedCount: number;
  totalSizeBytes: number;
  recommendedSizeBytes: number;
  reviewSuggestedSizeBytes: number;
  protectedSizeBytes: number;
  totalDiskFootprintBytes: number;
  totalItemCount: number;
  totalRecommendedCount: number;
  totalReviewSuggestedCount: number;
  totalProtectedItemCount: number;
}

export interface ScanCompletedNotification {
  scanId: string;
  status: 'completed' | 'cancelled' | 'failed';
  reportRevision: number;
  summary: ReportSummaryDTO | null;
  error?: RpcErrorPayload;
}

export type CoreNotification =
  | { jsonrpc: '2.0'; method: 'scan.progress'; params: ScanProgressNotification }
  | { jsonrpc: '2.0'; method: 'scan.completed'; params: ScanCompletedNotification };

export interface ClientSummaryDTO {
  id: string;
  name: string;
  symbolName: string;
  accentToken: string;
  kind: ClientKind;
  itemCount: number;
  totalSizeBytes: number;
  recommendedSizeBytes: number;
  reviewSuggestedSizeBytes: number;
  protectedSizeBytes: number;
}

export interface CleanableItemDTO {
  id: string;
  clientId: string;
  clientName: string;
  ruleId: string;
  displayName: string;
  preferredTitle: string;
  sessionTitle?: string;
  sessionProjectName?: string;
  fileName: string;
  path: string;
  category: ScanCategory;
  recommendation: CleanupRecommendation;
  safetyNote: string;
  hardProtectionReason?: string;
  requiresIndividualSelection: boolean;
  bulkSelectable: boolean;
  selected: boolean;
  sourceBadge?: string;
  isRecentlyModified: boolean;
  isSessionArtifact: boolean;
  isDirectory: boolean;
  isCustom: boolean;
  sizeBytes: number;
  fileCount: number;
  modifiedAt: string;
  artifacts?: CleanableItemDTO[];
}

export interface ItemGroupDTO {
  recommendation: CleanupRecommendation;
  itemCount: number;
  totalBytes: number;
  allBulkSelected: boolean;
}

export interface ItemsQueryResponse {
  reportRevision: number;
  total: number;
  groups: ItemGroupDTO[];
  items: CleanableItemDTO[];
}

export interface SelectionSummaryDTO {
  selectionRevision: number;
  selectedCount: number;
  selectedBytes: number;
  hasNotRecommended: boolean;
}

export interface TrashPreviewResponse {
  confirmationToken: string;
  totalBytes: number;
  hasNotRecommended: boolean;
  items: CleanableItemDTO[];
}

export interface TrashedItemRecordDTO {
  item: CleanableItemDTO;
  resultingTrashPath: string | null;
  trashedBytes: number;
}

export interface CleanupFailureDTO {
  item: CleanableItemDTO;
  reason: string;
}

export interface CleanupResultDTO {
  trashedItems: TrashedItemRecordDTO[];
  skippedProtectedItems: CleanupFailureDTO[];
  failedItems: CleanupFailureDTO[];
  trashedCount: number;
  freedBytes: number;
  completedAt: string;
}

export interface ClientCleanupDeltaDTO {
  clientID: string;
  clientName: string;
  freedBytes: number;
  itemCount: number;
}

export interface CategoryCleanupDeltaDTO {
  category: ScanCategory;
  freedBytes: number;
  itemCount: number;
}

export interface CleanupHistoryRecordDTO {
  id: string;
  timestamp: string;
  freedBytes: number;
  trashedCount: number;
  clientBreakdown: ClientCleanupDeltaDTO[];
  categoryBreakdown: CategoryCleanupDeltaDTO[];
  sampleItemNames: string[];
}

export interface TrashExecuteResponse {
  result: CleanupResultDTO;
  reportRevision: number;
  historyRecord?: CleanupHistoryRecordDTO;
  historyError?: RpcErrorPayload;
}

export interface ExcludedItemRecordDTO {
  id: string;
  normalizedPath: string;
  displayName: string;
  clientID: string;
  clientName: string;
  category: ScanCategory;
  isDirectory: boolean;
  excludedAt: string;
  sessionProjectName?: string;
}

export interface ExcludedListResponse {
  records: ExcludedItemRecordDTO[];
  statuses: Record<string, boolean>;
}

export interface CustomScanDirectoryDTO {
  id: string;
  displayName: string;
  path: string;
  category: ScanCategory;
  mode: ScanTargetMode;
  createdAt: string;
}

export interface CustomDirValidateResponse {
  allowed: boolean;
  reason?: string;
}

export interface ProjectSummaryDTO {
  projectId: string;
  name: string;
  sessionCount: number;
  sizeBytes: number;
  isProtected: boolean;
  workspacePath?: string;
}

export interface DiskCapacityDTO {
  total: number | null;
  available: number | null;
}

export interface SettingsDTO {
  appearanceMode: AppearanceMode;
}

export type SidebarSelection =
  | { kind: 'allClients' }
  | { kind: 'history' }
  | { kind: 'excluded' }
  | { kind: 'client'; clientId: string }
  | { kind: 'clientProjects'; clientId: string };

export type MenuActionId =
  | 'scan.start'
  | 'scan.return'
  | 'customDirs.openAdd'
  | 'nav.history'
  | 'nav.excluded'
  | 'selection.recommended'
  | 'selection.selectAll'
  | 'selection.invert'
  | 'selection.clear'
  | 'appearance.cycle';

export const PROTOCOL_VERSION = '1.0';
export const CLIENT_VERSION = '2.0.0';
export const OTHER_AI_TEMP_CLIENT_ID = 'other-ai-temp';
export const UNATTRIBUTED_TEMP_CLIENT_ID = 'system-tmp-unattributed';
