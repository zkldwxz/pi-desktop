import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pi_desktop/chat/widgets/pi_setup_banner.dart';
import 'package:pi_desktop/kernel/pi/pi_runtime_install.dart';

void main() {
  late Future<void> Function(PiRuntimeInstall) saved;
  setUp(() => saved = PiRuntimeInstall.installer);
  tearDown(() => PiRuntimeInstall.installer = saved);

  Future<void> pump(WidgetTester tester, PiRuntimeInstall install) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PiSetupBanner(install: install)),
        ),
      );

  testWidgets('shows nothing while Pi is there', (tester) async {
    await pump(tester, PiRuntimeInstall());
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('Pi'), findsNothing);
  });

  testWidgets('says how far Node.js is, then that Pi is being installed', (
    tester,
  ) async {
    final install = PiRuntimeInstall();
    await pump(tester, install);
    install.report(PiSetupStage.node, fraction: .42);
    await tester.pump();
    expect(
      find.text('Setting up Pi: downloading Node.js… 42%'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .42,
    );
    install.report(PiSetupStage.pi);
    await tester.pump();
    expect(
      find.text('Setting up Pi: installing it (the first time only)…'),
      findsOneWidget,
    );
    install.report(PiSetupStage.idle);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('says why it failed, and Try again sets Pi up again', (
    tester,
  ) async {
    final install = PiRuntimeInstall();
    var attempts = 0;
    final retried = Completer<void>();
    PiRuntimeInstall.installer = (state) async {
      attempts++;
      if (attempts == 1) throw StateError('no network');
      retried.complete();
    };
    await pump(tester, install);
    await expectLater(install.ensure(), throwsStateError);
    await tester.pump();
    expect(find.text('Pi could not be set up: no network'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await retried.future;
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('Try again'), findsNothing);
  });
}
