import 'dart:convert';
import 'dart:io';

import 'package:pi_remote/files.dart' show IdeFileExistsException;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:pi_desktop/customize/customization_store.dart';
import 'package:pi_desktop/customize/customizations.dart';

void main() {
  late Directory temp;
  late String config;
  late String project;
  late CustomizationStore store;

  void write(String path, String text) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('customize');
    config = p.join(temp.path, 'pi-agent');
    project = p.join(temp.path, 'app');
    store = CustomizationStore(configDir: config);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('reads front matter, block scalars and quotes included', () {
    const text =
        '---\n'
        'name: "pdf"\n'
        'description: >-\n'
        '  Reads PDFs\n'
        '  and fills forms.\n'
        'tools: Read\n'
        '---\n'
        '\n'
        '# PDF\n';
    expect(parseFrontMatter(text), {
      'name': 'pdf',
      'description': 'Reads PDFs and fills forms.',
      'tools': 'Read',
    });
    expect(describeMarkdown('# Title\n\nFirst line.\n'), 'First line.');
    expect(bodyOf(text), '\n# PDF\n');
  });

  test('lists the skills of the agent folder and the project\'s .pi, '
      'not Claude Code\'s', () async {
    write(
      p.join(config, 'skills', 'pdf-tools', 'SKILL.md'),
      '---\nname: pdf\ndescription: Reads PDFs\n---\n',
    );
    write(p.join(config, 'skills', 'no-skill-file', 'notes.md'), 'x');
    write(
      p.join(project, '.pi', 'skills', 'ship', 'SKILL.md'),
      '---\nname: ship\n---\nShips.\n',
    );
    write(
      p.join(project, '.claude', 'skills', 'old', 'SKILL.md'),
      '---\nname: old\n---\n',
    );
    final skills = await store.list(CustomizationKind.skills, project: project);
    expect(
      [for (final s in skills) (s.scope, s.name, s.description)],
      [
        (CustomizationScope.user, 'pdf', 'Reads PDFs'),
        (CustomizationScope.project, 'ship', 'Ships.'),
      ],
    );
    expect(skills.first.removePath, p.join(config, 'skills', 'pdf-tools'));
  });

  test('lists the prompt templates as /commands', () async {
    write(
      p.join(config, 'prompts', 'review.md'),
      '---\ndescription: Review the code\n---\nReview \$ARGUMENTS.\n',
    );
    write(p.join(project, '.pi', 'prompts', 'ship.md'), 'Ship it.\n');
    final commands = await store.list(
      CustomizationKind.commands,
      project: project,
    );
    expect(
      [for (final c in commands) (c.scope, c.name, c.description)],
      [
        (CustomizationScope.user, '/review', 'Review the code'),
        (CustomizationScope.project, '/ship', 'Ship it.'),
      ],
    );
  });

  test('finds a /command\'s file: a skill\'s (as /skill:name) or a '
      'prompt template\'s', () async {
    final skill = p.join(config, 'skills', 'pdf-tools', 'SKILL.md');
    write(skill, '---\nname: pdf\ndescription: Reads PDFs\n---\n');
    final command = p.join(project, '.pi', 'prompts', 'ship.md');
    write(command, 'Ship it.\n');
    expect(await store.commandFile('skill:pdf'), skill);
    expect(await store.commandFile('pdf-tools'), skill);
    expect(await store.commandFile('ship', project: project), command);
    expect(await store.commandFile('ship'), isNull);
    expect(await store.commandFile('compact'), isNull);
    expect(await store.commandFile('plugin:thing'), isNull);
  });

  test('lists the instruction files Pi reads, not Claude Code\'s '
      'CLAUDE.local.md or rules folders', () async {
    write(p.join(config, 'AGENTS.md'), '# Mine\n\nAlways run tests.\n');
    write(p.join(config, 'APPEND_SYSTEM.md'), 'Be brief.\n');
    write(p.join(config, 'rules', 'style.md'), 'Style.\n');
    write(p.join(project, 'AGENTS.md'), 'Project rules.\n');
    write(p.join(project, 'CLAUDE.local.md'), 'Private.\n');
    write(p.join(project, '.pi', 'SYSTEM.md'), 'You are a reviewer.\n');
    final rules = await store.list(CustomizationKind.rules, project: project);
    expect(
      [for (final r in rules) (r.scope, r.name)],
      [
        (CustomizationScope.user, 'AGENTS.md'),
        (CustomizationScope.user, 'APPEND_SYSTEM.md'),
        (CustomizationScope.project, 'AGENTS.md'),
        (CustomizationScope.project, 'SYSTEM.md'),
      ],
    );
    expect(rules.first.description, 'Always run tests.');
  });

  test('lists MCP servers from mcp.json, the user\'s and the project\'s, '
      'and whether one is turned off', () async {
    write(
      p.join(config, 'mcp.json'),
      jsonEncode({
        'mcpServers': {
          'github': {'url': 'https://example.com/mcp', 'type': 'http'},
          'old': {'command': 'old-mcp', 'enabled': false},
        },
      }),
    );
    write(
      p.join(project, '.pi', 'mcp.json'),
      jsonEncode({
        'mcpServers': {
          'db': {
            'command': 'npx',
            'args': ['db-mcp', '--ro'],
          },
          'docs': {'url': 'https://docs', 'description': 'The docs'},
        },
      }),
    );
    write(
      p.join(config, '.claude.json'),
      jsonEncode({
        'mcpServers': {
          'claude-only': {'command': 'x'},
        },
      }),
    );
    final servers = await store.list(CustomizationKind.mcps, project: project);
    expect(
      [for (final s in servers) (s.scope, s.name, s.description, s.enabled)],
      [
        (
          CustomizationScope.user,
          'github',
          'http · https://example.com/mcp',
          null,
        ),
        (CustomizationScope.user, 'old', 'old-mcp', false),
        (CustomizationScope.project, 'db', 'npx db-mcp --ro', null),
        (CustomizationScope.project, 'docs', 'The docs', null),
      ],
    );
    expect(servers.first.detail, contains('"url"'));
    expect(servers.first.editable, isTrue);
    expect(servers.first.path, p.join(config, 'mcp.json'));
  });

  test('lists the Pi packages the settings declare, by name', () async {
    write(
      p.join(config, 'settings.json'),
      jsonEncode({
        'packages': [
          'npm:@example/pi-tools@1.0.0',
          {
            'source': 'git:github.com/example/pi-skills@v1',
            'skills': ['skills/a'],
          },
          './local-package',
          {'nothing': true},
        ],
      }),
    );
    write(
      p.join(project, '.pi', 'settings.json'),
      jsonEncode({
        'packages': ['npm:pi-extra'],
      }),
    );
    // What Pi installed tells what a package is.
    write(
      p.join(
        config,
        'npm',
        'node_modules',
        '@example',
        'pi-tools',
        'package.json',
      ),
      jsonEncode({'name': '@example/pi-tools', 'description': 'Handy tools'}),
    );
    final plugins = await store.list(
      CustomizationKind.plugins,
      project: project,
    );
    expect(
      [for (final x in plugins) (x.scope, x.name, x.description, x.source)],
      [
        (
          CustomizationScope.user,
          '@example/pi-tools',
          'Handy tools',
          'npm:@example/pi-tools@1.0.0',
        ),
        (
          CustomizationScope.user,
          'example/pi-skills',
          'git:github.com/example/pi-skills@v1',
          'git:github.com/example/pi-skills@v1',
        ),
        (
          CustomizationScope.user,
          'local-package',
          './local-package',
          './local-package',
        ),
        (
          CustomizationScope.project,
          'pi-extra',
          'npm:pi-extra',
          'npm:pi-extra',
        ),
      ],
    );
    expect(plugins.every((x) => !x.editable && x.removePath == null), isTrue);
    expect(plugins[1].detail, contains('"skills"'));
  });

  test('names a package as its source does', () {
    for (final (source, name) in [
      ('npm:@scope/pkg@1.2.3', '@scope/pkg'),
      ('npm:pkg', 'pkg'),
      ('npm:pkg@latest', 'pkg'),
      ('git:github.com/a/b@v1', 'a/b'),
      ('https://github.com/a/b.git', 'a/b'),
      ('/abs/path/to/pkg/', 'pkg'),
      (r'C:\tools\pkg', 'pkg'),
      ('./pkg', 'pkg'),
    ]) {
      expect(CustomizationStore.packageName(source), name, reason: source);
    }
  });

  test('finds the file MCP servers are kept in, by scope', () async {
    Future<String?> file(CustomizationKind kind, CustomizationScope scope) =>
        store.configFile(kind, scope, project: project);
    expect(
      await file(CustomizationKind.mcps, CustomizationScope.user),
      p.join(config, 'mcp.json'),
    );
    expect(
      await file(CustomizationKind.mcps, CustomizationScope.project),
      p.join(project, '.pi', 'mcp.json'),
    );
    expect(
      await store.configFile(
        CustomizationKind.mcps,
        CustomizationScope.project,
      ),
      isNull,
    );
    expect(
      await file(CustomizationKind.skills, CustomizationScope.user),
      isNull,
    );
    expect(
      await file(CustomizationKind.plugins, CustomizationScope.user),
      isNull,
    );
  });

  test('lists none of each where there are none', () async {
    for (final kind in CustomizationKind.values) {
      expect(await store.list(kind, project: project), isEmpty);
    }
  });

  test('takes any name a file can have, Chinese included', () {
    for (final name in ['style', 'Release_notes-2', '代码风格', '发布v2', 'a' * 64]) {
      expect(isCustomizationName(name), isTrue, reason: name);
    }
    for (final name in [
      '',
      '../escape',
      'a/b',
      'a b',
      'what?',
      'a:b',
      '.hidden',
      '-dash',
      'ends.',
      'a' * 65,
    ]) {
      expect(isCustomizationName(name), isFalse, reason: name);
    }

    expect(
      followsOfficialNaming(CustomizationKind.skills, 'pdf-tools'),
      isTrue,
    );
    expect(followsOfficialNaming(CustomizationKind.skills, '代码风格'), isFalse);
    expect(followsOfficialNaming(CustomizationKind.rules, '代码风格'), isTrue);
    expect(followsOfficialNaming(CustomizationKind.commands, '发布'), isTrue);
  });

  test('makes new ones from templates, edits and deletes them', () async {
    final skill = await store.create(
      CustomizationKind.skills,
      CustomizationScope.user,
      'release-notes',
    );
    expect(skill, p.join(config, 'skills', 'release-notes', 'SKILL.md'));
    expect(parseFrontMatter(await store.read(skill))['name'], 'release-notes');
    await expectLater(
      store.create(
        CustomizationKind.skills,
        CustomizationScope.user,
        'release-notes',
      ),
      throwsA(isA<IdeFileExistsException>()),
    );
    expect(
      () => store.create(
        CustomizationKind.skills,
        CustomizationScope.user,
        '../escape',
      ),
      throwsArgumentError,
    );

    final chinese = await store.create(
      CustomizationKind.commands,
      CustomizationScope.project,
      '发布说明',
      project: project,
    );
    expect(chinese, p.join(project, '.pi', 'prompts', '发布说明.md'));
    expect(File(chinese).existsSync(), isTrue);

    await store.write(skill, '---\nname: notes\ndescription: Edited\n---\n');
    final listed = await store.list(CustomizationKind.skills);
    expect(listed.single.description, 'Edited');

    await store.delete(listed.single);
    expect(Directory(p.dirname(skill)).existsSync(), isFalse);
    expect(await store.list(CustomizationKind.skills), isEmpty);
  });

  test('the rules are the one AGENTS.md: the user\'s in the agent folder, '
      'a project\'s at its root', () async {
    final user = await store.create(
      CustomizationKind.rules,
      CustomizationScope.user,
      'AGENTS',
    );
    expect(user, p.join(config, 'AGENTS.md'));
    final mine = await store.create(
      CustomizationKind.rules,
      CustomizationScope.project,
      'AGENTS',
      project: project,
    );
    expect(mine, p.join(project, 'AGENTS.md'));
    await expectLater(
      store.create(
        CustomizationKind.rules,
        CustomizationScope.project,
        'AGENTS',
        project: project,
      ),
      throwsA(isA<IdeFileExistsException>()),
    );
    expect(
      () =>
          store.create(CustomizationKind.plugins, CustomizationScope.user, 'x'),
      throwsArgumentError,
    );
  });
}
