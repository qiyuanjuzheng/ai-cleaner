import { describe, expect, it } from 'vitest';
import { abbreviatePath, formatBytes, revealActionTitle, trashName } from './format';
import { formatShortcut, matchShortcutEvent } from './shortcuts';

describe('platform formatting & shortcuts', () => {
  it('formats bytes cleanly across B/KB/MB/GB', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(512)).toBe('512 B');
    expect(formatBytes(1_500)).toBe('1.5 KB');
    expect(formatBytes(25_600_000)).toBe('25.6 MB');
    expect(formatBytes(1_500_000_000)).toBe('1.5 GB');
  });

  it('uses platform-appropriate trash and reveal terminology', () => {
    expect(trashName('macos')).toBe('废纸篓');
    expect(trashName('windows')).toBe('回收站');
    expect(trashName('linux')).toBe('回收站');

    expect(revealActionTitle('macos')).toBe('在 Finder 中显示');
    expect(revealActionTitle('windows')).toBe('在文件资源管理器中显示');
    expect(revealActionTitle('linux')).toBe('在文件管理器中显示');
  });

  it('abbreviates home paths on macOS, Linux, and Windows', () => {
    expect(abbreviatePath('/Users/alice/.codex/tmp', 'macos')).toBe('~/.codex/tmp');
    expect(abbreviatePath('/home/alice/.cache/opencode', 'linux')).toBe('~/.cache/opencode');
    expect(abbreviatePath('C:\\Users\\alice\\AppData\\Local\\opencode', 'windows')).toBe('~\\AppData\\Local\\opencode');
  });

  it('matches Cmd+R on macOS and Ctrl+R on Windows/Linux', () => {
    expect(formatShortcut('macos', 'r')).toBe('⌘R');
    expect(formatShortcut('windows', 'r')).toBe('Ctrl+R');
    expect(formatShortcut('linux', 'a', { shift: true })).toBe('Ctrl+Shift+A');

    const macEvent = new KeyboardEvent('keydown', { key: 'r', metaKey: true });
    expect(matchShortcutEvent(macEvent, 'macos')).toBe('scan.start');
    expect(matchShortcutEvent(macEvent, 'windows')).toBeNull();

    const winEvent = new KeyboardEvent('keydown', { key: 'r', ctrlKey: true });
    expect(matchShortcutEvent(winEvent, 'windows')).toBe('scan.start');
    expect(matchShortcutEvent(winEvent, 'linux')).toBe('scan.start');
    expect(matchShortcutEvent(winEvent, 'macos')).toBeNull();
  });
});
