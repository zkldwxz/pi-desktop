import 'dart:convert';
import 'dart:io';

import 'package:pi_remote/client.dart' show SshLauncher, SshTarget, findSsh;

import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import 'pi_storage.dart';

/// Runs the fixed helper on [host], with its JSON request on stdin.
/// Replaceable to support a host's SSH configuration or tests.
typedef PiRemoteCatalogRunner = Future<String> Function(
  String host,
  Map<String, Object?> request,
);

/// PI sessions on this machine and in remote projects opened in the app.
class PiRemoteCatalog implements SessionCatalog {
  PiRemoteCatalog({this.local = const PiStorage(), PiRemoteCatalogRunner? run})
    : _run = run ?? _runSsh;

  final SessionCatalog local;
  final PiRemoteCatalogRunner _run;
  final Map<String, Set<String>> _hosts = {};

  @override
  Future<List<ProjectRecord>> projects() => local.projects();

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final host = RemoteLocation.hostOf(cwd);
    if (host == null) return local.sessionsIn(cwd);
    final response = jsonDecode(
      await _run(host, {'op': 'list', 'cwd': RemoteLocation.pathOf(cwd)}),
    );
    if (response is! List) throw const FormatException('Invalid PI catalog');
    final records = <SessionRecord>[];
    for (final item in response) {
      if (item is! Map ||
          item['id'] is! String ||
          item['title'] is! String ||
          item['cwd'] is! String ||
          item['path'] is! String ||
          item['updatedAt'] is! num) {
        throw const FormatException('Invalid PI session record');
      }
      final id = item['id'] as String;
      records.add(
        SessionRecord(
          id: id,
          title: item['title'] as String,
          cwd: RemoteLocation.of(host, item['cwd'] as String),
          path: item['path'] as String,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (item['updatedAt'] as num).toInt(),
          ),
        ),
      );
      (_hosts[id] ??= {}).add(host);
    }
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return records;
  }

  @override
  Future<void> delete(String id) async {
    final hosts = _hosts[id];
    if (hosts == null || hosts.isEmpty) return local.delete(id);
    if (hosts.length != 1) {
      throw StateError('PI session ID occurs on more than one host');
    }
    await _run(hosts.single, {'op': 'delete', 'id': id});
    _hosts.remove(id);
  }
}

Future<String> _runSsh(String host, Map<String, Object?> request) async {
  if (!SshTarget.isValid(host)) throw ArgumentError.value(host, 'host');
  final target = SshTarget.parse(host);
  final encoded = base64.encode(utf8.encode(_helper));
  final command =
      'node -e "eval(Buffer.from(\'$encoded\',\'base64\').toString())"';
  final distro = target.wslDistro;
  final executable = distro == null
      ? findSsh(Platform.environment) ?? 'ssh'
      : 'wsl.exe';
  final arguments = distro == null
      ? [...SshLauncher.defaultOptions, ...target.arguments, command]
      : SshLauncher.wslArguments(distro, command);
  final process = await Process.start(executable, arguments);
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  process.stdin.write(jsonEncode(request));
  await process.stdin.close();
  final code = await process.exitCode.timeout(
    const Duration(minutes: 2),
    onTimeout: () {
      process.kill();
      throw StateError('Remote PI catalog timed out');
    },
  );
  final output = await stdout;
  final error = await stderr;
  if (code != 0) throw StateError('Remote PI catalog failed ($code): $error');
  return output;
}

// Static source only: host, paths, and IDs never enter a shell command.
const _helper = r'''
const fs = require('fs');
const os = require('os');
const path = require('path');
const root = path.join(os.homedir(), '.pi-desktop', 'pi-agent', 'sessions');
function canonical(p) {
  try { p = fs.realpathSync(p); } catch (_) { p = path.resolve(p); }
  return process.platform === 'win32' ? p.toLowerCase() : p;
}
function files(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, {withFileTypes: true}); }
  catch (e) { if (e.code === 'ENOENT') return []; throw e; }
  const result = [];
  for (const entry of entries) {
    const name = path.join(dir, entry.name);
    if (entry.isDirectory()) result.push(...files(name));
    else if (entry.isFile() && name.endsWith('.jsonl')) result.push(name);
  }
  return result;
}
function record(file) {
  let lines, stat;
  try { lines = fs.readFileSync(file, 'utf8').split(/\r?\n/); stat = fs.statSync(file); }
  catch (e) { if (e.code === 'ENOENT') return null; throw e; }
  let id, cwd, title, named = false;
  for (const line of lines) {
    let item;
    try { item = JSON.parse(line); } catch (_) { continue; }
    if (!item || typeof item !== 'object') continue;
    if (item.type === 'session') { id = item.id; cwd = item.cwd; }
    else if (item.type === 'session_info' && typeof item.name === 'string') {
      title = item.name; named = true;
    } else if (!named && title == null && item.type === 'message' && item.message?.role === 'user') {
      const content = item.message.content;
      title = typeof content === 'string' ? content : Array.isArray(content)
        ? content.filter(b => b && b.type === 'text').map(b => b.text).join('\n') : '';
    }
  }
  if (typeof id !== 'string' || typeof cwd !== 'string') return null;
  title = (title || '').replace(/\s+/g, ' ').trim();
  if (title.length > 160) title = title.substring(0, 157) + '...';
  return {id, cwd, title, path: file, updatedAt: stat.mtimeMs};
}
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  try {
    const request = JSON.parse(input);
    if (request.op === 'list' && typeof request.cwd === 'string') {
      const cwd = canonical(request.cwd);
      const records = files(root).map(record).filter(r => r && canonical(r.cwd) === cwd);
      records.sort ( (a, b) => b.updatedAt - a.updatedAt );
      process.stdout.write(JSON.stringify(records));
    } else if (request.op === 'delete' && typeof request.id === 'string') {
      for (const file of files(root)) {
        if (record(file)?.id === request.id) fs.unlinkSync(file);
      }
      process.stdout.write('null');
    } else throw new Error('Invalid request');
  } catch (e) { console.error(String(e)); process.exitCode = 1; }
});
''';
