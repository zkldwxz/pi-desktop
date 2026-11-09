import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { compareVersions, currentRuntime, installPinned, installRelease, latestRelease, npmCommand, pinnedVersion } from '../runtime-manager.mjs';

const packageName = '@earendil-works/pi-coding-agent';
async function installFixture(root, version) {
  const directory = path.join(root, 'node_modules', '@earendil-works', 'pi-coding-agent');
  await mkdir(path.join(directory, 'dist', 'bundle'), { recursive: true });
  await writeFile(path.join(directory, 'package.json'), JSON.stringify({ name: packageName, version }));
  await writeFile(path.join(directory, 'dist', 'bundle', 'cli.js'), '');
}

test('checks the official stable release and rejects unrelated packages or prereleases', async () => {
  const release = await latestRelease(async (url) => {
    assert.equal(url, 'https://pi.dev/api/latest-version');
    return Response.json({ version: '1.6.0', packageName });
  });
  assert.equal(release.version, '1.6.0');
  assert.equal(compareVersions('1.10.0', '1.9.9'), 1);
  await assert.rejects(latestRelease(async () => Response.json({ version: '1.6.0', packageName: 'unrelated' })), /Unexpected/);
  await assert.rejects(latestRelease(async () => Response.json({ version: '1.6.0-rc.1', packageName })), /Unexpected/);
});

test('stages official locked packages and switches only after a successful smoke test', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'pi-update-test-'));
  const bundled = path.join(root, 'bundled');
  const managed = path.join(root, 'managed');
  await installFixture(bundled, '1.5.0');
  const fetcher = async (url) => Response.json(url.endsWith('package-lock.json') ?
    { packages: { '': { dependencies: { [packageName]: '1.6.0' } } } } :
    { dependencies: { [packageName]: '1.6.0' } });
  let checked = false;
  const runner = async (node, args, options) => {
    if (args.includes('ci')) {
      assert.ok(args.includes('--ignore-scripts'));
      assert.ok(args.includes('--include=optional'));
      await installFixture(args[args.indexOf('--prefix') + 1], '1.6.0');
    } else {
      assert.equal(args.at(-1), '--version');
      checked = true;
      await assert.rejects(readFile(path.join(managed, 'current-version')), /ENOENT/);
    }
  };
  try {
    const old = await currentRuntime(managed, bundled);
    assert.equal(old.version, '1.5.0');
    const updated = await installRelease(managed, { version: '1.6.0', packageName }, { fetcher, runner, bundled });
    assert.equal(checked, true);
    assert.equal(updated.version, '1.6.0');
    assert.equal(updated.managed, true);
    assert.equal((await currentRuntime(managed, bundled)).version, '1.6.0');
    // Path traversal in a pointer cannot select another executable.
    await writeFile(path.join(managed, 'current-version'), '../../malicious');
    assert.equal((await currentRuntime(managed, bundled)).version, '1.5.0');
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a failed install leaves the bundled release active', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'pi-update-failure-'));
  const bundled = path.join(root, 'bundled');
  await installFixture(bundled, '1.5.0');
  try {
    await assert.rejects(installRelease(path.join(root, 'managed'), { version: '1.6.0', packageName }, {
      bundled,
      fetcher: async () => Response.json({ dependencies: { [packageName]: '1.5.0' } }),
      runner: async () => { throw new Error('must not run npm'); },
    }), /does not pin/);
    assert.equal((await currentRuntime(path.join(root, 'managed'), bundled)).version, '1.5.0');
  } finally { await rm(root, { recursive: true, force: true }); }
});

// The app carries the runtime files only: package.json and its lock pin the
// Pi release, which the first run installs.
async function writeRuntimeFiles(directory, version) {
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, 'package.json'), JSON.stringify({ dependencies: { [packageName]: version } }));
  await writeFile(path.join(directory, 'package-lock.json'), JSON.stringify({ packages: { '': { dependencies: { [packageName]: version } } } }));
}

test('with no Pi beside the runtime files, nothing is installed and the pinned release is the base', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'pi-first-run-'));
  const bundled = path.join(root, 'runtime');
  await writeRuntimeFiles(bundled, '1.5.0');
  try {
    assert.equal(await pinnedVersion(bundled), '1.5.0');
    const none = await currentRuntime(path.join(root, 'managed'), bundled);
    assert.deepEqual(none, { version: '1.5.0', cli: null, managed: false, installed: false });
    await writeFile(path.join(bundled, 'package.json'), JSON.stringify({ dependencies: { [packageName]: '^1.5.0' } }));
    await assert.rejects(pinnedVersion(bundled), /pin a stable Pi release/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('the first run installs the pinned release from the runtime files, not from the network', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'pi-install-pinned-'));
  const bundled = path.join(root, 'runtime');
  const managed = path.join(root, 'managed');
  await writeRuntimeFiles(bundled, '1.5.0');
  const commands = [];
  const runner = async (command, args) => {
    commands.push(args);
    if (args.includes('ci')) await installFixture(args[args.indexOf('--prefix') + 1], '1.5.0');
  };
  try {
    const installed = await installPinned(managed, {
      bundled, runner, fetcher: async () => { throw new Error('must not reach the network for the lock'); },
    });
    assert.equal(installed.installed, true);
    assert.equal(installed.managed, true);
    assert.equal(installed.version, '1.5.0');
    assert.ok(installed.cli.endsWith(path.join('releases', '1.5.0', 'node_modules', ...packageName.split('/'), 'dist', 'bundle', 'cli.js')));
    assert.ok(commands.some((args) => args.includes('ci') && args.includes('--ignore-scripts') && args.includes('--omit=dev')));
    // Again: already there, nothing run.
    commands.length = 0;
    assert.equal((await installPinned(managed, { bundled, runner })).version, '1.5.0');
    assert.deepEqual(commands, []);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a lock that does not pin the release is refused before npm runs', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'pi-install-mismatch-'));
  const bundled = path.join(root, 'runtime');
  await writeRuntimeFiles(bundled, '1.5.0');
  await writeFile(path.join(bundled, 'package-lock.json'), JSON.stringify({ packages: { '': { dependencies: { [packageName]: '1.4.0' } } } }));
  try {
    await assert.rejects(installPinned(path.join(root, 'managed'), { bundled, runner: async () => { throw new Error('must not run npm'); } }), /does not pin/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('npm is the one beside the node that runs, else the one on the PATH', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'pi-npm-'));
  try {
    const cli = path.join(root, 'node-v24', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js');
    await mkdir(path.dirname(cli), { recursive: true });
    await writeFile(cli, '');
    const node = path.join(root, 'node-v24', 'bin', 'node');
    const beside = npmCommand(['ci'], { bundled: root, env: {}, execPath: node });
    assert.equal(beside.command, node);
    assert.equal(beside.args.length, 2);
    assert.ok(beside.args[0].endsWith(path.join('npm', 'bin', 'npm-cli.js')));
    assert.equal(beside.args[1], 'ci');
    const named = npmCommand(['ci'], { bundled: root, env: { PI_DESKTOP_NPM_CLI: cli }, execPath: '/nowhere/node' });
    assert.deepEqual(named.args, [cli, 'ci']);
    const none = npmCommand(['ci'], { bundled: root, env: {}, execPath: '/nowhere/bin/node' });
    assert.equal(none.command, 'npm');
    assert.deepEqual(none.args, ['ci']);
  } finally { await rm(root, { recursive: true, force: true }); }
});
