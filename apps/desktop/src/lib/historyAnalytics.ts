import type { CleanupHistoryRecordDTO } from '../rpc/types';

export type CleanupTrendRange = 'days7' | 'days30' | 'days90' | 'allTime';
export type CleanupTrendMetricMode = 'cumulative' | 'daily';

export const TREND_RANGE_OPTIONS: Array<{ id: CleanupTrendRange; label: string; daySpan: number | null }> = [
  { id: 'days7', label: '近 7 天', daySpan: 7 },
  { id: 'days30', label: '近 30 天', daySpan: 30 },
  { id: 'days90', label: '近 90 天', daySpan: 90 },
  { id: 'allTime', label: '全部', daySpan: null },
];

export interface CleanupTrendPoint {
  date: Date;
  key: string;
  dailyFreedBytes: number;
  cumulativeFreedBytes: number;
  cleanupRuns: number;
  trashedCount: number;
}

export interface ClientRankingEntry {
  clientId: string;
  clientName: string;
  totalFreedBytes: number;
  itemCount: number;
  share: number;
}

export interface CleanupHistorySummary {
  range: CleanupTrendRange;
  isEmpty: boolean;
  totalFreedBytes: number;
  totalRuns: number;
  totalTrashedItems: number;
  largestSingleRunBytes: number;
  averagePerRunBytes: number;
  rangeFreedBytes: number;
  rangeRuns: number;
  rangeTrashedItems: number;
  usesWeeklyBuckets: boolean;
  points: CleanupTrendPoint[];
  topClients: ClientRankingEntry[];
  recentRecords: CleanupHistoryRecordDTO[];
}

export function startOfLocalDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0, 0);
}

export function addLocalDays(date: Date, days: number): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days, 0, 0, 0, 0);
}

