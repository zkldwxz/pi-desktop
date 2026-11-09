import 'package:pi_desktop/stash/stash_actions.dart';
import 'package:pi_desktop/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a project of another machine called as one here is told by its '
    'host; this machine\'s, and one alone of its name, by the name',
    () async {
      final workspace = Workspace.mock();
      Project at(String path) =>
          workspace.projects.firstWhere((project) => project.path == path);
      final local = workspace.projects.firstWhere(
        (project) => project.name == 'pi-desktop',
      );
      await workspace.openFolder('ssh://home-imac/work/pi-desktop');
      await workspace.openFolder('ssh://home-imac/work/alone');

      expect(stashProjectLabel(workspace, local), 'pi-desktop');
      expect(
        stashProjectLabel(workspace, at('ssh://home-imac/work/pi-desktop')),
        'pi-desktop · home-imac',
      );
      expect(
        stashProjectLabel(workspace, at('ssh://home-imac/work/alone')),
        'alone',
      );
    },
  );
}
