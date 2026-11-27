import { Check, Sparkles, X } from 'lucide-react';
import { formatBytes, stageDisplayName } from '../lib/format';
import type { ScanProgressNotification, ScanStage } from '../rpc/types';
import { ClientLogo } from './ClientLogo';

const STAGES: ScanStage[] = ['scanningClients', 'analyzingCacheFiles', 'tallyingCleanableSpace'];

interface OrbitalScannerHeroProps {
  progress: ScanProgressNotification | null;
  effectiveTheme: 'light' | 'dark';
  onCancel: () => void;
}

export function OrbitalScannerHero({ progress, effectiveTheme, onCancel }: OrbitalScannerHeroProps) {
  const currentStage = progress?.stage ?? 'scanningClients';
  const currentIndex = STAGES.indexOf(currentStage);
  const revealedClients = (progress?.clients ?? [])
    .filter((c) => c.state === 'measured' && (c.cleanableBytes > 0 || c.itemCount > 0))
    .slice(-5);

  return (
    <section className="hero-center-stage" data-testid="orbital-scanner-hero">
      <div className="orbital-ring-wrap" aria-hidden="true">
        <div className="orbital-ring-outer" />
        <div className="orbital-ring-inner" />
        <div
          style={{
            width: 82,
            height: 82,
            borderRadius: '50%',
            background: 'linear-gradient(135deg, rgba(41, 209, 138, 0.16), rgba(59, 130, 246, 0.18))',
            border: '1px solid var(--border-rim)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            color: 'var(--accent-recommended)',
          }}
        >
          <Sparkles size={28} />
        </div>
      </div>

      <div style={{ textAlign: 'center' }}>
        <h2 style={{ margin: '0 0 4px', fontSize: 19, fontWeight: 700 }}>正在扫描 AI 客户端空间…</h2>
        <div className="mono-num" style={{ fontSize: 12.5, color: 'var(--text-secondary)' }}>
          已扫描 {progress?.scannedFileCount ?? 0} 个文件 · 已发现可清理{' '}
          <strong style={{ color: 'var(--accent-recommended)' }}>
            {formatBytes(progress?.cleanableBytes ?? 0)}
          </strong>
        </div>
      </div>

      <div className="stage-bar" role="status" aria-label={`当前阶段：${stageDisplayName(currentStage)}`}>
        {STAGES.map((stage, idx) => {
          const status = idx < currentIndex ? 'done' : idx === currentIndex ? 'active' : 'pending';
          return (
            <div key={stage} className={`stage-capsule ${status}`}>
              <span
                style={{
                  width: 15,
                  height: 15,
                  borderRadius: '50%',
                  display: 'inline-flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 9,
                  fontWeight: 700,
                  background:
                    status === 'done'
                      ? 'var(--accent-recommended)'
                      : status === 'active'
                        ? 'var(--accent-blue)'
                        : 'var(--surface-muted)',
                  color: status === 'pending' ? 'var(--text-tertiary)' : '#ffffff',
                }}
              >
                {status === 'done' ? <Check size={9} strokeWidth={3} /> : idx + 1}
              </span>
              <span>{stageDisplayName(stage)}</span>
            </div>
          );
        })}
      </div>

      {revealedClients.length > 0 && (
        <div className="ticker-row" aria-label="已发现客户端">
          {revealedClients.map((client) => (
            <div key={client.id} className="ticker-card">
              <ClientLogo clientId={client.id} effectiveTheme={effectiveTheme} size={32} />
              <span
                style={{
                  fontSize: 11.5,
                  fontWeight: 600,
                  maxWidth: '100%',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
              >
                {client.name}
              </span>
              <span
                className="mono-num"
                style={{ fontSize: 10.5, fontWeight: 600, color: 'var(--accent-recommended)' }}
              >
                {formatBytes(client.cleanableBytes)}
              </span>
            </div>
          ))}
        </div>
      )}

      <button type="button" className="btn-subtle-pill" onClick={onCancel} data-testid="cancel-scan-button">
        <X size={13} />
        <span>取消扫描</span>
      </button>
    </section>
  );
}
