import { describe, expect, it } from 'vitest';
import { buildVirtualRows, computeNeededPages, ITEMS_PAGE_SIZE } from './virtualRows';
import type { ItemGroupDTO } from '../rpc/types';

describe('virtualRows for 5,000+ items', () => {
  const largeGroups: ItemGroupDTO[] = [
    { recommendation: 'recommended', itemCount: 3_200, totalBytes: 320_000_000, allBulkSelected: false },
    { recommendation: 'reviewSuggested', itemCount: 2_100, totalBytes: 210_000_000, allBulkSelected: false },
    { recommendation: 'notRecommended', itemCount: 200, totalBytes: 40_000_000, allBulkSelected: false },
  ];

  it('builds flat row descriptors for 5,500 items with section headers and boundary flags', () => {
    const rows = buildVirtualRows(largeGroups);
    expect(rows).toHaveLength(5_500 + 3);
    expect(rows[0]).toMatchObject({ kind: 'sectionHeader', recommendation: 'recommended', itemCount: 3_200 });
    expect(rows[1]).toMatchObject({ kind: 'item', globalItemIndex: 0, isFirstInSection: true, isLastInSection: false });
    expect(rows[3_200]).toMatchObject({ kind: 'item', globalItemIndex: 3_199, isFirstInSection: false, isLastInSection: true });
    expect(rows[3_201]).toMatchObject({ kind: 'sectionHeader', recommendation: 'reviewSuggested' });
    expect(rows[rows.length - 1]).toMatchObject({ kind: 'item', globalItemIndex: 5_499, isLastInSection: true });
  });

  it('computes visible and prefetch pages without duplicating loaded or in-flight pages', () => {
    const rows = buildVirtualRows(largeGroups);
    const loaded = new Set<number>([0]);
    const inFlight = new Set<number>([1]);

    // Visible around global index 0..30 => pages 0 and 1 already handled
    expect(computeNeededPages(rows, 0, 30, loaded, inFlight, ITEMS_PAGE_SIZE)).toEqual([]);

    // Scrolled to middle around item ~2500 (page 12, prefetch page 13)
    const middleNeeded = computeNeededPages(rows, 2_501, 2_530, loaded, inFlight, ITEMS_PAGE_SIZE);
    expect(middleNeeded).toEqual([12, 13]);

    // Near end of list (item 5499 => page 27, no page 28)
    const endNeeded = computeNeededPages(rows, rows.length - 20, rows.length - 1, loaded, inFlight, ITEMS_PAGE_SIZE);
    expect(endNeeded).toEqual([27]);
  });
});
