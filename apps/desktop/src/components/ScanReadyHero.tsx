import { ShieldCheck, Sparkles, TrendingUp } from 'lucide-react';
import { formatBytes, trashName } from '../lib/format';
import type { PlatformKind } from '../rpc/types';

interface ScanReadyHeroProps {
  historicalFreedBytes: number;
  platform: PlatformKind;
  onStartScan: () => void;
  onOpenHistory: () => void;
}

export function ScanReadyHero({
  historicalFreedBytes,
  platform,
  onStartScan,
  onOpenHistory,
}: ScanReadyHeroProps) {
  return (
    <section className="hero-center-stage" data-testid="scan-ready-hero">
      <div style={{ textAlign: 'center', maxWidth: 460 }}>
        <h1 style={{ margin: '0 0 6px', fontSize: 24, fontWeight: 700, letterSpacing: '-0.02em' }}>
          扫描本机 AI 客户端空间
        </h1>
        <p style={{ margin: 0, fontSize: 13, color: 'var(--text-secondary)' }}>
          识别缓存、日志、会话记录与临时文件，自动锁定凭据与主数据库，清理仅移入系统{trashName(platform)}。
        </p>
      </div>

      <button
        type="button"
        className="ready-orb-btn"
        onClick={onStartScan}
        data-testid="start-scan-button"
      >
        <Sparkles size={28} />
        <span style={{ fontSize: 16, fontWeight: 700 }}>开始扫描</span>
        <span style={{ fontSize: 11, opacity: 0.88 }}>安全只读扫描</span>
      </button>

      {historicalFreedBytes > 0 && (
        <button
          type="button"
          className="btn-subtle-pill"
          onClick={onOpenHistory}
          data-testid="hero-open-history"
        >
          <TrendingUp size={13} style={{ color: 'var(--accent-recommended)' }} />
          <span className="mono-num">累计已清理 {formatBytes(historicalFreedBytes)}</span>
          <span style={{ color: 'var(--accent-blue)', fontWeight: 600 }}>查看清理记录</span>
        </button>
      )}

      <div
        style={{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 6,
          fontSize: 11.5,
          color: 'var(--text-tertiary)',
        }}
      >
        <ShieldCheck size={14} style={{ color: 'var(--accent-recommended)' }} />
        <span>SafetyGuard 全程防护 · 绝不执行永久删除</span>
      </div>
    </section>
  );
}
