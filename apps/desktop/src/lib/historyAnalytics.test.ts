import { describe, expect, it } from 'vitest';
import { paginateRecentRecords, summarizeCleanupHistory } from './historyAnalytics';
import type { CleanupHistoryRecordDTO } from '../rpc/types';

function makeRecord(overrides: Partial<CleanupHistoryRecordDTO> & { id: string; timestamp: string; freedBytes: number }): CleanupHistoryRecordDTO {
  return {
    trashedCount: 2,
    clientBreakdown: [
      {
        clientID: 'codex',
        clientName: 'Codex',
        freedBytes: overrides.freedBytes,
        itemCount: 2,
      },
    ],
    categoryBreakdown: [{ category: 'cache', freedBytes: overrides.freedBytes, itemCount: 2 }],
    sampleItemNames: ['cache.bin'],
    ...overrides,
  };
}

describe('summarizeCleanupHistory', () => {
  const refDate = new Date(2026, 10, 26, 15, 0, 0); // 2026-11-26 local

  it('handles empty records cleanly', () => {
    const summary = summarizeCleanupHistory([], 'days30', refDate);
    expect(summary.isEmpty).toBe(true);
    expect(summary.totalFreedBytes).toBe(0);
    expect(summary.usesWeeklyBuckets).toBe(false);
    expect(summary.points).toHaveLength(30);
    expect(summary.topClients).toHaveLength(0);
  });

  it('carries over baseline cumulative bytes prior to the active window', () => {
    const records: CleanupHistoryRecordDTO[] = [
      makeRecord({ id: 'old', timestamp: new Date(2026, 9, 1, 10, 0).toISOString(), freedBytes: 10_000 }),
      makeRecord({ id: 'recent', timestamp: new Date(2026, 10, 25, 10, 0).toISOString(), freedBytes: 5_000 }),
    ];

    const summary = summarizeCleanupHistory(records, 'days7', refDate);
    expect(summary.usesWeeklyBuckets).toBe(false);
    expect(summary.points).toHaveLength(7);
    expect(summary.totalFreedBytes).toBe(15_000);
    expect(summary.rangeFreedBytes).toBe(5_000);
    expect(summary.points[0].cumulativeFreedBytes).toBe(10_000);
    expect(summary.points[summary.points.length - 1].cumulativeFreedBytes).toBe(15_000);
  });

  it('switches automatically to weekly buckets when allTime span exceeds 180 days', () => {
    const records: CleanupHistoryRecordDTO[] = [
      makeRecord({ id: 'r1', timestamp: new Date(2026, 0, 10, 12, 0).toISOString(), freedBytes: 4_000 }),
      makeRecord({ id: 'r2', timestamp: new Date(2026, 5, 15, 12, 0).toISOString(), freedBytes: 6_000 }),
      makeRecord({ id: 'r3', timestamp: new Date(2026, 10, 26, 12, 0).toISOString(), freedBytes: 2_000 }),
    ];

    const summary = summarizeCleanupHistory(records, 'allTime', refDate);
    expect(summary.usesWeeklyBuckets).toBe(true);
    expect(summary.points.length).toBeLessThan(60);
    expect(summary.points.length).toBeGreaterThan(40);
    expect(summary.points[summary.points.length - 1].cumulativeFreedBytes).toBe(12_000);

    const sumOfWeekly = summary.points.reduce((acc, p) => acc + p.dailyFreedBytes, 0);
    expect(sumOfWeekly).toBe(12_000);
  });

  it('keeps daily buckets when allTime span is <= 180 days', () => {
    const records: CleanupHistoryRecordDTO[] = [
      makeRecord({ id: 'r1', timestamp: new Date(2026, 8, 1, 12, 0).toISOString(), freedBytes: 1_000 }),
      makeRecord({ id: 'r2', timestamp: new Date(2026, 10, 26, 12, 0).toISOString(), freedBytes: 3_000 }),
    ];

    const summary = summarizeCleanupHistory(records, 'allTime', refDate);
    expect(summary.usesWeeklyBuckets).toBe(false);
    expect(summary.points[summary.points.length - 1].cumulativeFreedBytes).toBe(4_000);
  });

  it('computes client ranking shares and falls back to all-time ranking when range has no runs', () => {
    const records: CleanupHistoryRecordDTO[] = [
      makeRecord({
        id: 'old-multi',
        timestamp: new Date(2026, 8, 1, 12, 0).toISOString(),
        freedBytes: 1_000,
        clientBreakdown: [
          { clientID: 'cursor', clientName: 'Cursor', freedBytes: 750, itemCount: 3 },
          { clientID: 'codex', clientName: 'Codex', freedBytes: 250, itemCount: 1 },
        ],
      }),
    ];

    const summary = summarizeCleanupHistory(records, 'days7', refDate);
    expect(summary.rangeRuns).toBe(0);
    expect(summary.topClients).toHaveLength(2);
    expect(summary.topClients[0].clientId).toBe('cursor');
    expect(summary.topClients[0].share).toBeCloseTo(0.75);
    expect(summary.topClients[1].share).toBeCloseTo(0.25);
  });

  it('paginates recent records 5 per page and clamps out-of-range page numbers', () => {
    const records = Array.from({ length: 12 }, (_, idx) =>
      makeRecord({
        id: `rec-${idx}`,
        timestamp: new Date(2026, 10, 1 + idx).toISOString(),
        freedBytes: 100 * (idx + 1),
      })
    );
    const p1 = paginateRecentRecords(records, 1);
    expect(p1.page).toBe(1);
    expect(p1.totalPages).toBe(3);
    expect(p1.slice).toHaveLength(5);

    const pLast = paginateRecentRecords(records, 99);
    expect(pLast.page).toBe(3);
    expect(pLast.slice).toHaveLength(2);
  });
});
