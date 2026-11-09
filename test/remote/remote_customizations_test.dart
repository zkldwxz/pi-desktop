@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/files.dart' show IdeFileExistsException;
import 'package:pi_desktop/customize/customization_store.dart';
import 'package:pi_desktop/customize/customizations.dart';
import 'package:pi_desktop/remote/remote_customization_disk.dart';
import 'package:pi_desktop/remote/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

/// Customize on a remote host: the customizations its agents read, its
/// own Pi agent folder and its projects', through its server.
void main() {
  late Directory dataDir;
  late Directory temp;
  late String home;
  late String config;
  late String project;
  late SshHost host;
  late CustomizationStore store;

  void write(String path, String text) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('baocode-remote-data-');
    temp = Directory.systemTemp.createTempSync('baocode-remote-custom-');
    final root = temp.resolveSymbolicLinksSync();
    home = p.join(root, 'home');
    config = p.join(home, '.pi-desktop', 'pi-agent');
    project = p.join(root, 'project');
    Directory(project).createSync(recursive: true);
    host = SshHost('dev', connect: MemoryConnector(dataDir.path).call);
    store = CustomizationStore(
      configDir: config,
      disk: RemoteCustomizationDisk(host),
    );
  });
  tearDown(() async {
    host.close();
    temp.deleteSync(recursive: true);
    dataDir.deleteSync(recursive: true);
  });

  test("the host's skills, the user's and its project's", () async {
    write(
      p.join(config, 'skills', 'pdf', 'SKILL.md'),
      '---\nname: pdf\ndescription: Reads PDF files\n---\n',
    );
    write(p.join(project, '.pi', 'skills', 'ship', 'SKILL.md'), 'Ships');
    // A skill linked in from elsewhere, as installers do.
    write(p.join(home, 'shared', 'lint', 'SKILL.md'), 'Lints');
    Link(p.join(config, 'skills', 'lint'))
        .createSync(p.join(home, 'shared', 'lint'));

    final skills = await store.list(CustomizationKind.skills, project: project);
    expect(
      [for (final skill in skills) (skill.scope, skill.name)],
      [
        (CustomizationScope.user, 'lint'),
        (CustomizationScope.user, 'pdf'),
        (CustomizationScope.project, 'ship'),
      ],
    );
    expect(skills[1].description, 'Reads PDF files');
  });

  test('made there, folders and all; edited and deleted there', () async {
    final path = await store.create(
      CustomizationKind.commands,
      CustomizationScope.project,
      'reviewer',
      project: project,
    );
    expect(path, p.join(project, '.pi', 'prompts', 'reviewer.md'));
    expect(File(path).existsSync(), isTrue);
    await expectLater(
      store.create(
        CustomizationKind.commands,
        CustomizationScope.project,
        'reviewer',
        project: project,
      ),
      throwsA(isA<IdeFileExistsException>()),
    );

    await store.write(path, 'Reviews');
    expect(File(path).readAsStringSync(), 'Reviews');
    expect(await store.read(path), 'Reviews');
    expect(await store.exists(path), isTrue);

    final [command] = await store.list(
      CustomizationKind.commands,
      project: project,
    );
    await store.delete(command);
    expect(File(path).existsSync(), isFalse);
  });

  test('its MCP servers, from its mcp.json and the project\'s', () async {
    write(
      p.join(config, 'mcp.json'),
      jsonEncode({
        'mcpServers': {
          'docs': {'command': 'docs-server'},
        },
      }),
    );
    write(
      p.join(project, '.pi', 'mcp.json'),
      jsonEncode({
        'mcpServers': {
          'db': {'url': 'http://localhost:5432'},
        },
      }),
    );
    final servers = await store.list(CustomizationKind.mcps, project: project);
    expect(
      [for (final server in servers) (server.scope, server.name)],
      [(CustomizationScope.user, 'docs'), (CustomizationScope.project, 'db')],
    );
    expect(store.isLocal, isFalse);
  });
}
