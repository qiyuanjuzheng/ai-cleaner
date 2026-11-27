import type { CleanupRecommendation, ScanCategory } from '../rpc/types';

export const EXCLUDED_ACCENT_COLOR = '#8f80f5';

export const RECOMMENDATION_COLORS: Record<CleanupRecommendation, string> = {
  recommended: '#29d18a',
  reviewSuggested: '#faa838',
  notRecommended: '#e06b7a',
};

export const CATEGORY_COLORS: Record<ScanCategory, string> = {
  sessions: '#8580fa',
  cache: '#42adff',
  temporary: '#faa33d',
  logs: '#bd80f5',
  custom: '#2ec7bd',
  protectedData: '#d67080',
};

const ACCENT_TOKEN_COLORS: Record<string, string> = {
  claude: '#f08a57',
  claudeDesktop: '#f08a57',
  cursor: '#4da3ff',
  codex: '#24d199',
  chatgpt: '#24d199',
  workbuddy: '#3d9eff',
  doubao: '#618fff',
  workdaddy: '#947afa',
  deepseek: '#5c8afa',
  trae: '#24d1a3',
  qoder: '#fa8f3d',
  lingma: '#8075ff',
  kiro: '#a870fa',
  zcode: '#4da8ff',
  windsurf: '#29d1e0',
  opencode: '#7a85fa',
  pi: '#eb70ad',
  gemini: '#5c9eff',
  multica: '#7585ff',
  copilot: '#99a8c7',
  cherry: '#f05c80',
  anythingllm: '#33bddb',
  t3: '#faad42',
  stepfun: '#3dbdff',
  kimi: '#57a8ff',
  yuanbao: '#24d1a8',
  ollama: '#c2c7d6',
  lmstudio: '#9975fa',
  chatbox: '#42adfa',
  jan: '#f56b99',
  zed: '#57bdfa',
  tempAI: '#f59e3d',
  tempUnattributed: '#e68f33',
  custom: '#29cc9e',
};

export function accentColorForToken(token: string): string {
  return ACCENT_TOKEN_COLORS[token] ?? '#29cc9e';
}

export function clientAccentById(clientId: string): string {
  if (clientId.startsWith('custom-')) return ACCENT_TOKEN_COLORS.custom;
  if (clientId === 'other-ai-temp') return ACCENT_TOKEN_COLORS.tempAI;
  if (clientId === 'system-tmp-unattributed') return ACCENT_TOKEN_COLORS.tempUnattributed;
  const map: Record<string, string> = {
    'claude-code': 'claude',
    'claude-desktop': 'claudeDesktop',
    'chatgpt-desktop': 'chatgpt',
    'gemini-antigravity': 'gemini',
    'cherry-studio': 'cherry',
    't3-code': 't3',
    'lm-studio': 'lmstudio',
  };
  return accentColorForToken(map[clientId] ?? clientId);
}

type LogoSpec = { kind: 'single'; name: string } | { kind: 'themed'; name: string };

const CLIENT_LOGOS: Record<string, LogoSpec> = {
  'claude-code': { kind: 'single', name: 'claude-code' },
  codex: { kind: 'single', name: 'codex' },
  workbuddy: { kind: 'single', name: 'workbuddy' },
  doubao: { kind: 'single', name: 'doubao' },
  cursor: { kind: 'themed', name: 'cursor' },
  deepseek: { kind: 'single', name: 'deepseek' },
  trae: { kind: 'single', name: 'trae' },
  qoder: { kind: 'single', name: 'qoder' },
  lingma: { kind: 'single', name: 'lingma' },
  kiro: { kind: 'single', name: 'kiro' },
  zcode: { kind: 'single', name: 'zcode' },
  windsurf: { kind: 'themed', name: 'windsurf' },
  'claude-desktop': { kind: 'single', name: 'claude-desktop' },
  'chatgpt-desktop': { kind: 'themed', name: 'chatgpt-desktop' },
  opencode: { kind: 'themed', name: 'opencode' },
  pi: { kind: 'themed', name: 'pi' },
  'gemini-antigravity': { kind: 'single', name: 'gemini-antigravity' },
  multica: { kind: 'themed', name: 'multica' },
  copilot: { kind: 'themed', name: 'copilot' },
  'cherry-studio': { kind: 'single', name: 'cherry-studio' },
  anythingllm: { kind: 'single', name: 'anythingllm' },
  't3-code': { kind: 'single', name: 't3-code' },
  stepfun: { kind: 'single', name: 'stepfun' },
  kimi: { kind: 'themed', name: 'kimi' },
  yuanbao: { kind: 'single', name: 'yuanbao' },
  ollama: { kind: 'themed', name: 'ollama' },
  'lm-studio': { kind: 'single', name: 'lm-studio' },
  chatbox: { kind: 'single', name: 'chatbox' },
  jan: { kind: 'single', name: 'jan' },
  zed: { kind: 'themed', name: 'zed' },
};

export function resolveClientLogoSrc(clientId: string, effectiveTheme: 'light' | 'dark'): string | null {
  const spec = CLIENT_LOGOS[clientId];
  if (!spec) return null;
  const filename = spec.kind === 'themed' ? `${spec.name}-${effectiveTheme}` : spec.name;
  return `/client-logos/${filename}.png`;
}
