import 'package:pi_conpty/pi_conpty.dart';

import 'pty_stub.dart' if (dart.library.io) 'pty_io.dart' as platform;

export 'package:pi_conpty/pi_conpty.dart' hide WindowsPty;

/// Whether processes can run on a pseudo terminal here: on macOS and Linux
/// (with the native library hook/build.dart makes) and on Windows (ConPTY);
/// not in the browser.
bool get ptySupported => platform.supported;

/// Starts [launch] on a pseudo terminal; fails with [PtyException] (always
/// on the web).
Future<Pty> spawnPty(PtyLaunch launch) => platform.spawn(launch);
