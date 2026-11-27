import { Contrast, Download, FolderPlus, Loader2, Moon, Play, RefreshCw, Sun } from 'lucide-react';
import { appearanceDisplayName } from '../lib/format';
import { formatShortcut } from '../lib/shortcuts';
import type { AppearanceMode, PlatformKind } from '../rpc/types';

interface ToolbarProps {
  appearanceMode: AppearanceMode;
  onCycleAppearance: () => void;
  onOpenAddCustom: () => void;
  onStartScan: () => void;
  onCheckUpdates?: () => void;
  hasScanResults: boolean;
  isScanning: boolean;
  isCleaning: boolean;
  isUpdating: boolean;
  platform: PlatformKind;
}

export function Toolbar({
  appearanceMode,
  onCycleAppearance,
  onOpenAddCustom,
  onStartScan,
  onCheckUpdates,
  hasScanResults,
  isScanning,
  isCleaning,
  isUpdating,
  platform,
}: ToolbarProps) {
  const AppearanceIcon =
    appearanceMode === 'light' ? Sun : appearanceMode === 'dark' ? Moon : Contrast;

  return (
    <header className="top-toolbar" data-tauri-drag-region>
      {onCheckUpdates && (
        <button
          type="button"
          className="toolbar-btn"
          onClick={onCheckUpdates}
          disabled={isScanning || isCleaning || isUpdating}
          aria-label="检查更新"
          aria-busy={isUpdating}
        >
          {isUpdating ? <Loader2 size={14} className="spin-icon" /> : <Download size={14} />}
          <span>{isUpdating ? '更新处理中' : '检查更新'}</span>
        </button>
      )}
      <button
        type="button"
        className="toolbar-btn"
        onClick={onCycleAppearance}
        title={`切换外观（当前：${appearanceDisplayName(appearanceMode)}）`}
        data-testid="toolbar-appearance"
      >
        <AppearanceIcon size={14} />
        <span>{appearanceDisplayName(appearanceMode)}</span>
      </button>

      <button
        type="button"
        className="toolbar-btn"
        onClick={onOpenAddCustom}
        title={`添加自定义目录 (${formatShortcut(platform, 'A', { shift: true })})`}
        data-testid="toolbar-add-custom"
      >
        <FolderPlus size={14} />
        <span>添加目录</span>
      </button>

      <button
        type="button"
        className="toolbar-btn icon-only"
        onClick={onStartScan}
        disabled={isScanning || isCleaning || isUpdating}
        aria-label={hasScanResults ? '重新扫描' : '开始扫描'}
        title={`${hasScanResults ? '重新扫描' : '开始扫描'} (${formatShortcut(platform, 'R')})`}
        data-testid="toolbar-scan"
      >
        {isScanning ? (
          <Loader2 size={14} className="spin-icon" />
        ) : hasScanResults ? (
          <RefreshCw size={14} />
        ) : (
          <Play size={14} />
        )}
      </button>
    </header>
  );
}
