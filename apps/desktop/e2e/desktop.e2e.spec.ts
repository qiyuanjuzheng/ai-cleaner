import { expect, test } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startE2EBridge } from './sidecar-bridge.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const desktopRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(desktopRoot, '../..');
const distDir = path.join(desktopRoot, 'dist');

test.describe('AI Cleaner Desktop E2E (Real Swift aicleaner-core sidecar)', () => {
  test('complete lifecycle: scan, filter, full title, exclude/restore, project protection, custom dir, real recycle, history & theme', async ({
    page,
  }) => {
    const bridge = await startE2EBridge({ repoRoot, distDir });
    try {
      const appUrl = `${bridge.baseUrl}/?bridge=${encodeURIComponent(bridge.baseUrl)}`;
      await page.goto(appUrl);

      // 1. Landing hero + real startup disk capacity footer
      await expect(page.getByTestId('scan-ready-hero')).toBeVisible();
      await expect(page.getByTestId('disk-usage-footer')).toContainText('总容量');

      // 2. Start real scan via Hero CTA
      await page.getByTestId('start-scan-button').click();
      await expect(page.getByTestId('item-list-view')).toBeVisible();
      await expect(page.getByTestId('dashboard-title')).toHaveText('空间总览');
      await expect(page.getByTestId('nav-client-codex')).toBeVisible();

      // 3. Search & Full Session Title inspection via real `items.get`
      const searchInput = page.getByTestId('items-search-input');
      await searchInput.fill('Cross-platform Tauri 2');
      await expect(page.getByTestId('scan-item-row')).toHaveCount(1);
      await page.getByTestId('item-full-title-btn').first().click();
      await expect(page.getByTestId('full-title-modal')).toBeVisible();
      await expect(page.getByTestId('full-title-content')).toContainText(bridge.fixtureInfo.longTitle);
      await page.getByRole('button', { name: '完成' }).click();
      await expect(page.getByTestId('full-title-modal')).toBeHidden();

      // 4. Reveal path through Core-verified `items.resolvePath`
      await page.getByTestId('item-reveal-btn').first().click();
      await expect.poll(() => bridge.revealedPaths.length).toBeGreaterThan(0);

      // Reset search filter
      await page.getByTestId('reset-filters-btn').click();

      // 5. Project Sessions & Project Protection
      await page.getByTestId('nav-client-codex').click();
      await page.getByTestId('open-project-sessions-btn').click();
      await expect(page.getByTestId('project-sessions-view')).toBeVisible();
      await expect(page.getByTestId(`project-row-${bridge.fixtureInfo.projectName}`)).toBeVisible();

      await page.getByTestId('toggle-project-protection-btn').click();
      await expect(page.getByTestId('project-protected-banner')).toBeVisible();
      // Unlock again to verify round-trip persistence
      await page.getByTestId('toggle-project-protection-btn').click();
      await expect(page.getByTestId('project-protected-banner')).toBeHidden();

      await page.getByTestId('back-to-cleanup-items-btn').click();
      await expect(page.getByTestId('item-list-view')).toBeVisible();

      // 6. Exclude one log file & verify Excluded Items view + Restore
      await searchInput.fill('e2e-exclude-me.log');
      await expect(page.getByTestId('scan-item-row')).toHaveCount(1);
      await expect(page.getByTestId('scan-item-row').first()).toContainText('e2e-exclude-me.log');
      await page.getByTestId('item-more-btn').first().click();
      await page.getByTestId('ctx-exclude-item').click();
      await expect(page.getByTestId('empty-items-state')).toBeVisible();

      await page.getByTestId('nav-excluded').click();
      await expect(page.getByTestId('excluded-items-view')).toBeVisible();
      await expect(page.getByTestId('excluded-row')).toHaveCount(1);
      await page.getByTestId('restore-excluded-btn').first().click();
      await expect(page.getByTestId('excluded-empty-state')).toBeVisible();

      // 7. Custom directory live SafetyGuard validation (reject system root, accept safe dir)
      await page.getByTestId('toolbar-add-custom').click();
      const customPathInput = page.getByTestId('custom-dir-path-input');
      await customPathInput.fill(bridge.fixtureInfo.blockedRootDir);
      await expect(page.getByTestId('custom-dir-validation-error')).toBeVisible();
      await expect(page.getByTestId('submit-custom-dir-btn')).toBeDisabled();

      await customPathInput.fill(bridge.fixtureInfo.safeCustomDir);
      await expect(page.getByTestId('submit-custom-dir-btn')).toBeEnabled();
      await page.getByTestId('submit-custom-dir-btn').click();
      await expect(page.getByTestId('add-custom-dir-modal')).toBeHidden();
      // Triggers scan automatically and returns to overview with new custom dir scanned
      await expect(page.getByTestId('item-list-view')).toBeVisible();

      // 8. Select one recommended file -> Preview -> Execute real native recycle
      await page.getByTestId('nav-all-clients').click();
      await searchInput.fill('e2e-stale-cache.log');
      await expect(page.getByTestId('scan-item-row')).toHaveCount(1);
      await expect(page.getByTestId('scan-item-row').first()).toContainText('e2e-stale-cache.log');
      await page.getByTestId('item-checkbox').first().click();

      await expect(page.getByTestId('selection-dock')).toBeVisible();
      await page.getByTestId('open-trash-confirm-btn').click();
      await expect(page.getByTestId('trash-confirm-modal')).toBeVisible();
      await page.getByTestId('confirm-trash-execute-btn').click();

      // Celebration pill appears and original file is gone from sandbox
      await expect(page.getByTestId('cleanup-result-pill')).toBeVisible();
      expect(fs.existsSync(bridge.fixtureInfo.staleTmpPath)).toBe(false);

      // 9. Cleanup History view reflects the real recycled run
      await page.getByTestId('nav-history').click();
      await expect(page.getByTestId('cleanup-history-view')).toBeVisible();
      await expect(page.getByTestId('history-trend-chart')).toBeVisible();
      await expect(page.getByTestId('history-client-ranking')).toContainText('Codex');
      await page.getByTestId('history-metric-daily').click();
      await page.getByTestId('history-range-allTime').click();

      // 10. Appearance cycle persists through real sidecar settings.set
      await page.getByTestId('toolbar-appearance').click();
      await page.getByTestId('toolbar-appearance').click();
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');

      // 11. Keyboard shortcut (Cmd+R on macOS / Ctrl+R on Windows & Linux) starts rescan
      const shortcut = process.platform === 'darwin' ? 'Meta+r' : 'Control+r';
      await page.keyboard.press(shortcut);
      await expect(page.getByTestId('item-list-view')).toBeVisible();
      await expect(page.getByTestId('toolbar-scan')).toBeEnabled();
    } finally {
      await bridge.close();
    }
  });

  test('the AI client sidebar scrolls when its navigation exceeds the window', async ({ page }) => {
    const bridge = await startE2EBridge({ repoRoot, distDir });
    try {
      const { sandboxHome } = bridge.fixtureInfo;
      const createdAt = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
      const directories = Array.from({ length: 40 }, (_, index) => {
        const displayName = `Sidebar fixture ${String(index + 1).padStart(2, '0')}`;
        const directory = path.join(sandboxHome, displayName);
        fs.mkdirSync(directory);
        return { id: randomUUID(), displayName, path: directory, category: 'cache', mode: 'children', createdAt };
      });
      const dataDir = path.join(sandboxHome, '.aicleaner-data');
      fs.mkdirSync(dataDir, { recursive: true });
      fs.writeFileSync(path.join(dataDir, 'custom-directories.json'), JSON.stringify(directories));

      await page.setViewportSize({ width: 1180, height: 660 });
      await page.goto(`${bridge.baseUrl}/?bridge=${encodeURIComponent(bridge.baseUrl)}`);
      const sidebar = page.locator('aside[aria-label="主导航侧栏"]');
      const lastDirectory = sidebar.getByText('Sidebar fixture 40', { exact: true });
      const footer = page.getByTestId('disk-usage-footer');
      await expect(lastDirectory).toBeAttached();
      await expect(lastDirectory).not.toBeInViewport();
      const footerTop = await footer.evaluate((element) => element.getBoundingClientRect().top);

      await sidebar.getByText('AI 客户端', { exact: true }).hover();
      await page.mouse.wheel(0, 1800);
      await expect(lastDirectory).toBeInViewport();
      await expect(footer).toBeInViewport({ ratio: 1 });
      expect(await footer.evaluate((element) => element.getBoundingClientRect().top)).toBe(footerTop);
    } finally {
      await bridge.close();
    }
  });

  test('cleanup history scrolls from the fixed page heading', async ({ page }) => {
    const bridge = await startE2EBridge({ repoRoot, distDir });
    try {
      const records = Array.from({ length: 6 }, (_, index) => ({
        id: randomUUID(),
        timestamp: new Date(Date.now() - index * 3_600_000).toISOString().replace(/\.\d+Z$/, 'Z'),
        freedBytes: 2048,
        trashedCount: 1,
        clientBreakdown: [],
        categoryBreakdown: [],
        sampleItemNames: [`history-scroll-${index}.log`],
      }));
      const dataDir = path.join(bridge.fixtureInfo.sandboxHome, '.aicleaner-data');
      fs.mkdirSync(dataDir, { recursive: true });
      fs.writeFileSync(path.join(dataDir, 'cleanup-history.json'), JSON.stringify(records));

      await page.setViewportSize({ width: 1180, height: 660 });
      await page.goto(`${bridge.baseUrl}/?bridge=${encodeURIComponent(bridge.baseUrl)}`);
      await page.getByTestId('nav-history').click();
      const heading = page.getByRole('heading', { name: '清理记录', exact: true });
      const lastRecord = page.getByTestId('history-recent-list').getByText('history-scroll-4.log');
      await expect(lastRecord).toBeAttached();
      await expect(lastRecord).not.toBeInViewport();
      const top = await heading.evaluate((element) => element.getBoundingClientRect().top);

      await heading.hover();
      await page.mouse.wheel(0, 600);
      await expect(lastRecord).toBeInViewport();
      await expect(heading).toBeInViewport();
      expect(await heading.evaluate((element) => element.getBoundingClientRect().top)).toBe(top);
    } finally {
      await bridge.close();
    }
  });

  test('virtual scrolling stays smooth with 5,200+ real scanned items', async ({ page }) => {
    test.setTimeout(90_000);
    const bridge = await startE2EBridge({ repoRoot, distDir, stressFileCount: 5200 });
    try {
      const appUrl = `${bridge.baseUrl}/?bridge=${encodeURIComponent(bridge.baseUrl)}`;
      await page.goto(appUrl);

      await page.getByTestId('start-scan-button').click();
      await expect(page.getByTestId('item-list-view')).toBeVisible({ timeout: 60_000 });
      await expect(page.getByTestId('section-header-recommended')).toContainText('5202 项');

      // DOM virtualization check: 5,200+ items exist, but DOM renders only a tiny window (< 80 rows)
      const initialRenderedRows = await page.getByTestId('scan-item-row').count();
      expect(initialRenderedRows).toBeGreaterThan(5);
      expect(initialRenderedRows).toBeLessThan(80);

      const viewport = page.getByTestId('virtual-item-list');
      const heading = page.getByTestId('dashboard-title');
      for (const [navigation, title] of [['nav-all-clients', '空间总览'], ['nav-client-codex', 'Codex']]) {
        await page.getByTestId(navigation).click();
        await expect(heading).toHaveText(title);
        const top = await heading.evaluate((element) => element.getBoundingClientRect().top);
        await heading.hover();
        await page.mouse.wheel(0, 480);
        await expect.poll(() => viewport.evaluate((element) => element.scrollTop)).toBeGreaterThan(0);
        expect(await heading.evaluate((element) => element.getBoundingClientRect().top)).toBe(top);
      }

      // Scroll far down (to ~item #2,600) and verify lazy 200-item paging renders real rows cleanly
      await viewport.evaluate((el) => {
        el.scrollTop = el.scrollHeight * 0.5;
      });
      await expect
        .poll(async () => {
          const indices = await page
            .getByTestId('scan-item-row')
            .evaluateAll((els) => els.map((el) => Number(el.getAttribute('data-row-index') ?? -1)));
          return indices.length > 5 && indices.some((idx) => idx >= 2000);
        })
        .toBe(true);

      const midRenderedRows = await page.getByTestId('scan-item-row').count();
      expect(midRenderedRows).toBeGreaterThan(5);
      expect(midRenderedRows).toBeLessThan(80);
    } finally {
      await bridge.close();
    }
  });
});
