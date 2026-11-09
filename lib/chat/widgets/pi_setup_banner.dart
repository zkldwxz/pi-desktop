import 'package:flutter/material.dart';

import '../../kernel/pi/pi_runtime_install.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'hover_builder.dart';

/// Over the composer while Pi is being set up for the first time: Node.js
/// downloaded, Pi installed, with how far; or why it did not work, and a
/// button to try again. Nothing once Pi is there.
class PiSetupBanner extends StatelessWidget {
  const PiSetupBanner({super.key, this.install});

  /// What it follows: the app's own, unless under test.
  final PiRuntimeInstall? install;

  @override
  Widget build(BuildContext context) {
    final install = this.install ?? PiRuntimeInstall.instance;
    return ListenableBuilder(
      listenable: install,
      builder: (context, _) {
        final l10n = context.l10n;
        return switch (install.stage) {
          PiSetupStage.idle => const SizedBox.shrink(),
          PiSetupStage.node => _Card(
            text: install.fraction == null
                ? l10n.piSetupNodeUnsized
                : l10n.piSetupNode(((install.fraction ?? 0) * 100).floor()),
            fraction: install.fraction,
          ),
          PiSetupStage.pi => _Card(text: l10n.piSetupInstalling),
          PiSetupStage.failed => _Card(
            text: l10n.piSetupFailed(install.error ?? ''),
            failed: true,
            retry: () => install.ensure().ignore(),
          ),
        };
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.text,
    this.fraction,
    this.failed = false,
    this.retry,
  });

  final String text;
  final double? fraction;
  final bool failed;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
        decoration: BoxDecoration(
          color: themeColors['editorWidget.background'],
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: failed
                ? themeColors['errorForeground']
                : themeColors['editorWidget.border'],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    text,
                    style: TextStyle(
                      color: failed
                          ? themeColors['errorForeground']
                          : AppColors.textPrimary,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                if (retry case final retry?) ...[
                  const SizedBox(width: 12),
                  HoverBuilder(
                    cursor: SystemMouseCursors.click,
                    builder: (context, hovered) => GestureDetector(
                      onTap: retry,
                      child: Text(
                        context.l10n.piSetupRetry,
                        style: TextStyle(
                          color: hovered ? AppColors.text : AppColors.textMuted,
                          fontSize: 12.5,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (!failed) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: fraction,
                    color: themeColors['progressBar.background'],
                    backgroundColor: themeColors['editorWidget.border'],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
