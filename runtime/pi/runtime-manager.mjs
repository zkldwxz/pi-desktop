import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { access, copyFile, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const releaseApi = 'https://pi.dev/api/latest-version';
const installerApi = 'https://pi.dev/api/installer/releases';
const packageName = '@earendil-works/pi-coding-agent';
const stable = /^\d+\.\d+\.\d+$/;
const runtime = path.dirname(fileURLToPath(import.meta.url));
const relativeCli = path.join('node_modules', ...packageName.split('/'), 'dist', 'bundle', 'cli.js');

export function compareVersions(a, b) {
  if (!stable.test(a) || !stable.test(b)) throw new Error('Expected a stable Pi version');
  const left = a.split('.').map(Number);
  const right = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (left[i] !== right[i]) return Math.sign(left[i] - right[i]);
  return 0;
}

// The Pi release this app is made for: what its package.json pins. The app
// carries no copy of Pi; the first run installs this release (`install`).
export async function pinnedVersion(bundled = runtime) {
  const manifest = JSON.parse(await readFile(path.join(bundled, 'package.json'), 'utf8'));
  const version = manifest.dependencies?.[packageName];
  if (!stable.test(version ?? '')) throw new Error('The runtime does not pin a stable Pi release');
  return version;
}

// A Pi installed beside the runtime files: a checkout's `npm ci --prefix
// runtime/pi`, or an older bundle. Null where there is none.
async function bundledInstall(bundled) {
  try {
    const manifest = JSON.parse(await readFile(path.join(bundled, 'node_modules', ...packageName.split('/'), 'package.json'), 'utf8'));
    const cli = path.join(bundled, relativeCli);
    await access(cli);
    return { version: manifest.version, cli };
  } catch {
    return null;
  }
}

export async function currentRuntime(root, bundled = runtime) {
  const base = await bundledInstall(bundled);
  const baseVersion = base?.version ?? await pinnedVersion(bundled);
  let version;
  try {
    version = (await readFile(path.join(root, 'current-version'), 'utf8')).trim();
    if (!stable.test(version) || compareVersions(version, baseVersion) < 0) throw new Error('Invalid or older active runtime version');
    const directory = path.join(root, 'releases', version);
    const manifest = JSON.parse(await readFile(path.join(directory, 'node_modules', ...packageName.split('/'), 'package.json'), 'utf8'));
    if (manifest.name !== packageName || manifest.version !== version) throw new Error('Incomplete Pi install');
    const cli = path.join(directory, relativeCli);
    await access(cli);
    return { version, cli, managed: true, installed: true };
  } catch {
    return { version: baseVersion, cli: base?.cli ?? null, managed: false, installed: base !== null };
  }
}

export async function latestRelease(fetcher = fetch) {
  const response = await fetcher(releaseApi, { signal: AbortSignal.timeout(15000), headers: { accept: 'application/json' } });
  if (!response.ok) throw new Error(`Pi version check returned HTTP ${response.status}`);
  const release = await response.json();
  if (release.packageName !== packageName || !stable.test(release.version ?? '')) throw new Error('Unexpected official Pi release');
  return { version: release.version, packageName, note: typeof release.note === 'string' ? release.note : undefined };
}

async function run(command, args, options = {}) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, { ...options, stdio: ['ignore', 'pipe', 'pipe'] });
    let diagnostic = '';
    for (const stream of [child.stdout, child.stderr]) stream.on('data', (chunk) => {
      diagnostic = `${diagnostic}${chunk}`.slice(-4000);
    });
    child.once('error', reject);
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`Pi install failed (${code}): ${diagnostic}`)));
  });
}

