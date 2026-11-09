import 'dart:async';

import 'package:flutter/foundation.dart';

import 'pi_runtime_install_stub.dart'
    if (dart.library.io) 'pi_runtime_install_io.dart'
    as platform;

/// Where setting Pi up stands.
enum PiSetupStage {
  /// Nothing under way, nothing wrong (yet, or no longer).
  idle,

  /// Node.js being downloaded: [PiRuntimeInstall.fraction] of it.
  node,

  /// Pi being installed with npm.
  pi,

  /// It did not work: [PiRuntimeInstall.error] says why.
  failed,
}

/// Getting Pi onto this machine. The app carries none of it (Node.js alone is
/// 100 MB): the first run installs the release the app is made for, with the
/// machine's Node.js or one it downloads, into its data folder; then Pi
/// follows its official releases ([PiRuntimeUpdates]).
class PiRuntimeInstall extends ChangeNotifier {
  static final instance = PiRuntimeInstall();

  /// What does the work; replaceable under test.
  @visibleForTesting
  static Future<void> Function(PiRuntimeInstall state) installer =
      platform.installPiRuntime;

  PiSetupStage stage = PiSetupStage.idle;

  /// How much of a download is done, 0 to 1; null when not known.
  double? fraction;
  String? error;
  Future<void>? _running;

  bool get busy => stage == PiSetupStage.node || stage == PiSetupStage.pi;

  /// Makes sure Pi is installed; completes when it is, or throws why not. Once
  /// at a time: what asks while it runs waits for it.
  Future<void> ensure() => _running ??= _run().whenComplete(() {
    _running = null;
  });

  Future<void> _run() async {
    error = null;
    try {
      await installer(this);
      report(PiSetupStage.idle);
    } on Object catch (failure) {
      error = '$failure'
          .replaceFirst('Exception: ', '')
          .replaceFirst('Bad state: ', '');
      report(PiSetupStage.failed);
      rethrow;
    }
  }

  /// What the installer says it is doing.
  void report(PiSetupStage next, {double? fraction}) {
    stage = next;
    this.fraction = fraction;
    notifyListeners();
  }
}
