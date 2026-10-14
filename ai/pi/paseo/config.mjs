#!/usr/bin/env node
// Only network/entry-point invariants are owned after initialization.
import fs from 'node:fs';
import assert from 'node:assert/strict';

const [mode, input, ...args] = process.argv.slice(2);
const hosts = ['localhost', '127.0.0.1', 'pi.dpao.la'];
function fail(message, status = 1) { const error = new Error(message); error.status = status; throw error; }
function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`invalid configuration object: ${label}`);
  return value;
}
function child(parent, key) { return object(parent[key] ??= {}, key); }
function read(file, privateFile) {
  const st = fs.lstatSync(file);
  if (!st.isFile() || (privateFile && (st.uid !== process.getuid() || (st.mode & 0o077) !== 0))) fail('configuration must be a regular private file owned by the current user');
  let value;
  try { value = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { fail('configuration must contain valid JSON'); }
  return object(value, 'root');
}
function checkPassword(config, required) {
  const auth = config.daemon?.auth;
  if (auth !== undefined) object(auth, 'daemon.auth');
  const password = auth?.password;
  if (password === undefined) { if (required) fail('password required: run the managed paseo daemon set-password command', 2); return; }
  // Bound the work factor as well as rejecting plaintext and malformed hashes.
  const match = typeof password === 'string' && /^\$2[ab]\$(\d\d)\$[./A-Za-z0-9]{53}$/.exec(password);
  if (!match || Number(match[1]) < 10 || Number(match[1]) > 16) fail('invalid daemon.auth.password hash');
}
function checkOptionalListeners(config) {
  const proxy = config.daemon?.serviceProxy;
  if (proxy !== undefined) object(proxy, 'daemon.serviceProxy');
  if (proxy?.enabled === false || proxy?.listen == null) return;
  const m = typeof proxy.listen === 'string' && /^(?:127\.0\.0\.1|\[::1\]):([0-9]{1,5})$/.exec(proxy.listen);
  if (!m || Number(m[1]) < 1 || Number(m[1]) > 65535) fail('extra service proxy listener must be loopback-only');
}
function check(config, pi, required) {
  if (config.daemon?.listen !== '127.0.0.1:31415' || config.daemon?.relay?.enabled !== false ||
      config.app?.baseUrl !== 'https://pi.dpao.la' || config.features?.webUi?.enabled !== true) fail('managed networking configuration differs');
  try {
    assert.deepEqual(config.daemon.hostnames, hosts);
    assert.deepEqual(config.agents?.providers?.pi?.command, [pi]);
  } catch { fail('managed hostname or native Pi command differs'); }
  checkPassword(config, required);
  checkOptionalListeners(config);
}
try {
  if (mode === 'reconcile' && args.length === 3) {
    const [output, pi, baseline] = args;
    const config = fs.existsSync(input) || fs.lstatSync(input, {throwIfNoEntry: false}) ? read(input, true) : read(baseline, false);
    const daemon = child(config, 'daemon');
    daemon.listen = '127.0.0.1:31415';
    daemon.hostnames = [...hosts];
    child(daemon, 'relay').enabled = false;
    child(config, 'app').baseUrl = 'https://pi.dpao.la';
    child(child(config, 'features'), 'webUi').enabled = true;
    child(child(child(config, 'agents'), 'providers'), 'pi').command = [pi];
    check(config, pi, false);
    fs.writeFileSync(output, JSON.stringify(config, null, 2) + '\n', {mode: 0o600, flag: 'wx'});
    console.log('reconciled private Paseo configuration');
  } else if (mode === 'validate' && args.length === 1) {
    check(read(input, true), args[0], true);
    console.log('validated private Paseo configuration');
  } else { fail('usage: config.mjs reconcile INPUT OUTPUT PI BASELINE | validate INPUT PI'); }
} catch (error) {
  // Parser/assertion exceptions must not echo private configuration values.
  console.error(`error: ${error.message}`);
  process.exitCode = error.status || 1;
}
