#!/usr/bin/env node
// Paginated read-only observation: do not infer quiescence from a CLI's first page.
import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
class ProbeError extends Error {}
let phase = 'runtime metadata';
function fail(message) { throw new ProbeError(message); }
function nextPage(page) {
  if (!Array.isArray(page?.entries) || typeof page.pageInfo?.hasMore !== 'boolean') fail('unknown Paseo activity response');
  if (!page.pageInfo.hasMore) return null;
  if (typeof page.pageInfo.nextCursor !== 'string' || !page.pageInfo.nextCursor) fail('incomplete Paseo activity pagination');
  return page.pageInfo.nextCursor;
}
async function walk(fetch, check) {
  let cursor;
  const seen = new Set();
  do {
    const page = await fetch({limit: 200, ...(cursor ? {cursor} : {})});
    const next = nextPage(page);
    for (const entry of page.entries) check(entry);
    cursor = next;
    if (cursor && seen.has(cursor)) fail('unstable Paseo activity pagination');
    seen.add(cursor);
  } while (cursor);
}
export async function assertQuiescent(client) {
  await walk(page => client.fetchAgents({scope: 'active', filter: {includeArchived: true}, page}), ({agent}) => {
    if (!agent || !['idle', 'closed', 'error'].includes(agent.status) || !Array.isArray(agent.pendingPermissions)) fail('busy or unknown Paseo agent status');
    if (agent.activeTurn || agent.pendingPermissions.length || agent.attentionReason === 'permission') fail('Paseo has active work or pending approvals');
  });
  await walk(page => client.fetchWorkspaces({page}), workspace => {
    if (!workspace || !['done', 'failed', 'attention'].includes(workspace.status) || !Array.isArray(workspace.scripts)) fail('busy or unknown Paseo workspace status');
    if (workspace.archivingAt || workspace.scripts.some(script => script.lifecycle !== 'stopped')) fail('Paseo has active workspace work');
  });
  const terminals = await client.listTerminals();
  if (!Array.isArray(terminals?.terminals) || terminals.terminals.length) fail('Paseo has active or unknown terminal sessions');
}

export function assertHealth(info, health, instance, listen) {
  if (!instance || info?.status !== 'server_info' || info.version !== '0.11.2' ||
      info.listen !== listen || instance.listen !== listen || !instance.serverId || info.serverId !== instance.serverId ||
      health?.status !== 'ok' || typeof health.timestamp !== 'string' || !Number.isFinite(Date.parse(health.timestamp))) fail('Paseo authenticated health identity is invalid');
}

async function main() {
  const [mode, runtime, home, url = 'http://127.0.0.1:31415/api/health', resolve = '', listen = '127.0.0.1:31415'] = process.argv.slice(2);
  if (!['health', 'quiescent'].includes(mode) || !/^127\.0\.0\.1:[0-9]{1,5}$/.test(listen)) fail('invalid probe arguments');
  if (!(url === `http://${listen}/api/health` || /^https:\/\/pi\.dpao\.la(?::8443)?\/api\/health$/.test(url))) fail('invalid probe URL');
  const requireRuntime = createRequire(path.resolve(runtime, 'package.json'));
  const control = await import(pathToFileURL(requireRuntime.resolve('@getpaseo/server/daemon-control')));
  const instance = await control.readDaemonInstance(home);
  const credentialFile = path.join(home, 'local-credential');
  const metadata = fs.lstatSync(credentialFile);
  if (!metadata.isFile() || metadata.uid !== process.getuid() || (metadata.mode & 0o077)) fail('local credential must be a regular private file');
  const token = control.readLocalCredentialForTarget(home, listen);
  if (!token) fail('local authenticated observation is unavailable');
  function request(endpoint, authenticated) {
    const args = ['-q', '--noproxy', '*', '--fail', '--silent', '--show-error', '--connect-timeout', '2', '--max-time', '5'];
    if (resolve) args.push('--resolve', resolve);
    if (authenticated) args.push('--header', '@-');
    args.push(endpoint);
    // The credential travels over stdin, never argv, a URL, or logged output.
    const result = spawnSync('curl', args, {input: authenticated ? `Authorization: Bearer ${token}\n` : '', encoding: 'utf8', timeout: 7000});
    if (result.status !== 0) fail('Paseo HTTP observation failed');
    try { return JSON.parse(result.stdout); } catch { fail('Paseo HTTP response is invalid'); }
  }
  phase = 'HTTP status/health';
  const info = request(url.replace(/\/health$/, '/status'), true);
  assertHealth(info, request(url, false), instance, listen);
  if (mode === 'quiescent') {
    phase = 'WebSocket activity';
    const {DaemonClient} = await import(pathToFileURL(requireRuntime.resolve('@getpaseo/client/internal/daemon-client')));
    const WebSocket = requireRuntime('ws');
    const client = new DaemonClient({url: `ws://${listen}/ws`, clientId: 'dotfiles-readonly-probe', clientType: 'cli', appVersion: '0.11.2',
      localCredential: () => control.readLocalCredentialForTarget(home, listen) ?? undefined, connectTimeoutMs: 2500, reconnect: {enabled: false},
      webSocketFactory: (target, config) => new WebSocket(target, config?.protocols, {headers: config?.headers})});
    try {
      await client.connect();
      const observed = client.getLastServerInfoMessage();
      if (observed?.serverId !== instance.serverId || observed?.version !== '0.11.2') fail('Paseo changed during activity observation');
      await assertQuiescent(client);
    } finally { await client.close(); }
    const current = await control.readDaemonInstance(home);
    if (!current || current.pid !== instance.pid || current.serverId !== instance.serverId) fail('Paseo changed during activity observation');
  }
  console.log(mode === 'health' ? 'Paseo is healthy' : 'Paseo is quiescent');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(`error: Paseo ${phase}: ${error instanceof ProbeError ? error.message : 'authenticated observation unavailable'}`); process.exitCode = 1; });
}
