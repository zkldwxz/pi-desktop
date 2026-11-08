import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../ide/explorer_excludes.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_menu.dart';
import '../../ide/ide_notifications.dart' show IdeSeverity;
import '../../kernel/pi/pi_transport.dart';
import '../../kernel/pi/pi_runtime_updates.dart';
import '../../kernel/claude_code/claude_path_setting.dart';
import '../../kernel/commit_attribution.dart';
import '../../chat/composer/composer_polish.dart' show ComposerPolishSetting;
import '../../chat/widgets/turn_footer.dart' show LiveTurnStatsSetting;
import '../../l10n/l10n.dart';
import '../../platform/app_platform.dart';
import '../../platform/context_menu.dart';
import '../../platform/shell_command.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../../tips/feature_tips_controller.dart';
import '../../tips/feature_tips_view.dart';
import '../../window/window_settings.dart';
import '../../workspace/main_window.dart';
import '../shell_command_actions.dart';
import '../user_settings.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// Settings → General: what the app shows at launch
/// (`workbench.mainWindow`), where the IDE opens and how its windows open,
/// come back and close (`window.*`), when a message sent while the agent
/// works is taken up (`chat.queuedMessages`), whether the composer has its
/// Polish button, and whether the turn under way shows time, speed and tokens.
/// the `code` shell command, and Open with BaoCode in Finder's or
/// Explorer's context menu. A choice is written at once; the default is not
/// written.
class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({
    super.key,
    this.settings,
    this.tips,
    this.claudeStatus,
  });

  /// settings.json; none under test, where choices are not kept.
  final UserSettings? settings;

  /// The Claude Code that runs now ([localClaudeStatus]); none under
  /// test and on the web, where the path is not shown.
  final Future<LocalClaudeStatus?> Function()? claudeStatus;

  /// The feature tips: those not on yet are listed first.
  final FeatureTipsController? tips;

  static String attributionName(BuildContext context, CommitAttribution value) {
    final l10n = context.l10n;
    return switch (value) {
      CommitAttribution.baocode => 'BaoCode',
      CommitAttribution.agent => l10n.generalSettingsAttributionAgent,
      CommitAttribution.none => l10n.generalSettingsAttributionNone,
    };
  }

  static String mainWindowName(BuildContext context, MainWindow value) {
    final l10n = context.l10n;
    return switch (value) {
      MainWindow.chat => l10n.generalSettingsMainWindowChat,
      MainWindow.ide => l10n.generalSettingsMainWindowIde,
      MainWindow.last => l10n.generalSettingsMainWindowLast,
    };
  }

  void _selectMainWindow(MainWindow value) => _write(
    MainWindow.settingKey,
    value == MainWindow.fallback ? null : value.name,
  );

  /// The `window.*` settings' rows: each its label, description, and
  /// values (the first the default) as settings.json has them and named.
  List<Widget> _windowRows(BuildContext context) {
    final l10n = context.l10n;
    // VS Code's `default` is `off`'s, so not a choice of its own.
    final open = {
      OpenInNewWindow.off.setting: l10n.generalSettingsOpenOff,
      OpenInNewWindow.on.setting: l10n.generalSettingsOpenOn,
    };
    return [
      _choiceRow(
        context,
        key: WindowSettings.ideWindowsKey,
        label: l10n.generalSettingsIdeWindows,
        description: l10n.generalSettingsIdeWindowsDescription,
        values: {
          IdeWindows.mainWindow.name: l10n.generalSettingsIdeWindowsMain,
          IdeWindows.separate.name: l10n.generalSettingsIdeWindowsSeparate,
        },
      ),
      _choiceRow(
        context,
        key: WindowSettings.openFoldersKey,
        label: l10n.generalSettingsOpenFolders,
        description: l10n.generalSettingsOpenFoldersDescription,
        values: open,
      ),
      _choiceRow(
        context,
        key: WindowSettings.openFilesKey,
        label: l10n.generalSettingsOpenFiles,
        description: l10n.generalSettingsOpenFilesDescription,
        values: open,
      ),
      _choiceRow(
        context,
        key: WindowSettings.restoreWindowsKey,
        label: l10n.generalSettingsRestoreWindows,
        description: l10n.generalSettingsRestoreWindowsDescription,
        values: {
          RestoreWindows.one.name: l10n.generalSettingsRestoreOne,
          RestoreWindows.all.name: l10n.generalSettingsRestoreAll,
          RestoreWindows.folders.name: l10n.generalSettingsRestoreFolders,
          RestoreWindows.none.name: l10n.generalSettingsRestoreNone,
        },
      ),
      _choiceRow(
        context,
        key: WindowSettings.newWindowDimensionsKey,
        label: l10n.generalSettingsNewWindowDimensions,
        description: l10n.generalSettingsNewWindowDimensionsDescription,
        values: {
          NewWindowDimensions.defaultSize.setting:
              l10n.generalSettingsDimensionsDefault,
          NewWindowDimensions.inherit.setting:
              l10n.generalSettingsDimensionsInherit,
          NewWindowDimensions.maximized.setting:
              l10n.generalSettingsDimensionsMaximized,
          NewWindowDimensions.fullscreen.setting:
              l10n.generalSettingsDimensionsFullscreen,
        },
      ),
      _choiceRow(
        context,
        key: WindowSettings.confirmBeforeCloseKey,
        label: l10n.generalSettingsConfirmBeforeClose,
        description: l10n.generalSettingsConfirmBeforeCloseDescription,
        values: {
          ConfirmBeforeClose.never.name: l10n.generalSettingsConfirmNever,
          ConfirmBeforeClose.keyboardOnly.name:
              l10n.generalSettingsConfirmKeyboard,
          ConfirmBeforeClose.always.name: l10n.generalSettingsConfirmAlways,
        },
      ),
    ];
  }

  Widget _choiceRow(
    BuildContext context, {
    required String key,
    required String label,
    required String description,
    required Map<String, String> values,
    String? fallback,
  }) {
    // A fallback given may change (e.g. as an install is found): the
    // choice is then kept as made, whichever it is.
    final keep = fallback != null;
    fallback ??= values.keys.first;
    final setting = settings?[key];
    final current = values.containsKey(setting) ? setting as String : fallback;
    final shown = values[current]!;
    return SettingsRow(
      label: label,
      description: description,
      trailing: SettingsDropdown(
        current: shown,
        semanticLabel: context.l10n.generalSettingsWindowLabel(label, shown),
        entries: () => [
          for (final MapEntry(key: value, value: name) in values.entries)
            IdeMenuAction(
              name,
              checked: value == current,
              onSelected: () =>
                  _write(key, !keep && value == fallback ? null : value),
            ),
        ],
      ),
    );
  }

  void _write(String key, Object? value) {
    final settings = this.settings;
    if (settings == null) return;
    unawaited(
      settings.update(key, value).catchError((Object error) {
        // A settings file that does not parse is left as it is; its
        // error is shown.
        debugPrint('$key not kept: $error');
      }),
    );
  }

  /// The explorer's exclusions as a list for
  /// [IdeExplorerExcludes.settingKey]: the comma-separated patterns typed
  /// in the field, trimmed; null (the setting removed) when there are none.
  @visibleForTesting
  static List<String>? excludePatterns(String value) {
    final patterns = [
      for (final part in splitPatterns(value))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    return patterns.isEmpty ? null : patterns;
  }

  /// [value] split at its commas, but not those in a glob's `{a,b}` or
  /// `[…]`: `*.{log,tmp}` is one pattern.
  @visibleForTesting
  static List<String> splitPatterns(String value) {
    final parts = <String>[];
    final part = StringBuffer();
    var braces = 0;
    var brackets = false;
    for (final char in value.split('')) {
      switch (char) {
        case '[' when !brackets:
          brackets = true;
        case ']' when brackets:
          brackets = false;
        case '{' when !brackets:
          braces++;
        case '}' when !brackets && braces > 0:
          braces--;
        case ',' when braces == 0 && !brackets:
          parts.add('$part');
          part.clear();
          continue;
      }
      part.write(char);
    }
    parts.add('$part');
    return parts;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = this.settings;
    return ListenableBuilder(
      listenable: settings ?? Listenable.merge(const []),
      builder: (context, _) {
        final mainWindow = MainWindow.parse(settings?[MainWindow.settingKey]);
        final mainWindowShown = mainWindowName(context, mainWindow);
        return SettingsPage(
          title: l10n.generalSettingsTitle,
          children: [
            if (tips case final tips?)
              FeatureTipsSettingsList(
                controller: tips,
                builder: (context, rows) => SettingsGroup(
                  title: l10n.tipsSettingsTitle,
                  description: l10n.tipsSettingsDescription,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                      child: Column(children: rows),
                    ),
                  ],
                ),
              ),
            SettingsCard(
              children: [
                SettingsRow(
                  label: l10n.generalSettingsMainWindow,
                  description: l10n.generalSettingsMainWindowDescription,
                  trailing: SettingsDropdown(
                    current: mainWindowShown,
                    semanticLabel: l10n.generalSettingsMainWindowLabel(
                      mainWindowShown,
                    ),
                    entries: () => [
                      for (final value in MainWindow.values)
                        IdeMenuAction(
                          mainWindowName(context, value),
                          checked: value == mainWindow,
                          onSelected: () => _selectMainWindow(value),
                        ),
                    ],
                  ),
                ),
                SettingsSwitchRow(
                  label: l10n.generalSettingsComposerPolish,
                  description: l10n.generalSettingsComposerPolishDescription,
                  value: ComposerPolishSetting.enabled(
                    settings?[ComposerPolishSetting.settingKey],
                  ),
                  onChanged: (on) => _write(
                    ComposerPolishSetting.settingKey,
                    on ? null : ComposerPolishSetting.off,
                  ),
                ),
                SettingsSwitchRow(
                  label: l10n.generalSettingsLiveTurnStats,
                  description: l10n.generalSettingsLiveTurnStatsDescription,
                  value: LiveTurnStatsSetting.enabled(
                    settings?[LiveTurnStatsSetting.settingKey],
                  ),
                  onChanged: (on) => _write(
                    LiveTurnStatsSetting.settingKey,
                    on ? null : LiveTurnStatsSetting.off,
                  ),
                ),
              ],
            ),
            if (!kIsWeb)
              SettingsGroup(
                title: 'PI',
                children: [
                  _PiRuntimeUpdateSettings(settings: settings),
                  SettingsCard(
                    children: [
                      for (final field in const [
                        (
                          PiRuntimeSettings.pathKey,
                          'Pi CLI',
                          'Uses the latest installed official Pi release when empty.',
                        ),
                        (
                          PiRuntimeSettings.nodeKey,
                          'Node.js',
                          'Bundled Node.js is used when empty; requires Node 22.19 or newer.',
                        ),
                      ])
                        SettingsRow(
                          label: field.$2,
                          description: '${field.$3} (${field.$1})',
                          trailing: SettingsTextField(
                            value: settings?[field.$1] as String? ?? '',
                            hint: 'Bundled runtime',
                            semanticLabel: field.$2,
                            width: 260,
                            onSubmitted: (value) => _write(
                              field.$1,
                              value.trim().isEmpty ? null : value.trim(),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            SettingsGroup(
              title: l10n.generalSettingsWindows,
              children: _windowRows(context),
            ),
            SettingsGroup(
              title: l10n.generalSettingsIde,
              children: [
                SettingsCard(
                  children: [
                    SettingsRow(
                      label: l10n.explorerExcludeSetting,
                      description: l10n.explorerExcludeSettingDescription,
                      trailing: SettingsTextField(
                        value: IdeExplorerExcludes.parse(
                          settings?[IdeExplorerExcludes.settingKey],
                        ).patterns.join(', '),
                        width: 260,
                        hint: l10n.explorerExcludeSettingPlaceholder,
                        semanticLabel: l10n.explorerExcludeSetting,
                        onSubmitted: (value) => _write(
                          IdeExplorerExcludes.settingKey,
                          excludePatterns(value),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (ShellCommand.supported)
              const SettingsCard(children: [_ShellCommandSetting()]),
            if (ContextMenu.supported)
              const SettingsCard(children: [_ContextMenuSetting()]),
          ],
        );
      },
    );
  }
}

class _PiRuntimeUpdateSettings extends StatelessWidget {
  const _PiRuntimeUpdateSettings({this.settings});
  final UserSettings? settings;

  @override
  Widget build(BuildContext context) {
    final updates = PiRuntimeUpdates.current;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) => SettingsCard(
        children: [
          SettingsSwitchRow(
            label: zh ? '自动更新 PI 内核' : 'Update Pi automatically',
            description: zh ? '默认跟随 PI 官方稳定发行版。新会话使用更新，正在运行的会话不受影响。' : 'Follow official stable Pi releases. New sessions use updates; running sessions keep their runtime.',
            value: settings?[PiRuntimeUpdates.autoKey] != false,
            onChanged: (on) => unawaited(
              settings?.update(PiRuntimeUpdates.autoKey, on ? null : false),
            ),
          ),
          SettingsRow(
            label: updates.info == null
                ? (zh ? 'PI 发行版本' : 'Pi release')
                : 'PI ${updates.info!.version}',
            description:
                updates.error ??
                (updates.info?.latest == null
                    ? (zh
                          ? '从 PI 官方稳定发行渠道检查更新。'
                          : 'Check the official Pi stable release channel.')
                    : '${zh ? '官方最新版本' : 'Official latest'}: ${updates.info!.latest}'),
            trailing: SettingsButtons(
              children: [
                IdeButton(
                  label: zh ? '检查更新' : 'Check for Updates',
                  onPressed: updates.busy
                      ? null
                      : () => unawaited(updates.check()),
                ),
                IdeButton(
                  label: zh ? '更新 PI' : 'Update Pi',
                  secondary: true,
                  onPressed: updates.busy
                      ? null
                      : () => unawaited(updates.check(install: true)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether the `code` command is installed, and the buttons to install or
/// remove it; what that came to, under them.
class _ShellCommandSetting extends StatefulWidget {
  const _ShellCommandSetting();

  @override
  State<_ShellCommandSetting> createState() => _ShellCommandSettingState();
}

class _ShellCommandSettingState extends State<_ShellCommandSetting> {
  ShellCommandStatus? _status;
  bool _busy = false;
  ShellCommandOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    final status = await ShellCommand.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _run(
    Future<ShellCommandOutcome?> Function(BuildContext) action,
  ) async {
    setState(() {
      _busy = true;
      _outcome = null;
    });
    final outcome = await action(context);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = outcome;
    });
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = _status;
    final outcome = _outcome;
    return SettingsRow(
      label: l10n.generalSettingsShellCommand,
      description: l10n.generalSettingsShellCommandDescription(
        ShellCommand.location,
      ),
      below: [
        if (status != null)
          Text(switch (status) {
            ShellCommandStatus.installed =>
              l10n.generalSettingsShellCommandInstalled,
            ShellCommandStatus.occupied =>
              l10n.generalSettingsShellCommandOccupied,
            _ => l10n.generalSettingsShellCommandNotInstalled,
          }, style: SettingsText.description),
        if (outcome != null)
          SelectableText(
            outcome.message,
            style: outcome.severity == IdeSeverity.error
                ? SettingsText.description.copyWith(
                    color: themeColors['errorForeground'],
                  )
                : SettingsText.description,
          ),
      ],
      trailing: SettingsButtons(
        children: [
          IdeButton(
            label: l10n.generalSettingsShellCommandInstall,
            onPressed: _busy || status == null
                ? null
                : () => unawaited(_run(installShellCommand)),
          ),
          IdeButton(
            label: l10n.generalSettingsShellCommandUninstall,
            secondary: true,
            onPressed: _busy || status != ShellCommandStatus.installed
                ? null
                : () => unawaited(_run(uninstallShellCommand)),
          ),
        ],
      ),
    );
  }
}

/// Whether Open with BaoCode and Open with Fast Ide are in the system's
/// context menu (see ContextMenu), and the buttons to turn them on or off
/// (and, on macOS, System Settings' extensions); what failed, under them.
class _ContextMenuSetting extends StatefulWidget {
  const _ContextMenuSetting();

  @override
  State<_ContextMenuSetting> createState() => _ContextMenuSettingState();
}

class _ContextMenuSettingState extends State<_ContextMenuSetting> {
  ContextMenuStatus? _status;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    ContextMenuStatus status;
    try {
      status = await ContextMenu.status();
    } on ContextMenuException catch (error) {
      status = ContextMenuStatus.off;
      _error = error.message;
    }
    if (mounted) setState(() => _status = status);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await action();
    } on ContextMenuException catch (failure) {
      error = failure.message;
    } on Object catch (failure) {
      error = '$failure';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = _status;
    final error = _error;
    final openSystemSettings = ContextMenu.openSystemSettings;
    final ready = !_busy && status != null;
    return SettingsRow(
      label: AppPlatform.isMacOS
          ? l10n.generalSettingsContextMenuFinder
          : l10n.generalSettingsContextMenuExplorer,
      description: [
        l10n.generalSettingsContextMenuDescription,
        if (AppPlatform.isMacOS) l10n.generalSettingsContextMenuMacNote,
      ].join(' '),
      below: [
        if (status != null)
          Text(switch (status) {
            ContextMenuStatus.on => l10n.generalSettingsContextMenuOn,
            ContextMenuStatus.off => l10n.generalSettingsContextMenuOff,
            ContextMenuStatus.unsupported =>
              l10n.generalSettingsContextMenuUnsupported,
          }, style: SettingsText.description),
        if (error != null)
          SelectableText(
            l10n.generalSettingsContextMenuFailed(error),
            style: SettingsText.description.copyWith(
              color: themeColors['errorForeground'],
            ),
          ),
      ],
      trailing: SettingsButtons(
        children: [
          IdeButton(
            label: l10n.generalSettingsContextMenuTurnOn,
            onPressed: ready && status == ContextMenuStatus.off
                ? () => unawaited(
                    _run(
                      () => ContextMenu.install((
                        agent: l10n.contextMenuOpenWith('pi-desktop'),
                        ide: l10n.contextMenuOpenWith('Fast Ide'),
                      )),
                    ),
                  )
                : null,
          ),
          IdeButton(
            label: l10n.generalSettingsContextMenuTurnOff,
            secondary: true,
            onPressed: ready && status == ContextMenuStatus.on
                ? () => unawaited(_run(ContextMenu.uninstall))
                : null,
          ),
          if (openSystemSettings != null)
            IdeButton(
              label: l10n.generalSettingsContextMenuSystemSettings,
              secondary: true,
              onPressed: () => unawaited(openSystemSettings()),
            ),
        ],
      ),
    );
  }
}
