import type { CleanupRecommendation, ItemGroupDTO } from '../rpc/types';

export const ITEMS_PAGE_SIZE = 200;

export type VirtualRowDescriptor =
  | {
      kind: 'sectionHeader';
      key: string;
      recommendation: CleanupRecommendation;
      itemCount: number;
      totalBytes: number;
      allBulkSelected: boolean;
    }
  | {
      kind: 'item';
      key: string;
      globalItemIndex: number;
      recommendation: CleanupRecommendation;
      isFirstInSection: boolean;
      isLastInSection: boolean;
    };

/**
 * Builds the complete flat row model (section headers + indexed item placeholders)
 * from `items.query`'s `groups[]`. Supports 5,000+ rows in O(N) with zero DOM bloat,
 * while individual item payloads are fetched lazily per 200-item page.
 */
export function buildVirtualRows(groups: ItemGroupDTO[]): VirtualRowDescriptor[] {
  const rows: VirtualRowDescriptor[] = [];
  let itemIndex = 0;

  for (const group of groups) {
    if (group.itemCount <= 0) continue;
    rows.push({
      kind: 'sectionHeader',
      key: `section-${group.recommendation}`,
      recommendation: group.recommendation,
      itemCount: group.itemCount,
      totalBytes: group.totalBytes,
      allBulkSelected: group.allBulkSelected,
    });

    for (let i = 0; i < group.itemCount; i += 1) {
      rows.push({
        kind: 'item',
        key: `item-${itemIndex}`,
        globalItemIndex: itemIndex,
        recommendation: group.recommendation,
        isFirstInSection: i === 0,
        isLastInSection: i === group.itemCount - 1,
      });
      itemIndex += 1;
    }
  }

  return rows;
}

/**
 * Computes which 200-item pages should be fetched for the currently visible virtual rows,
 * including a 1-page lookahead/lookbehind margin for smooth scrolling at 5,000+ items.
 */
export function computeNeededPages(
  rows: VirtualRowDescriptor[],
  visibleStartRow: number,
  visibleEndRow: number,
  loadedPages: ReadonlySet<number>,
  inFlightPages: ReadonlySet<number>,
  pageSize = ITEMS_PAGE_SIZE
): number[] {
  if (rows.length === 0) return [];
  const start = Math.max(0, visibleStartRow);
  const end = Math.min(rows.length - 1, visibleEndRow);

  let minItem = Number.POSITIVE_INFINITY;
  let maxItem = -1;
  for (let i = start; i <= end; i += 1) {
    const row = rows[i];
    if (row.kind === 'item') {
      if (row.globalItemIndex < minItem) minItem = row.globalItemIndex;
      if (row.globalItemIndex > maxItem) maxItem = row.globalItemIndex;
    }
  }

  if (maxItem < 0) return [];

  const totalItems = rows.reduce((count, row) => (row.kind === 'item' ? count + 1 : count), 0);
  const maxPage = Math.max(0, Math.floor((totalItems - 1) / pageSize));
  const firstPage = Math.max(0, Math.floor(minItem / pageSize));
  const lastPage = Math.min(maxPage, Math.floor(maxItem / pageSize) + 1);

  const needed: number[] = [];
  for (let page = firstPage; page <= lastPage; page += 1) {
    if (!loadedPages.has(page) && !inFlightPages.has(page)) {
      needed.push(page);
    }
  }
  return needed;
}
