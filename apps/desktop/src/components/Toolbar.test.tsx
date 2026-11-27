import { fireEvent, render, screen } from '@testing-library/react';
import { expect, it, vi } from 'vitest';
import { Toolbar } from './Toolbar';

it('checks for updates from the toolbar and prevents duplicate or conflicting actions', () => {
  const onCheckUpdates = vi.fn();
  const props = {
    appearanceMode: 'light' as const,
    onCycleAppearance: vi.fn(),
    onOpenAddCustom: vi.fn(),
    onStartScan: vi.fn(),
    onCheckUpdates,
    hasScanResults: false,
    isScanning: false,
    isCleaning: false,
    isUpdating: false,
    platform: 'linux' as const,
  };
  const { rerender } = render(<Toolbar {...props} />);
  fireEvent.click(screen.getByRole('button', { name: '检查更新' }));
  expect(onCheckUpdates).toHaveBeenCalledOnce();

  rerender(<Toolbar {...props} isUpdating />);
  expect(screen.getByRole('button', { name: '检查更新' })).toBeDisabled();
  expect(screen.getByRole('button', { name: '开始扫描' })).toBeDisabled();

  rerender(<Toolbar {...props} isCleaning />);
  expect(screen.getByRole('button', { name: '检查更新' })).toBeDisabled();
});
