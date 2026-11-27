import { AlertTriangle, FolderOpen, FolderPlus, ShieldOff } from 'lucide-react';
import { useEffect, useState } from 'react';
import { categoryDisplayName } from '../lib/format';
import type { CustomDirValidateResponse, PlatformKind, ScanCategory, ScanTargetMode } from '../rpc/types';

interface AddCustomDirectoryModalProps {
  platform: PlatformKind;
  onClose: () => void;
  onPickDirectory: () => Promise<string | null>;
  onValidate: (path: string) => Promise<CustomDirValidateResponse>;
  onSubmit: (params: {
    path: string;
    displayName?: string;
    category: ScanCategory;
    mode: ScanTargetMode;
  }) => Promise<void>;
}

const USER_CATEGORIES: ScanCategory[] = ['custom', 'cache', 'temporary', 'logs', 'sessions'];

export function AddCustomDirectoryModal({
  platform,
  onClose,
  onPickDirectory,
  onValidate,
  onSubmit,
}: AddCustomDirectoryModalProps) {
  const [pathText, setPathText] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [category, setCategory] = useState<ScanCategory>('custom');
  const [mode, setMode] = useState<ScanTargetMode>('children');
  const [validation, setValidation] = useState<CustomDirValidateResponse | null>(null);
  const [validating, setValidating] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  useEffect(() => {
    const trimmed = pathText.trim();
    if (!trimmed) {
      setValidation(null);
      return;
    }
    let cancelled = false;
    setValidating(true);
    const timer = window.setTimeout(() => {
      void onValidate(trimmed)
        .then((res) => {
          if (!cancelled) {
            setValidation(res);
          }
        })
        .catch((err: unknown) => {
          if (!cancelled) {
            setValidation({
              allowed: false,
              reason: err instanceof Error ? err.message : '路径校验失败',
            });
          }
        })
        .finally(() => {
          if (!cancelled) setValidating(false);
        });
    }, 180);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [pathText, onValidate]);

  const handlePick = async () => {
    const picked = await onPickDirectory();
    if (!picked) return;
    setPathText(picked);
    if (!displayName.trim()) {
      const segments = picked.replace(/[\\/]+$/, '').split(/[\\/]/);
      const last = segments[segments.length - 1];
      if (last) setDisplayName(last);
    }
    setSubmitError(null);
  };

  const canSubmit = Boolean(pathText.trim()) && !validating && !submitting && validation?.allowed === true;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canSubmit) return;
    setSubmitting(true);
    setSubmitError(null);
    try {
      await onSubmit({
        path: pathText.trim(),
        displayName: displayName.trim() || undefined,
        category,
        mode,
      });
      onClose();
    } catch (err) {
      setSubmitError(err instanceof Error ? err.message : '添加失败');
    } finally {
      setSubmitting(false);
    }
  };

  const placeholder =
    platform === 'windows'
      ? '例如：C:\\Users\\you\\AppData\\Local\\my-ai-tool\\cache'
      : platform === 'linux'
        ? '例如：/home/you/.cache/my-ai-tool'
        : '例如：/Users/you/Library/Caches/my-ai-tool';

  return (
    <div className="modal-backdrop" onClick={onClose} data-testid="add-custom-dir-modal">
      <form className="modal-panel" style={{ maxWidth: 520 }} onClick={(e) => e.stopPropagation()} onSubmit={handleSubmit}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <div
            style={{
              width: 42,
              height: 42,
              borderRadius: 11,
              background: 'rgba(41, 209, 138, 0.16)',
              border: '1px solid rgba(41, 209, 138, 0.36)',
              color: '#29d18a',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              flexShrink: 0,
            }}
          >
            <FolderPlus size={19} />
          </div>
          <div>
            <h3 style={{ margin: '0 0 2px', fontSize: 17, fontWeight: 700 }}>添加自定义目录</h3>
            <div style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
              可添加缓存、导出文件或日志所在的文件夹，由 Core SafetyGuard 实时校验。
            </div>
          </div>
        </div>

        <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <span style={{ fontWeight: 600, fontSize: 12.5 }}>目录路径</span>
          <div style={{ display: 'flex', gap: 8 }}>
            <input
              type="text"
              value={pathText}
              onChange={(e) => {
                setPathText(e.target.value);
                setSubmitError(null);
              }}
              placeholder={placeholder}
              style={{
                flex: 1,
                height: 34,
                padding: '0 10px',
                borderRadius: 8,
                border: '1px solid var(--border-rim)',
                background: 'var(--card-bg)',
              }}
              data-testid="custom-dir-path-input"
            />
            <button type="button" className="btn-subtle-pill" style={{ height: 34 }} onClick={handlePick}>
              <FolderOpen size={13} />
              <span>选择文件夹…</span>
            </button>
          </div>
        </label>

        {validation && !validation.allowed && validation.reason && (
          <div
            style={{
              padding: '8px 10px',
              borderRadius: 8,
              background: 'rgba(224, 107, 122, 0.12)',
              color: 'var(--accent-risk)',
              display: 'flex',
              alignItems: 'flex-start',
              gap: 8,
              fontSize: 12,
            }}
            data-testid="custom-dir-validation-error"
          >
            <ShieldOff size={14} style={{ flexShrink: 0, marginTop: 1 }} />
            <span>{validation.reason}</span>
          </div>
        )}

        <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <span style={{ fontWeight: 600, fontSize: 12.5 }}>显示名称（可选）</span>
          <input
            type="text"
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
            placeholder="默认使用文件夹名称"
            style={{
              height: 34,
              padding: '0 10px',
              borderRadius: 8,
              border: '1px solid var(--border-rim)',
              background: 'var(--card-bg)',
            }}
            data-testid="custom-dir-name-input"
          />
        </label>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 12 }}>
          <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span style={{ fontWeight: 600, fontSize: 12.5 }}>类别</span>
            <select
              value={category}
              onChange={(e) => setCategory(e.target.value as ScanCategory)}
              style={{
                height: 34,
                padding: '0 8px',
                borderRadius: 8,
                border: '1px solid var(--border-rim)',
                background: 'var(--card-bg)',
              }}
            >
              {USER_CATEGORIES.map((cat) => (
                <option key={cat} value={cat}>
                  {categoryDisplayName(cat)}
                </option>
              ))}
            </select>
          </label>

          <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span style={{ fontWeight: 600, fontSize: 12.5 }}>扫描方式</span>
            <select
              value={mode}
              onChange={(e) => setMode(e.target.value as ScanTargetMode)}
              style={{
                height: 34,
                padding: '0 8px',
                borderRadius: 8,
                border: '1px solid var(--border-rim)',
                background: 'var(--card-bg)',
              }}
            >
              <option value="children">显示文件夹中的一级条目</option>
              <option value="directory">将整个文件夹作为一项</option>
            </select>
          </label>
        </div>

        {submitError && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: 'var(--accent-risk)', fontSize: 12 }}>
            <AlertTriangle size={14} />
            <span>{submitError}</span>
          </div>
        )}

        <div style={{ height: 1, background: 'var(--divider)' }} />

        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10 }}>
          <button type="button" className="btn-subtle-pill" onClick={onClose}>
            取消
          </button>
          <button type="submit" className="btn-glow-primary" disabled={!canSubmit} data-testid="submit-custom-dir-btn">
            {submitting ? '正在添加…' : '添加并扫描'}
          </button>
        </div>
      </form>
    </div>
  );
}
