import { formatBytes } from '../lib/format';
import { RECOMMENDATION_COLORS } from '../lib/theme';
import type { CleanupRecommendation } from '../rpc/types';

interface StorageRingGaugeProps {
  recommendedBytes: number;
  reviewBytes: number;
  protectedBytes: number;
  highlightedTier: CleanupRecommendation | null;
}

export function StorageRingGauge({
  recommendedBytes,
  reviewBytes,
  protectedBytes,
  highlightedTier,
}: StorageRingGaugeProps) {
  const cleanableTotal = Math.max(0, recommendedBytes) + Math.max(0, reviewBytes);
  const grandTotal = cleanableTotal + Math.max(0, protectedBytes);

  const radius = 37;
  const circumference = 2 * Math.PI * radius;

  const segments: Array<{ tier: CleanupRecommendation; bytes: number; color: string }> = [
    { tier: 'recommended', bytes: Math.max(0, recommendedBytes), color: RECOMMENDATION_COLORS.recommended },
    { tier: 'reviewSuggested', bytes: Math.max(0, reviewBytes), color: RECOMMENDATION_COLORS.reviewSuggested },
    { tier: 'notRecommended', bytes: Math.max(0, protectedBytes), color: RECOMMENDATION_COLORS.notRecommended },
  ];

  let offsetAccumulator = 0;

  return (
    <div
      style={{
        position: 'relative',
        width: 90,
        height: 90,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
      aria-label={`可清理空间 ${formatBytes(cleanableTotal)}`}
    >
      <svg width="90" height="90" viewBox="0 0 90 90" style={{ transform: 'rotate(-90deg)' }}>
        <circle
          cx="45"
          cy="45"
          r={radius}
          fill="none"
          stroke="var(--surface-muted)"
          strokeWidth="8"
        />
        {grandTotal > 0 &&
          segments.map((seg) => {
            if (seg.bytes <= 0) return null;
            const fraction = seg.bytes / grandTotal;
            const dashLength = Math.max(3, fraction * circumference - 2);
            const dashOffset = -offsetAccumulator * circumference;
            offsetAccumulator += fraction;
            const dimmed = highlightedTier !== null && highlightedTier !== seg.tier;
            return (
              <circle
                key={seg.tier}
                cx="45"
                cy="45"
                r={radius}
                fill="none"
                stroke={seg.color}
                strokeWidth={highlightedTier === seg.tier ? 9.5 : 8}
                strokeLinecap="round"
                strokeDasharray={`${dashLength} ${circumference}`}
                strokeDashoffset={dashOffset}
                style={{
                  opacity: dimmed ? 0.28 : 1,
                  transition: 'opacity 160ms ease, stroke-width 160ms ease',
                }}
              />
            );
          })}
      </svg>

      <div
        style={{
          position: 'absolute',
          inset: 0,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          textAlign: 'center',
          pointerEvents: 'none',
        }}
      >
        <span className="mono-num" style={{ fontSize: 13.5, fontWeight: 700, lineHeight: 1.1 }}>
          {formatBytes(cleanableTotal)}
        </span>
        <span style={{ fontSize: 10, color: 'var(--text-tertiary)', marginTop: 2 }}>可清理</span>
      </div>
    </div>
  );
}

interface HairlineStorageBarProps {
  recommendedBytes: number;
  reviewBytes: number;
  protectedBytes: number;
  highlightedTier: CleanupRecommendation | null;
}

export function HairlineStorageBar({
  recommendedBytes,
  reviewBytes,
  protectedBytes,
  highlightedTier,
}: HairlineStorageBarProps) {
  const total =
    Math.max(0, recommendedBytes) + Math.max(0, reviewBytes) + Math.max(0, protectedBytes);
  const parts: Array<{ tier: CleanupRecommendation; bytes: number; color: string }> = [
    { tier: 'recommended', bytes: Math.max(0, recommendedBytes), color: RECOMMENDATION_COLORS.recommended },
    { tier: 'reviewSuggested', bytes: Math.max(0, reviewBytes), color: RECOMMENDATION_COLORS.reviewSuggested },
    { tier: 'notRecommended', bytes: Math.max(0, protectedBytes), color: RECOMMENDATION_COLORS.notRecommended },
  ];

  return (
    <div className="hairline-bar" aria-hidden="true">
      {total > 0 &&
        parts.map((part) => {
          if (part.bytes <= 0) return null;
          const pct = (part.bytes / total) * 100;
          const dimmed = highlightedTier !== null && highlightedTier !== part.tier;
          return (
            <div
              key={part.tier}
              style={{
                width: `${pct}%`,
                background: part.color,
                opacity: dimmed ? 0.25 : 1,
                transition: 'opacity 160ms ease, width 220ms ease',
              }}
            />
          );
        })}
    </div>
  );
}
