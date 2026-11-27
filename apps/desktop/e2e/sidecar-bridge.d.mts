export interface SandboxFixtureInfo {
  sandboxHome: string;
  staleTmpPath: string;
  excludeTargetPath: string;
  sessionFile: string;
  longTitle: string;
  projectName: string;
  safeCustomDir: string;
  blockedRootDir: string;
}

export interface E2EBridgeHandle {
  baseUrl: string;
  fixtureInfo: SandboxFixtureInfo;
  revealedPaths: string[];
  getStderr(): string;
  close(): Promise<void>;
}

export function startE2EBridge(options: {
  repoRoot: string;
  distDir: string;
  stressFileCount?: number;
}): Promise<E2EBridgeHandle>;