// npm, as the node that runs this has it: named by PI_DESKTOP_NPM_CLI, beside
// the runtime files, or in the Node folder the app downloaded; else the
// `npm` on the PATH.
export function npmCommand(rest, { bundled = runtime, env = process.env, execPath = process.execPath } = {}) {
  const beside = path.dirname(execPath);
  const candidates = [
    env.PI_DESKTOP_NPM_CLI,
    path.join(bundled, 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    path.join(beside, 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    path.join(beside, '..', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js'),
  ].filter(Boolean);
  const cli = candidates.find((candidate) => existsSync(candidate));
  return cli
    ? { command: execPath, args: [cli, ...rest], options: {} }
    : { command: 'npm', args: rest, options: { shell: process.platform === 'win32' } };
}

// Install a release as `pi update`'s managed installer does: its complete
// dependency lock, from pi.dev (`source: 'official'`) or, for the release the
// app is made for, from the runtime files (`source: 'bundled'`). Only user
// data is written, never a signed .app or a global npm installation. Running
// sessions keep their previous release.
export async function installRelease(root, release, { fetcher = fetch, runner = run, bundled = runtime, source = 'official' } = {}) {
  if (release.packageName !== packageName || !stable.test(release.version)) throw new Error('Invalid Pi release');
  await mkdir(root, { recursive: true });
  const lock = path.join(root, 'desktop-update.lock');
  await mkdir(lock).catch(() => { throw new Error('Another Pi runtime update is in progress'); });
  let stage;
  try {
    await mkdir(path.join(root, 'releases'), { recursive: true });
    stage = await mkdtemp(path.join(root, 'install-'));
    for (const name of ['package.json', 'package-lock.json']) {
      let text;
      if (source === 'bundled') {
        await copyFile(path.join(bundled, name), path.join(stage, name));
        text = await readFile(path.join(stage, name), 'utf8');
      } else {
        const response = await fetcher(`${installerApi}/${release.version}/${name}`, { signal: AbortSignal.timeout(20000) });
        if (!response.ok) throw new Error(`Official Pi ${name} returned HTTP ${response.status}`);
        text = await response.text();
        await writeFile(path.join(stage, name), text, { mode: 0o600 });
      }
      const parsed = JSON.parse(text);
      const dependencies = name === 'package.json' ? parsed.dependencies : parsed.packages?.['']?.dependencies;
      if (dependencies?.[packageName] !== release.version) throw new Error(`${name} does not pin the selected Pi release`);
    }
    const npm = npmCommand(['ci', '--prefix', stage, '--ignore-scripts', '--omit=dev', '--include=optional',
      '--no-audit', '--no-fund', '--progress=false'], { bundled });
    await runner(npm.command, npm.args, { cwd: root, ...npm.options });
    const cli = path.join(stage, relativeCli);
    const manifest = JSON.parse(await readFile(path.join(stage, 'node_modules', ...packageName.split('/'), 'package.json'), 'utf8'));
    if (manifest.version !== release.version || manifest.name !== packageName) throw new Error('Installed Pi version differs from the release');
    await runner(process.execPath, [cli, '--version'], { cwd: root });
    const destination = path.join(root, 'releases', release.version);
    // Leave previously installed releases untouched. Verify before activation.
    try {
      await rename(stage, destination);
      stage = undefined;
    } catch (error) {
      if (!['EEXIST', 'ENOTEMPTY'].includes(error.code)) throw error;
      const installed = JSON.parse(await readFile(path.join(destination, 'node_modules', ...packageName.split('/'), 'package.json'), 'utf8'));
      if (installed.version !== release.version || installed.name !== packageName) throw new Error('Existing Pi release is incomplete');
      await runner(process.execPath, [path.join(destination, relativeCli), '--version'], { cwd: root });
    }
    const pointer = path.join(root, `current-version.${process.pid}.tmp`);
    await writeFile(pointer, `${release.version}\n`, { mode: 0o600 });
    await rename(pointer, path.join(root, 'current-version'));
    return currentRuntime(root, bundled);
  } finally {
    if (stage) await rm(stage, { recursive: true, force: true });
    await rm(lock, { recursive: true, force: true });
  }
}

// The release the app is made for, if none is installed yet.
export async function installPinned(root, options = {}) {
  const bundled = options.bundled ?? runtime;
  const current = await currentRuntime(root, bundled);
  if (current.installed) return current;
  return installRelease(root, { version: await pinnedVersion(bundled), packageName }, { ...options, source: 'bundled' });
}

async function main() {
  const [command, root] = process.argv.slice(2);
  if (!['status', 'check', 'update', 'install'].includes(command) || !root || !path.isAbsolute(root)) throw new Error('Expected status|check|update|install ABSOLUTE_RUNTIME_DIRECTORY');
  let current = await currentRuntime(root);
  if (command === 'status') return current;
  if (command === 'install') return installPinned(root);
  if (command === 'update' && !current.installed) current = await installPinned(root);
  const latest = await latestRelease();
  if (command === 'update' && compareVersions(latest.version, current.version) > 0) current = await installRelease(root, latest);
  return { ...current, latest: latest.version, source: releaseApi };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((result) => process.stdout.write(`${JSON.stringify(result)}\n`))
    .catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
