import 'dart:convert';

import 'package:pi_remote/files.dart'
    show IdeFileExistsException, IdeFileNotFoundException;
import 'package:path/path.dart' as p;

import 'customization_disk.dart';
import 'customizations.dart';

/// Pi's customizations on a [CustomizationDisk] (this machine's, or a
/// remote host's): the user's under Pi's agent folder, a project's under
/// `<project>/.pi` and the project's root (`AGENTS.md`).
///
/// What is listed is what Pi itself loads (see Pi's docs, Configuration):
/// skills (`skills/<name>/SKILL.md`), prompt templates (`prompts/*.md`,
/// typed as `/name`), the instruction files (`AGENTS.md`, `CLAUDE.md`,
/// `SYSTEM.md`, `APPEND_SYSTEM.md`), MCP servers (`mcp.json`) and the Pi
/// packages declared in `settings.json`.
class CustomizationStore {
  CustomizationStore({this.configDir, CustomizationDisk? disk})
    : _disk = disk ?? CustomizationDisk.local;

  /// Pi's project folder.
  static const _projectConfig = '.pi';

  /// The files Pi reads as instructions beside a project's or the user's
  /// own, in the order it prefers them.
  static const contextFiles = [
    'AGENTS.override.md',
    'AGENTS.md',
    'AGENTS.MD',
    'CLAUDE.md',
    'CLAUDE.MD',
  ];

  /// The files that replace or add to its system prompt.
  static const systemFiles = ['SYSTEM.md', 'APPEND_SYSTEM.md'];

  /// Pi's agent folder; by default as the disk's finds it.
  final String? configDir;

  final CustomizationDisk? _disk;

  CustomizationDisk get _files =>
      _disk ?? (throw UnsupportedError('No files on the web'));

  p.Context get _paths => _files.paths;

  /// Whether there are files to read and write here (not on the web).
  bool get supported => _disk != null;

  /// Whether the files are this machine's (not a remote host's): shown in
  /// its file manager, opened in its IDE.
  bool get isLocal => _disk?.isLocal ?? true;

  /// How paths are spelled where the files are.
  p.Context get paths => _disk == null ? p.context : _paths;

  Future<String> config() async => configDir ?? await _files.configDir();

