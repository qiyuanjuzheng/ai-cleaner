import type { MenuActionId, PlatformKind } from '../rpc/types';

export function formatShortcut(platform: PlatformKind, key: string, opts?: { shift?: boolean; alt?: boolean }): string {
  const isMac = platform === 'macos';
  if (isMac) {
    return `${opts?.alt ? '⌥' : ''}${opts?.shift ? '⇧' : ''}⌘${key.toUpperCase()}`;
  }
  const parts = ['Ctrl'];
  if (opts?.shift) parts.push('Shift');
  if (opts?.alt) parts.push('Alt');
  parts.push(key.toUpperCase());
  return parts.join('+');
}

export function matchShortcutEvent(event: KeyboardEvent, platform: PlatformKind): MenuActionId | null {
  const primary = platform === 'macos' ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey;
  if (!primary) return null;

  const target = event.target as HTMLElement | null;
  const isTyping =
    target !== null &&
    (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable);

  const key = event.key.toLowerCase();

  if (key === 'r' && !event.shiftKey && !event.altKey) {
    return 'scan.start';
  }
  if (key === 'a' && event.shiftKey && !event.altKey) {
    return 'customDirs.openAdd';
  }
  if (key === 'a' && event.altKey && !event.shiftKey && !isTyping) {
    return 'selection.selectAll';
  }
  if (key === '2' && !event.shiftKey && !event.altKey) {
    return 'nav.history';
  }
  if (key === '3' && !event.shiftKey && !event.altKey) {
    return 'nav.excluded';
  }
  return null;
}
