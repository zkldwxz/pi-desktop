import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../settings/user_settings.dart';
import 'pi_runtime_install.dart';
import 'pi_runtime_updates_stub.dart'
    if (dart.library.io) 'pi_runtime_updates_io.dart'
    as platform;

class PiRuntimeUpdateInfo {
  const PiRuntimeUpdateInfo({
    required this.version,
    this.latest,
    this.cli,
    this.managed = false,
  });
  final String version;
  final String? latest;
  final String? cli;
  final bool managed;
}

/// Pi's official stable releases update independently from the desktop shell.
class PiRuntimeUpdates extends ChangeNotifier {
  static final current = PiRuntimeUpdates();
  static const autoKey = 'pi.autoUpdate';
  PiRuntimeUpdateInfo? info;
  String? error;
  bool busy = false;
  Timer? _timer;
  UserSettings? _settings;
  bool get automatic => _settings?[autoKey] != false;

  void follow(UserSettings settings) {
    _settings = settings;
    _timer?.cancel();
    unawaited(refresh());
    _timer = Timer(const Duration(seconds: 30), () {
      if (automatic) unawaited(check(install: true));
      _timer = Timer.periodic(const Duration(hours: 6), (_) {
        if (automatic) unawaited(check(install: true));
      });
    });
  }

  Future<void> refresh() async {
    try {
      info = await platform.piRuntimeCommand('status');
    } on Object catch (failure) {
      error = '$failure';
    }
    notifyListeners();
  }

  Future<void> check({bool install = false}) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      // Pi itself first, on the first run: one installer at a time.
      await PiRuntimeInstall.instance.ensure();
      info = await platform.piRuntimeCommand(install ? 'update' : 'check');
    } on Object catch (failure) {
      error = '$failure';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
