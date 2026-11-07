import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { compareVersions, currentRuntime, installRelease, latestRelease } from '../runtime-manager.mjs';

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
    if (args[1] === 'ci') {
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