  /// Those of [kind], the user's and [project]'s (none of a project's when
  /// null), by scope then name.
  Future<List<Customization>> list(
    CustomizationKind kind, {
    String? project,
  }) async {
    if (!supported) return const [];
    final config = await this.config();
    final dotPi = project == null ? null : _paths.join(project, _projectConfig);
    final items = switch (kind) {
      CustomizationKind.skills => [
        ...await _skills(
          CustomizationScope.user,
          _paths.join(config, 'skills'),
        ),
        if (dotPi != null)
          ...await _skills(
            CustomizationScope.project,
            _paths.join(dotPi, 'skills'),
          ),
      ],
      CustomizationKind.commands => [
        ...await _markdown(
          kind,
          CustomizationScope.user,
          _paths.join(config, 'prompts'),
        ),
        if (dotPi != null)
          ...await _markdown(
            kind,
            CustomizationScope.project,
            _paths.join(dotPi, 'prompts'),
          ),
      ],
      CustomizationKind.rules => await _rules(config, project),
      CustomizationKind.mcps => await _servers(config, project),
      CustomizationKind.plugins => await _plugins(config, project),
    };
    // A copy: what a kind has none of may be a const list.
    return [...items]..sort((a, b) {
      final scope = a.scope.index.compareTo(b.scope.index);
      return scope != 0
          ? scope
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  /// The file of the `/command` [name] as Pi lists it: a skill's SKILL.md
  /// (typed `/skill:name`) or a prompt template's markdown, the user's or
  /// [project]'s; null for none (one built in).
  Future<String?> commandFile(String name, {String? project}) async {
    if (!supported) return null;
    final skill = name.startsWith('skill:') ? name.substring(6) : name;
    for (final item in await list(CustomizationKind.skills, project: project)) {
      if (item.name == skill ||
          _paths.basename(_paths.dirname(item.path)) == skill) {
        return item.path;
      }
    }
    for (final command in await list(
      CustomizationKind.commands,
      project: project,
    )) {
      if (command.name == '/$name') return command.path;
    }
    return null;
  }

  Future<String> read(String path) async =>
      await _files.read(path) ?? (throw IdeFileNotFoundException(path));

  Future<bool> exists(String path) async =>
      await _files.isDirectory(path) == false;

  Future<void> write(String path, String text) => _files.write(path, text);

  /// Makes a new one of [kind] named [name] from its template: the user's,
  /// or [project]'s. Returns its file; throws an [IdeFileExistsException]
  /// when one by that name is there already. Of the rules there is the one
  /// to make, `AGENTS.md`, whatever the name.
  Future<String> create(
    CustomizationKind kind,
    CustomizationScope scope,
    String name, {
    String? project,
  }) async {
    if (!kind.creatable ||
        (kind != CustomizationKind.rules && !isCustomizationName(name))) {
      throw ArgumentError.value(name, 'name');
    }
    final config = await this.config();
    final base = scope == CustomizationScope.user
        ? config
        : _paths.join(project!, _projectConfig);
    final path = switch (kind) {
      CustomizationKind.skills => _paths.join(base, 'skills', name, 'SKILL.md'),
      CustomizationKind.commands => _paths.join(base, 'prompts', '$name.md'),
      // Beside the project's folder: its root, as Pi reads it.
      _ => _paths.join(
        scope == CustomizationScope.user ? config : project!,
        'AGENTS.md',
      ),
    };
    final taken = kind == CustomizationKind.skills
        ? await _files.isDirectory(_paths.dirname(path)) != null
        : await _files.isDirectory(path) != null;
    if (taken) throw IdeFileExistsException(path);
    await write(path, template(kind, name));
    return path;
  }

  /// The file [kind] is kept in for [scope], to be edited whole (see
  /// [CustomizationKind.configuredIn]): Pi's `mcp.json`. Null where there
  /// is none (or no [project]).
  Future<String?> configFile(
    CustomizationKind kind,
    CustomizationScope scope, {
    String? project,
  }) async {
    if (!supported || !kind.configuredIn(scope)) return null;
    if (kind != CustomizationKind.mcps) return null;
    return _mcpFile(await config(), scope, project);
  }

  String? _mcpFile(String config, CustomizationScope scope, String? project) =>
      switch (scope) {
        CustomizationScope.user => _paths.join(config, 'mcp.json'),
        CustomizationScope.project =>
          project == null
              ? null
              : _paths.join(project, _projectConfig, 'mcp.json'),
      };

  /// Removes [item]'s file, or its folder (a skill's).
  Future<void> delete(Customization item) async {
    final path = item.removePath;
    if (path == null) return;
    await _files.delete(path);
  }

  // --- Reading ---------------------------------------------------------------

  Future<Map<String, Object?>?> _json(String path) async {
    final text = await _files.read(path);
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      return json is Map<String, Object?> ? json : null;
    } on Object {
      return null;
    }
  }

  static const _pretty = JsonEncoder.withIndent('  ');

  /// Each folder of [root] with a SKILL.md.
  Future<List<Customization>> _skills(
    CustomizationScope scope,
    String root,
  ) async {
    final skills = <Customization>[];
    for (final child in await _files.children(root)) {
      if (!child.directory || _paths.basename(child.path).startsWith('.')) {
        continue;
      }
      final path = _paths.join(child.path, 'SKILL.md');
      final text = await _files.read(path);
      if (text == null) continue;
      skills.add(
        Customization(
          kind: CustomizationKind.skills,
          scope: scope,
          name: switch (parseFrontMatter(text)['name']) {
            final name? when name.isNotEmpty => name,
            _ => _paths.basename(child.path),
          },
          description: describeMarkdown(text),
          path: path,
          removePath: child.path,
        ),
      );
    }
    return skills;
  }

  /// How deep [_markdown] goes: links may loop.
  static const _deepest = 8;

  /// The markdown files under [root], its folders' too.
  Future<List<Customization>> _markdown(
    CustomizationKind kind,
    CustomizationScope scope,
    String root,
  ) async {
    final found = <Customization>[];
    Future<void> walk(String dir, int depth) async {
      for (final child in await _files.children(dir)) {
        if (child.directory) {
          if (depth < _deepest) await walk(child.path, depth + 1);
        } else if (child.path.endsWith('.md')) {
          if (await _files.read(child.path) case final text?) {
            found.add(
              Customization(
                kind: kind,
                scope: scope,
                // A command as it is typed.
                name: '/${_paths.basenameWithoutExtension(child.path)}',
                description: describeMarkdown(text),
                path: child.path,
                removePath: child.path,
              ),
            );
          }
        }
      }
    }

    await walk(root, 0);
    return found;
  }

  /// The instruction files Pi reads: the agent folder's (`AGENTS.md` or
  /// `CLAUDE.md`, `SYSTEM.md`, `APPEND_SYSTEM.md`), the project's root's and
  /// its `.pi` folder's.
  Future<List<Customization>> _rules(String config, String? project) async {
    Future<List<Customization>> files(
      CustomizationScope scope,
      String dir,
      List<String> names,
    ) async {
      final found = <Customization>[];
      for (final child in await _files.children(dir)) {
        final name = _paths.basename(child.path);
        if (child.directory || !names.contains(name)) continue;
        final text = await _files.read(child.path);
        if (text == null) continue;
        found.add(
          Customization(
            kind: CustomizationKind.rules,
            scope: scope,
            name: name,
            description: describeMarkdown(text),
            path: child.path,
          ),
        );
      }
      return found;
    }

    return [
      ...await files(CustomizationScope.user, config, [
        ...contextFiles,
        ...systemFiles,
      ]),
      if (project != null) ...[
        ...await files(CustomizationScope.project, project, contextFiles),
        ...await files(
          CustomizationScope.project,
          _paths.join(project, _projectConfig),
          systemFiles,
        ),
      ],
    ];
  }

  /// The MCP servers: those of the user's `mcp.json` and the project's
  /// `.pi/mcp.json`.
  Future<List<Customization>> _servers(String config, String? project) async {
    Future<List<Customization>> servers(
      CustomizationScope scope,
      String? path,
    ) async {
      if (path == null) return const [];
      final entries = (await _json(path))?['mcpServers'];
      return [
        if (entries is Map<String, Object?>)
          for (final MapEntry(key: name, value: server) in entries.entries)
            Customization(
              kind: CustomizationKind.mcps,
              scope: scope,
              name: name,
              description: _describeServer(server),
              path: path,
              detail: _pretty.convert({name: server}),
              server: server is Map<String, Object?> ? server : null,
              enabled:
                  server is Map<String, Object?> && server['enabled'] == false
                  ? false
                  : null,
            ),
      ];
    }

    return [
      ...await servers(
        CustomizationScope.user,
        _mcpFile(config, CustomizationScope.user, project),
      ),
      ...await servers(
        CustomizationScope.project,
        _mcpFile(config, CustomizationScope.project, project),
      ),
    ];
  }

  /// `command args…`, or the URL a remote server is at.
  static String _describeServer(Object? server) {
    if (server is! Map<String, Object?>) return '';
    if (server['description'] case final String description
        when description.isNotEmpty) {
      return description;
    }
    if (server['url'] case final String url) {
      return switch (server['type']) {
        final String type => '$type · $url',
        _ => url,
      };
    }
    return [
      if (server['command'] case final String command) command,
      if (server['args'] case final List<Object?> args)
        for (final arg in args) '$arg',
    ].join(' ');
  }

  /// The Pi packages declared in `settings.json` (the user's) and
  /// `.pi/settings.json` (the project's): each entry a source string, or an
  /// object with a `source`.
  Future<List<Customization>> _plugins(String config, String? project) async {
    Future<List<Customization>> declared(
      CustomizationScope scope,
      String path,
    ) async {
      final entries = (await _json(path))?['packages'];
      if (entries is! List<Object?>) return const [];
      final found = <Customization>[];
      for (final entry in entries) {
        final source = switch (entry) {
          final String source => source,
          final Map<String, Object?> entry when entry['source'] is String =>
            entry['source'] as String,
          _ => null,
        };
        if (source == null || source.isEmpty) continue;
        found.add(await _plugin(config, scope, path, source, entry));
      }
      return found;
    }

    return [
      ...await declared(
        CustomizationScope.user,
        _paths.join(config, 'settings.json'),
      ),
      if (project != null)
        ...await declared(
          CustomizationScope.project,
          _paths.join(project, _projectConfig, 'settings.json'),
        ),
    ];
  }

  Future<Customization> _plugin(
    String config,
    CustomizationScope scope,
    String settings,
    String source,
    Object? entry,
  ) async {
    final name = packageName(source);
    // What Pi installed under its npm folder tells what it is.
    Map<String, Object?>? manifest;
    if (source.startsWith('npm:')) {
      manifest = await _json(
        _paths.join(config, 'npm', 'node_modules', name, 'package.json'),
      );
    }
    final version = manifest?['version'];
    return Customization(
      kind: CustomizationKind.plugins,
      scope: scope,
      name: name,
      description: switch (manifest?['description']) {
        final String description when description.isNotEmpty => description,
        _ => source,
      },
      path: settings,
      editable: false,
      detail: _pretty.convert({
        'source': source,
        'version': ?version,
        if (entry is Map<String, Object?>)
          for (final MapEntry(:key, :value) in entry.entries)
            if (key != 'source') key: value,
      }),
      source: source,
    );
  }

  /// A package's name as Pi's settings spell its [source]: `npm:@a/b@1.0`
  /// is `@a/b`, `git:github.com/a/b@v1` is `a/b`, a path its folder's name.
  static String packageName(String source) {
    String unversioned(String text) {
      final at = text.lastIndexOf('@');
      return at > 0 ? text.substring(0, at) : text;
    }

    if (source.startsWith('npm:')) return unversioned(source.substring(4));
    if (source.startsWith('git:') ||
        source.startsWith('http://') ||
        source.startsWith('https://') ||
        source.startsWith('ssh://')) {
      final repo = unversioned(
        source.replaceFirst(RegExp(r'^[a-z]+:(//)?'), ''),
      ).replaceFirst(RegExp(r'\.git$'), '');
      final parts = repo.split('/').where((part) => part.isNotEmpty).toList();
      return parts.length >= 2
          ? parts.sublist(parts.length - 2).join('/')
          : repo;
    }
    final trimmed = source.replaceAll(RegExp(r'[\\/]+$'), '');
    final cut = trimmed.lastIndexOf(RegExp(r'[\\/]'));
    return cut < 0 ? trimmed : trimmed.substring(cut + 1);
  }
}
