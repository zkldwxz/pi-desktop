import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { registerDesktopProviders, shouldConfirm } from '../desktop-config.mjs';

const runtime = fileURLToPath(new URL('..', import.meta.url));

test('approval policy permits reads and asks before edits, commands, and desktop tools', () => {
  for (const name of ['read', 'grep', 'find', 'ls']) assert.equal(shouldConfirm(name, 'ask'), false);
  for (const name of ['edit', 'write', 'bash', 'powershell', 'mcp__pi_desktop__browser_click']) {
    assert.equal(shouldConfirm(name, 'ask'), true);
    assert.equal(shouldConfirm(name, 'full'), false);
  }
});

test('provider credentials remain environment references; expressions are not executed', () => {
  let actual;
  registerDesktopProviders({ registerProvider: (id, config) => { actual = { id, config }; } }, {
    PI_DESKTOP_PROVIDERS: JSON.stringify([{
      id: 'desktop-test', name: 'Test', api: 'openai-completions', baseUrl: 'http://127.0.0.1/v1',
      keyVariable: 'PI_DESKTOP_KEY_0', models: [],
      headers: { 'X-Literal': '$TOKEN', 'X-Command': '!never-run' },
    }]),
    PI_DESKTOP_KEY_0: '!do-not-run-this',
  });
  assert.equal(actual.id, 'desktop-test');
  assert.equal(actual.config.apiKey, '$PI_DESKTOP_KEY_0');
  assert.equal(actual.config.headers['X-Literal'], '$$TOKEN');
  assert.equal(actual.config.headers['X-Command'], '$!never-run');
  assert.throws(() => registerDesktopProviders({ registerProvider() {} }, {
    PI_DESKTOP_PROVIDERS: JSON.stringify([{ id: 'bad', models: [], keyVariable: '!command' }]),
  }), /credential reference/);
});

test('the pinned real Pi process accepts RPC and desktop permission commands without model access', { timeout: 30000 }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'pi-desktop-rpc-'));
  const cli = path.join(runtime, 'node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js');
  const child = spawn(process.execPath, [cli, '--mode', 'rpc', '--no-session', '--no-approve', '--no-mcp',
    '--extension', path.join(runtime, 'desktop-extension.mjs')], {
    cwd: directory,
    env: { PATH: process.env.PATH, HOME: directory, PI_CODING_AGENT_DIR: path.join(directory, 'agent'),
      PI_SKIP_VERSION_CHECK: '1', NO_COLOR: '1' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const pending = new Map();
  let output = '';
  let diagnostic = '';
  child.stderr.on('data', (chunk) => { diagnostic += chunk; });
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    output += chunk;
    let newline;
    while ((newline = output.indexOf('\n')) >= 0) {
      const line = output.slice(0, newline);
      output = output.slice(newline + 1);
      if (!line.trim()) continue;
      const message = JSON.parse(line);
      if (message.type === 'response') pending.get(message.id)?.(message);
    }
  });
  const exited = new Promise((resolve) => child.once('exit', resolve));
  const request = (id, type, fields = {}) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Pi RPC timeout: ${diagnostic}`)); }, 20000);
    pending.set(id, (message) => { clearTimeout(timer); pending.delete(id); resolve(message); });
    child.stdin.write(`${JSON.stringify({ id, type, ...fields })}\n`);
  });
  try {
    const state = await request('state', 'get_state');
    assert.equal(state.success, true, diagnostic);
    assert.equal(typeof state.data.sessionId, 'string');
    const commands = await request('commands', 'get_commands');
    assert.ok(commands.data.commands.some((command) => command.name === 'desktop-permission'), diagnostic);
    const permission = await request('permission', 'prompt', { message: '/desktop-permission full' });
    assert.equal(permission.success, true, diagnostic);
    assert.equal(permission.data.disposition, 'handled');
  } finally {
    child.stdin.end();
    const kill = setTimeout(() => child.kill('SIGKILL'), 3000);
    await exited;
    clearTimeout(kill);
    await rm(directory, { recursive: true, force: true });
  }
});
