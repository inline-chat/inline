// Run with node --test after installing this adapter's pinned dependencies.
// INLINE_AMP_ADAPTER_BIN can point at a scratch installation of the artifact.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const adapter = process.env.INLINE_AMP_ADAPTER_BIN ?? fileURLToPath(new URL('dist/index.js', import.meta.url));

function client(env) {
  const child = spawn(process.execPath, [adapter], { env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
  let serial = 0;
  const pending = new Map();
  const updates = [];
  child.stderr.resume();
  createInterface({ input: child.stdout }).on('line', line => {
    const value = JSON.parse(line);
    if (value.method) updates.push(value);
    else {
      const waiter = pending.get(value.id);
      if (!waiter) return;
      pending.delete(value.id);
      clearTimeout(waiter.timer);
      if (value.error) waiter.reject(new Error(JSON.stringify(value.error)));
      else waiter.resolve(value.result);
    }
  });
  return {
    updates,
    notify(method, params) { child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n'); },
    request(method, params) {
      const id = ++serial;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`Timeout: ${method}`)), 8000);
        pending.set(id, { resolve, reject, timer });
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
      });
    },
    async close() {
      if (child.exitCode !== null || child.signalCode !== null) return;
      const done = new Promise(resolve => child.once('exit', resolve));
      if (child.exitCode === null) process.kill(-child.pid, 'SIGTERM');
      for (const waiter of pending.values()) clearTimeout(waiter.timer);
      await done;
    },
  };
}

test('pinned Amp ACP preserves identity, settings and fresh MCP bindings across epochs', { timeout: 30000 }, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'inline-amp-continuity-'));
  const native = path.join(root, 'amp-fixture.mjs');
  fs.writeFileSync(native, `#!/usr/bin/env node
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
const args = process.argv.slice(2);
let prompt = '';
for await (const chunk of process.stdin) prompt += chunk;
const id = args[0] === 'threads' ? args[2] : 'T-' + randomUUID();
const file = process.env.AMP_FIXTURE_ROOT + '/' + id;
const previous = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
fs.writeFileSync(file, previous || prompt);
fs.appendFileSync(process.env.AMP_FIXTURE_ROOT + '/calls', JSON.stringify({ args, id, prompt, previous }) + '\\n');
console.log(JSON.stringify({ type: 'system', session_id: id }));
if (prompt === 'wait') setInterval(() => {}, 1000);
else {
  console.log(JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: previous || prompt }] } }));
  console.log(JSON.stringify({ type: 'result', is_error: false }));
}
`, { mode: 0o700 });
  const sessions = path.join(root, 'sessions');
  const env = { ...process.env, AMP_CLI_PATH: native, AMP_ACP_TRANSPORT: 'cli', AMP_ACP_SESSION_DIR: sessions, AMP_FIXTURE_ROOT: root, AMP_API_KEY: 'fixture-only', AMP_SKIP_UPDATE_CHECK: '1', AMP_ACP_CONTINUE_LATEST: '1' };
  const peers = [];
  const open = async () => {
    const peer = client(env);
    peers.push(peer);
    const info = await peer.request('initialize', { protocolVersion: 1, clientCapabilities: {} });
    assert.equal(info.agentCapabilities.loadSession, true);
    assert.equal(info.agentCapabilities.promptCapabilities.image, false);
    assert.equal(info.agentInfo.version, '0.8.1+e4ccce1.inline2');
    return peer;
  };
  const mcp = marker => [{ name: 'inline', command: 'fixture-mcp', args: [marker], env: [] }];
  const prompt = (peer, sessionId, text) => peer.request('session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
  try {
    const first = await open();
    const a = await first.request('session/new', { cwd: root, mcpServers: mcp('old-capability') });
    const b = await first.request('session/new', { cwd: root, mcpServers: mcp('other-chat') });
    assert.notEqual(a.sessionId, b.sessionId);
    await first.request('session/set_config_option', { sessionId: a.sessionId, configId: 'amp-mode', value: 'high' });
    assert.equal((await prompt(first, a.sessionId, 'remember-731')).stopReason, 'end_turn');
    await prompt(first, b.sessionId, 'other-842');
    const saved = JSON.parse(fs.readFileSync(path.join(sessions, a.sessionId + '.json'), 'utf8'));
    assert.equal(saved.model, 'high');
    assert.match(saved.threadId, /^T-/);
    assert.equal(Object.keys(saved).sort().join(','), 'cwd,mode,model,threadId,version');
    assert.equal(fs.statSync(path.join(sessions, a.sessionId + '.json')).mode & 0o777, 0o600);
    await first.close();
    peers.splice(peers.indexOf(first), 1);
    const resumed = await open();
    const loaded = await resumed.request('session/load', { sessionId: a.sessionId, cwd: root, mcpServers: mcp('new-capability') });
    assert.equal(loaded.configOptions.find(c => c.id === 'amp-mode').currentValue, 'high');
    await prompt(resumed, a.sessionId, 'recall');
    const calls = fs.readFileSync(path.join(root, 'calls'), 'utf8').trim().split('\n').map(JSON.parse);
    assert.equal(calls[2].id, calls[0].id);
    assert.notEqual(calls[1].id, calls[0].id);
    assert.equal(calls[2].previous, 'remember-731');
    assert.ok(calls[2].args.includes('high'));
    assert.ok(calls[2].args.includes(JSON.stringify({ inline: { command: 'fixture-mcp', args: ['new-capability'] } })));
    assert.ok(calls.every(call => !call.args.includes('--last')));
    await assert.rejects(resumed.request('session/load', { sessionId: a.sessionId, cwd: os.tmpdir(), mcpServers: [] }));
    await assert.rejects(resumed.request('session/load', { sessionId: '../outside', cwd: root, mcpServers: [] }));
    const waiting = prompt(resumed, a.sessionId, 'wait');
    const deadline = Date.now() + 4000;
    while (fs.readFileSync(path.join(root, 'calls'), 'utf8').trim().split('\n').length < 4) {
      assert.ok(Date.now() < deadline, 'waiting turn did not start');
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    resumed.notify('session/cancel', { sessionId: a.sessionId });
    assert.equal((await waiting).stopReason, 'cancelled');
    await prompt(resumed, a.sessionId, 'after-cancel');
    fs.writeFileSync(path.join(sessions, a.sessionId + '.json'), '{}');
    await assert.rejects(resumed.request('session/load', { sessionId: a.sessionId, cwd: root, mcpServers: [] }));
  } finally {
    for (const peer of peers) await peer.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
});
