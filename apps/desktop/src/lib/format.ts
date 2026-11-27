import type {
  AppearanceMode,
  CleanupRecommendation,
  ItemAgeFilter,
  ItemSortOrder,
  PlatformKind,
  ScanCategory,
  ScanStage,
} from '../rpc/types';

/**
 * Formats byte counts cleanly using decimal units (matching macOS Finder / ByteCountFormatter(.file)).
 */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return '0 B';
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1000 && unitIndex < units.length - 1) {
    value /= 1000;
    unitIndex += 1;
  }
  if (unitIndex === 0) {
    return `${Math.round(value)} B`;
  }
  const decimals = value >= 100 ? 0 : value >= 10 ? 1 : 2;
  const formatted = Number(value.toFixed(decimals)).toString();
  return `${formatted} ${units[unitIndex]}`;
}

export function formatDateTime(iso: string | Date | null | undefined): string {
  if (!iso) return '—';
  const date = typeof iso === 'string' ? new Date(iso) : iso;
  if (Number.isNaN(date.getTime())) return '—';
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(date);
}

export function formatTimeShort(iso: string | Date | null | undefined): string {
  if (!iso) return '';
  const date = typeof iso === 'string' ? new Date(iso) : iso;
  if (Number.isNaN(date.getTime())) return '';
  return new Intl.DateTimeFormat('zh-CN', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).format(date);
}

export function formatShortMonthDay(date: Date): string {
  return new Intl.DateTimeFormat('zh-CN', {
    month: 'numeric',
    day: 'numeric',
  }).format(date);
}

export function formatFullDate(date: Date): string {
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  }).format(date);
}

export function abbreviatePath(rawPath: string, platform: PlatformKind): string {
  if (!rawPath) return '';
  if (platform === 'windows') {
    const winMatch = rawPath.match(/^[A-Za-z]:\\Users\\[^\\]+(\\.*)?$/i);
    if (winMatch) {
      return `~${winMatch[1] ?? ''}`;
    }
    return rawPath;
  }
  const posixMatch = rawPath.match(/^\/(?:Users|home)\/[^/]+(\/.*)?$/);
  if (posixMatch) {
    return `~${posixMatch[1] ?? ''}`;
  }
  return rawPath;
}

export function trashName(platform: PlatformKind): string {
  return platform === 'macos' ? '废纸篓' : '回收站';
}

export function trashRestoreHint(platform: PlatformKind): string {
  if (platform === 'macos') {
    return '如需恢复，请在废纸篓中选择「放回原处」。';
  }
  return '如需恢复，可在系统回收站中还原对应文件。';
}

export function revealActionTitle(platform: PlatformKind): string {
  switch (platform) {
    case 'macos':
      return '在 Finder 中显示';
    case 'windows':
      return '在文件资源管理器中显示';
    case 'linux':
      return '在文件管理器中显示';
  }
}

export function diskLabel(platform: PlatformKind): string {
  if (platform === 'windows') return '系统磁盘';
  if (platform === 'linux') return '系统磁盘';
  return '启动磁盘';
}

export function recommendationDisplayName(rec: CleanupRecommendation): string {
  switch (rec) {
    case 'recommended':
      return '建议清理';
    case 'reviewSuggested':
      return '按需清理';
    case 'notRecommended':
      return '不建议清理';
  }
}

export function categoryDisplayName(category: ScanCategory): string {
  switch (category) {
    case 'sessions':
      return '会话记录';
    case 'cache':
      return '缓存';
    case 'temporary':
      return '临时文件';
    case 'logs':
      return '日志';
    case 'custom':
      return '自定义目录';
    case 'protectedData':
      return '受保护数据';
  }
}

export function categoryShortTitle(category: ScanCategory): string {
  switch (category) {
    case 'sessions':
      return '会话';
    case 'cache':
      return '缓存';
    case 'temporary':
      return '临时';
    case 'logs':
      return '日志';
    case 'custom':
      return '自定义';
    case 'protectedData':
      return '受保护';
  }
}

export function stageDisplayName(stage: ScanStage): string {
  switch (stage) {
    case 'scanningClients':
      return '扫描客户端';
    case 'analyzingCacheFiles':
      return '分析缓存文件';
    case 'tallyingCleanableSpace':
      return '统计可释放空间';
  }
}

export function ageFilterDisplayName(age: ItemAgeFilter): string {
  switch (age) {
    case 'all':
      return '全部时间';
    case 'olderThan7Days':
      return '7 天前';
    case 'olderThan30Days':
      return '30 天前';
    case 'olderThan90Days':
      return '90 天前';
  }
}

export function sortOrderDisplayName(sort: ItemSortOrder): string {
  switch (sort) {
    case 'sizeDesc':
      return '体积从大到小';
    case 'sizeAsc':
      return '体积从小到大';
    case 'modifiedDesc':
      return '修改时间从新到旧';
    case 'modifiedAsc':
      return '修改时间从旧到新';
    case 'nameAsc':
      return '名称 A–Z';
  }
}

export function appearanceDisplayName(mode: AppearanceMode): string {
  switch (mode) {
    case 'light':
      return '浅色';
    case 'dark':
      return '深色';
    case 'system':
      return '跟随系统';
  }
}

export function nextAppearanceMode(mode: AppearanceMode): AppearanceMode {
  switch (mode) {
    case 'light':
      return 'system';
    case 'system':
      return 'dark';
    case 'dark':
      return 'light';
  }
}

export function extractCustomDirectoryId(clientId: string): string | null {
  if (!clientId.startsWith('custom-')) return null;
  return clientId.slice('custom-'.length) || null;
}
