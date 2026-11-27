import { Clock, Cpu, Folder, FolderPlus, HelpCircle } from 'lucide-react';
import { useState } from 'react';
import { clientAccentById, resolveClientLogoSrc } from '../lib/theme';
import { OTHER_AI_TEMP_CLIENT_ID, UNATTRIBUTED_TEMP_CLIENT_ID } from '../rpc/types';

interface ClientLogoProps {
  clientId: string;
  effectiveTheme: 'light' | 'dark';
  size?: number;
}

export function ClientLogo({ clientId, effectiveTheme, size = 20 }: ClientLogoProps) {
  const [imgFailed, setImgFailed] = useState(false);
  const tint = clientAccentById(clientId);

  if (clientId.startsWith('custom-')) {
    return (
      <span
        style={{
          width: size,
          height: size,
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: '#14b8a6',
          flexShrink: 0,
        }}
      >
        <FolderPlus size={Math.round(size * 0.78)} />
      </span>
    );
  }

  if (clientId === OTHER_AI_TEMP_CLIENT_ID) {
    return (
      <span
        style={{
          width: size,
          height: size,
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: tint,
          flexShrink: 0,
        }}
      >
        <Clock size={Math.round(size * 0.78)} />
      </span>
    );
  }

  if (clientId === UNATTRIBUTED_TEMP_CLIENT_ID) {
    return (
      <span
        style={{
          width: size,
          height: size,
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: tint,
          flexShrink: 0,
        }}
      >
        <HelpCircle size={Math.round(size * 0.78)} />
      </span>
    );
  }

  const logoSrc = resolveClientLogoSrc(clientId, effectiveTheme);
  if (logoSrc && !imgFailed) {
    return (
      <img
        src={logoSrc}
        alt=""
        aria-hidden="true"
        width={size}
        height={size}
        onError={() => setImgFailed(true)}
        style={{
          width: size,
          height: size,
          borderRadius: Math.max(4, Math.round(size * 0.24)),
          objectFit: 'contain',
          flexShrink: 0,
        }}
      />
    );
  }

  return (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: Math.max(4, Math.round(size * 0.24)),
        background: `color-mix(in srgb, ${tint} 18%, transparent)`,
        color: tint,
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flexShrink: 0,
      }}
    >
      {clientId ? <Cpu size={Math.round(size * 0.68)} /> : <Folder size={Math.round(size * 0.68)} />}
    </span>
  );
}
