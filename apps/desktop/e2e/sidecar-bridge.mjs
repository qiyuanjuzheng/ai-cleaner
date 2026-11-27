import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';

const ALLOWED_METHODS = new Set([
  'core.handshake',
  'core.ping',
  'core.shutdown',
  'scan.start',
  'scan.cancel',
  'report.summary',
  'clients.list',
  'items.query',
  'items.get',
  'items.resolvePath',
  'selection.apply',
  'selection.confirmRisk',
  'trash.preview',
  'trash.execute',
  'history.list',
  'history.delete',
  'history.clear',
  'excluded.list',
  'excluded.add',
  'excluded.restore',
  'excluded.restoreAll',
  'customDirs.list',
  'customDirs.validate',
  'customDirs.add',
  'customDirs.remove',
  'projects.list',
  'projects.sessions',
  'projects.setProtection',
  'disk.capacity',
  'settings.get',
  'settings.set',
]);

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8',
  '.ico': 'image/x-icon',
};

export function resolveSidecarBinary(repoRoot) {
  if (process.env.AI_CLEANER_SIDECAR_PATH && fs.existsSync(process.env.AI_CLEANER_SIDECAR_PATH)) {
    return process.env.AI_CLEANER_SIDECAR_PATH;
  }
  const exe = process.platform === 'win32' ? 'aicleaner-core.exe' : 'aicleaner-core';
  for (const config of ['debug', 'release']) {
    const candidate = path.join(repoRoot, '.build', config, exe);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  throw new Error(`Could not locate built ${exe} under ${path.join(repoRoot, '.build')}`);
}

export function seedSandbox(sandboxHome, options = {}) {
  const { stressFileCount = 0 } = options;

  // 1. Codex recommended log files (`codex-cli-log` is mode=children, recommended on macOS, Linux, Windows)
  const codexLog = path.join(sandboxHome, '.codex', 'log');
  fs.mkdirSync(codexLog, { recursive: true });
  const staleTmpPath = path.join(codexLog, 'e2e-stale-cache.log');
  fs.writeFileSync(staleTmpPath, 'x'.repeat(4096));

  const excludeTargetPath = path.join(codexLog, 'e2e-exclude-me.log');
  fs.writeFileSync(excludeTargetPath, 'y'.repeat(2048));

  // Optional 5,200+ file stress payload inside `.codex/log`
  if (stressFileCount > 0) {
    for (let i = 0; i < stressFileCount; i += 1) {
      const name = `bulk-${String(i).padStart(5, '0')}.log`;
      fs.writeFileSync(path.join(codexLog, name), 'z'.repeat(64));
    }
  }

  // 2. Codex project session with workspace path & long session title
  const sessionUuid = '11111111-2222-3333-4444-555555555555';
  const projectWorkspace = path.join(sandboxHome, 'workspace', 'demo-ai-project');
  fs.mkdirSync(projectWorkspace, { recursive: true });

  const sessionDir = path.join(sandboxHome, '.codex', 'sessions', '2026', '01', '15');
  fs.mkdirSync(sessionDir, { recursive: true });
  const sessionFile = path.join(sessionDir, `rollout-2026-01-15T10-00-00-${sessionUuid}.jsonl`);
  const longTitle =
    'Cross-platform Tauri 2 frontend alignment with Swift Core sidecar, project protection, and 5000+ virtualized list';
  const metaLine = JSON.stringify({
    type: 'session_meta',
    payload: { id: sessionUuid, cwd: projectWorkspace },
  });
  const msgLine = JSON.stringify({
    type: 'event_msg',
    payload: { type: 'user_message', message: longTitle },
  });
  fs.writeFileSync(sessionFile, `${metaLine}\n${msgLine}\n`, 'utf8');
  fs.writeFileSync(
    path.join(sandboxHome, '.codex', 'session_index.jsonl'),
    `${JSON.stringify({ id: sessionUuid, thread_name: longTitle })}\n`,
    'utf8'
  );

  // Backdate session mtime > 90 days so age filters can match it too
  const oldDate = new Date('2026-01-15T10:00:00Z');
  fs.utimesSync(sessionFile, oldDate, oldDate);

  // 3. Protected Codex config / db fixture
  const protectedAuth = path.join(sandboxHome, '.codex', 'auth.json');
  fs.writeFileSync(protectedAuth, '{"token":"do-not-delete"}\n', 'utf8');

  // 4. Safe custom directory candidate
  const safeCustomDir = path.join(sandboxHome, 'my-custom-ai-cache');
  fs.mkdirSync(safeCustomDir, { recursive: true });
  fs.writeFileSync(path.join(safeCustomDir, 'custom-export.log'), 'custom log payload'.repeat(80), 'utf8');

  const blockedRootDir = process.platform === 'win32' ? 'C:\\Windows' : '/';

  return {
    sandboxHome,
    staleTmpPath,
    excludeTargetPath,
    sessionFile,
    longTitle,
    projectName: 'demo-ai-project',
    safeCustomDir,
    blockedRootDir,
  };
}

/**
 * Starts a real HTTP + SSE bridge backed by the compiled Swift `aicleaner-core` binary
 * and serves the built production frontend from `apps/desktop/dist`.
 */
export async function startE2EBridge({ repoRoot, distDir, stressFileCount = 0 }) {
  const binary = resolveSidecarBinary(repoRoot);
  const sandboxHome = fs.mkdtempSync(path.join(os.tmpdir(), 'aicleaner-e2e-'));
  const fixtureInfo = seedSandbox(sandboxHome, { stressFileCount });

  const env = {
    ...process.env,
    AI_CLEANER_HOME: sandboxHome,
    HOME: sandboxHome,
    USERPROFILE: sandboxHome,
    XDG_DATA_HOME: path.join(sandboxHome, '.local', 'share'),
    XDG_CONFIG_HOME: path.join(sandboxHome, '.config'),
    XDG_CACHE_HOME: path.join(sandboxHome, '.cache'),
  };

  const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'pipe'], env });
  const pending = new Map();
  const sseClients = new Set();
  const revealedPaths = [];
  let nextId = 1;
  let stderrLog = '';

  child.stderr.on('data', (chunk) => {
    stderrLog += chunk.toString('utf8');
  });

  const rl = readline.createInterface({ input: child.stdout });
  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try {
      msg = JSON.parse(trimmed);
    } catch {
      return;
    }
    if (typeof msg.id === 'number') {
      const waiter = pending.get(msg.id);
      if (waiter) {
        pending.delete(msg.id);
        if (msg.error) waiter.reject(msg.error);
        else waiter.resolve(msg.result);
      }
    } else if (msg.method) {
      const data = `data: ${JSON.stringify(msg)}\n\n`;
      for (const res of sseClients) {
        res.write(data);
      }
    }
  });

  function sendRpc(method, params = {}) {
    if (!ALLOWED_METHODS.has(method)) {
      return Promise.reject({
        code: -32601,
        message: `Method not allowed by host whitelist: ${method}`,
        data: { name: 'METHOD_NOT_ALLOWED' },
      });
    }
    const id = nextId++;
    const payload = JSON.stringify({ jsonrpc: '2.0', id, method, params });
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(`${payload}\n`);
    });
  }

  const hostPlatform =
    process.platform === 'darwin' ? 'macos' : process.platform === 'win32' ? 'windows' : 'linux';

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url || '/', 'http://127.0.0.1');

    if (req.method === 'GET' && url.pathname === '/events') {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
      });
      res.write(':\n\n');
      sseClients.add(res);
      req.on('close', () => sseClients.delete(res));
      return;
    }

    if (req.method === 'GET' && url.pathname === '/platform') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ platform: hostPlatform }));
      return;
    }

    if (req.method === 'GET' && url.pathname === '/__test/info') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ...fixtureInfo, hostPlatform, revealedPaths }));
      return;
    }

    if (req.method === 'POST' && (url.pathname === '/rpc' || url.pathname === '/reveal-scan' || url.pathname === '/reveal-excluded')) {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');

      if (url.pathname === '/rpc') {
        try {
          const result = await sendRpc(body.method, body.params ?? {});
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ result }));
        } catch (error) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error }));
        }
        return;
      }

      if (url.pathname === '/reveal-scan') {
        try {
          const resolved = await sendRpc('items.resolvePath', { scanId: body.scanId, itemId: body.itemId });
          revealedPaths.push(resolved.path);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, path: resolved.path }));
        } catch (error) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error }));
        }
        return;
      }

      if (url.pathname === '/reveal-excluded') {
        try {
          const listed = await sendRpc('excluded.list', {});
          const found = (listed.records || []).find((r) => r.id.toLowerCase() === String(body.recordId).toLowerCase());
          if (found) revealedPaths.push(found.normalizedPath);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: Boolean(found) }));
        } catch (error) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error }));
        }
        return;
      }
    }

    // Serve static files from Vite dist
    let relPath = decodeURIComponent(url.pathname);
    if (relPath === '/') relPath = '/index.html';
    const filePath = path.join(distDir, relPath);
    if (!filePath.startsWith(distDir) || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      res.writeHead(404);
      res.end('Not Found');
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME_TYPES[ext] || 'application/octet-stream' });
    fs.createReadStream(filePath).pipe(res);
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const baseUrl = `http://127.0.0.1:${address.port}`;

  async function close() {
    for (const res of sseClients) res.end();
    sseClients.clear();
    try {
      await sendRpc('core.shutdown', {});
    } catch {
      // ignore if already exited
    }
    try {
      child.kill();
    } catch {
      // ignore
    }
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(sandboxHome, { recursive: true, force: true });
  }

  return {
    baseUrl,
    fixtureInfo,
    revealedPaths,
    getStderr: () => stderrLog,
    close,
  };
}