function dayKey(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function diffDays(start: Date, end: Date): number {
  const utcStart = Date.UTC(start.getFullYear(), start.getMonth(), start.getDate());
  const utcEnd = Date.UTC(end.getFullYear(), end.getMonth(), end.getDate());
  return Math.max(0, Math.round((utcEnd - utcStart) / 86_400_000));
}

/**
 * Pure TypeScript port of `CleanupHistoryAnalytics.summarize` (CleanupHistoryRecord.swift).
 * Automatically switches to weekly buckets when `range === 'allTime'` and the span exceeds 180 days.
 */
export function summarizeCleanupHistory(
  records: CleanupHistoryRecordDTO[],
  range: CleanupTrendRange,
  referenceDate: Date = new Date()
): CleanupHistorySummary {
  const sortedAsc = [...records].sort(
    (a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime()
  );

  const totalFreedBytes = sortedAsc.reduce((sum, r) => sum + Math.max(0, r.freedBytes), 0);
  const totalRuns = sortedAsc.length;
  const totalTrashedItems = sortedAsc.reduce((sum, r) => sum + Math.max(0, r.trashedCount), 0);
  const largestSingleRunBytes = sortedAsc.reduce((max, r) => Math.max(max, Math.max(0, r.freedBytes)), 0);
  const averagePerRunBytes = totalRuns > 0 ? Math.floor(totalFreedBytes / totalRuns) : 0;

  const todayStart = startOfLocalDay(referenceDate);
  const rangeDef = TREND_RANGE_OPTIONS.find((opt) => opt.id === range);
  const daySpan = rangeDef?.daySpan ?? null;

  let windowStart: Date;
  if (daySpan !== null) {
    windowStart = addLocalDays(todayStart, -(daySpan - 1));
  } else if (sortedAsc.length > 0) {
    const earliestDay = startOfLocalDay(new Date(sortedAsc[0].timestamp));
    const minSpanStart = addLocalDays(todayStart, -6);
    windowStart = earliestDay.getTime() < minSpanStart.getTime() ? earliestDay : minSpanStart;
  } else {
    windowStart = addLocalDays(todayStart, -6);
  }

  let baselineCumulative = 0;
  const inRangeRecords: CleanupHistoryRecordDTO[] = [];
  for (const record of sortedAsc) {
    const recordDay = startOfLocalDay(new Date(record.timestamp));
    if (recordDay.getTime() < windowStart.getTime()) {
      baselineCumulative += Math.max(0, record.freedBytes);
    } else {
      inRangeRecords.push(record);
    }
  }

  const rangeFreedBytes = inRangeRecords.reduce((sum, r) => sum + Math.max(0, r.freedBytes), 0);
  const rangeRuns = inRangeRecords.length;
  const rangeTrashedItems = inRangeRecords.reduce((sum, r) => sum + Math.max(0, r.trashedCount), 0);

  const dailyBuckets = new Map<string, { date: Date; bytes: number; runs: number; items: number }>();
  for (const record of inRangeRecords) {
    const rawDay = startOfLocalDay(new Date(record.timestamp));
    const clampedDay = rawDay.getTime() > todayStart.getTime() ? todayStart : rawDay;
    const key = dayKey(clampedDay);
    const prev = dailyBuckets.get(key) ?? { date: clampedDay, bytes: 0, runs: 0, items: 0 };
    prev.bytes += Math.max(0, record.freedBytes);
    prev.runs += 1;
    prev.items += Math.max(0, record.trashedCount);
    dailyBuckets.set(key, prev);
  }

  const spanDays = diffDays(windowStart, todayStart);
  const usesWeeklyBuckets = range === 'allTime' && spanDays > 180;
  const points: CleanupTrendPoint[] = [];
  let runningCumulative = baselineCumulative;

  if (usesWeeklyBuckets) {
    let cursor = windowStart;
    while (cursor.getTime() <= todayStart.getTime()) {
      const nextCursor = addLocalDays(cursor, 7);
      let bucketBytes = 0;
      let bucketRuns = 0;
      let bucketItems = 0;
      for (const entry of dailyBuckets.values()) {
        const t = entry.date.getTime();
        if (t >= cursor.getTime() && t < nextCursor.getTime()) {
          bucketBytes += entry.bytes;
          bucketRuns += entry.runs;
          bucketItems += entry.items;
        }
      }
      runningCumulative += bucketBytes;
      points.push({
        date: cursor,
        key: dayKey(cursor),
        dailyFreedBytes: bucketBytes,
        cumulativeFreedBytes: runningCumulative,
        cleanupRuns: bucketRuns,
        trashedCount: bucketItems,
      });
      cursor = nextCursor;
    }
  } else {
    for (let offset = 0; offset <= spanDays; offset += 1) {
      const day = addLocalDays(windowStart, offset);
      const key = dayKey(day);
      const entry = dailyBuckets.get(key);
      const bytes = entry?.bytes ?? 0;
      runningCumulative += bytes;
      points.push({
        date: day,
        key,
        dailyFreedBytes: bytes,
        cumulativeFreedBytes: runningCumulative,
        cleanupRuns: entry?.runs ?? 0,
        trashedCount: entry?.items ?? 0,
      });
    }
  }

  const rankingSource = inRangeRecords.length > 0 ? inRangeRecords : sortedAsc;
  const clientTotals = new Map<string, { name: string; bytes: number; items: number }>();
  for (const record of rankingSource) {
    for (const delta of record.clientBreakdown) {
      const prev = clientTotals.get(delta.clientID) ?? {
        name: delta.clientName,
        bytes: 0,
        items: 0,
      };
      prev.bytes += Math.max(0, delta.freedBytes);
      prev.items += Math.max(0, delta.itemCount);
      clientTotals.set(delta.clientID, prev);
    }
  }

  const rankingDenominator = Array.from(clientTotals.values()).reduce((sum, entry) => sum + entry.bytes, 0);
  const topClients: ClientRankingEntry[] = Array.from(clientTotals.entries())
    .map(([clientId, entry]) => ({
      clientId,
      clientName: entry.name,
      totalFreedBytes: entry.bytes,
      itemCount: entry.items,
      share: rankingDenominator > 0 ? entry.bytes / rankingDenominator : 0,
    }))
    .sort((a, b) => b.totalFreedBytes - a.totalFreedBytes || a.clientName.localeCompare(b.clientName));

  return {
    range,
    isEmpty: sortedAsc.length === 0,
    totalFreedBytes,
    totalRuns,
    totalTrashedItems,
    largestSingleRunBytes,
    averagePerRunBytes,
    rangeFreedBytes,
    rangeRuns,
    rangeTrashedItems,
    usesWeeklyBuckets,
    points,
    topClients,
    recentRecords: [...inRangeRecords].reverse(),
  };
}

export function paginateRecentRecords(
  records: CleanupHistoryRecordDTO[],
  requestedPage: number,
  pageSize = 5
): { page: number; totalPages: number; slice: CleanupHistoryRecordDTO[] } {
  const totalPages = Math.max(1, Math.ceil(records.length / pageSize));
  const page = Math.min(Math.max(1, requestedPage), totalPages);
  const start = (page - 1) * pageSize;
  return {
    page,
    totalPages,
    slice: records.slice(start, start + pageSize),
  };
}
