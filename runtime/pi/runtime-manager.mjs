import { spawn } from 'node:child_process';
import { access, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
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

export async function currentRuntime(root, bundled = runtime) {
  const base = JSON.parse(await readFile(path.join(bundled, 'node_modules', ...packageName.split('/'), 'package.json'), 'utf8'));
  let version;
  try {
    version = (await readFile(path.join(root, 'current-version'), 'utf8')).trim();
    if (!stable.test(version) || compareVersions(version, base.version) < 0) throw new Error('Invalid or older active runtime version');
    const directory = path.join(root, 'releases', version);
    const manifest = JSON.parse(await readFile(path.join(directory, 'node_modules', ...packageName.split('/'), 'package.json'), 'utf8'));
    if (manifest.name !== packageName || manifest.version !== version) throw new Error('Incomplete Pi update');
    const cli = path.join(directory, relativeCli);
    await access(cli);
    return { version, cli, managed: true };
  } catch {
    return { version: base.version, cli: path.join(bundled, relativeCli), managed: false };
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

// Use the same official release manifest and complete dependency lock as `pi
// update`'s managed installer. Update only user data, never a signed .app or a
// global npm installation. Running sessions keep their previous release.
export async function installRelease(root, release, { fetcher = fetch, runner = run, bundled = runtime } = {}) {
  if (release.packageName !== packageName || !stable.test(release.version)) throw new Error('Invalid Pi release');
  await mkdir(root, { recursive: true });
  const lock = path.join(root, 'desktop-update.lock');
  await mkdir(lock).catch(() => { throw new Error('Another Pi runtime update is in progress'); });
  let stage;
  try {
    await mkdir(path.join(root, 'releases'), { recursive: true });
    stage = await mkdtemp(path.join(root, 'install-'));
    for (const name of ['package.json', 'package-lock.json']) {
      const response = await fetcher(`${installerApi}/${release.version}/${name}`, { signal: AbortSignal.timeout(20000) });
      if (!response.ok) throw new Error(`Official Pi ${name} returned HTTP ${response.status}`);
      const text = await response.text();
      const parsed = JSON.parse(text);
      const dependencies = name === 'package.json' ? parsed.dependencies : parsed.packages?.['']?.dependencies;
      if (dependencies?.[packageName] !== release.version) throw new Error(`Official ${name} does not pin the selected Pi release`);
      await writeFile(path.join(stage, name), text, { mode: 0o600 });
    }
    const npm = path.join(bundled, 'node_modules', 'npm', 'bin', 'npm-cli.js');
    await runner(process.execPath, [npm, 'ci', '--prefix', stage, '--ignore-scripts', '--omit=dev', '--include=optional',
      '--no-audit', '--no-fund', '--progress=false'], { cwd: root });
    const cli = path.join(stage, relativeCli);
    const manifest = JSON.parse(await readFile(path.join(stage, 'node_modules', ...packageName.split('/'), 'package.json'), 'utf8'));
    if (manifest.version !== release.version || manifest.name !== packageName) throw new Error('Installed Pi version differs from the official release');
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

async function main() {
  const [command, root] = process.argv.slice(2);
  if (!['status', 'check', 'update'].includes(command) || !root || !path.isAbsolute(root)) throw new Error('Expected status|check|update ABSOLUTE_RUNTIME_DIRECTORY');
  let current = await currentRuntime(root);
  if (command === 'status') return current;
  const latest = await latestRelease();
  if (command === 'update' && compareVersions(latest.version, current.version) > 0) current = await installRelease(root, latest);
  return { ...current, latest: latest.version, source: releaseApi };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((result) => process.stdout.write(`${JSON.stringify(result)}\n`))
    .catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
