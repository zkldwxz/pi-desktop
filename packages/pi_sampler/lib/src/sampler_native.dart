/// The sampler's native half on Windows and Linux: native/pi_sampler.c,
/// and Linux' crash handler, native/pi_crash.c; built by hook/build.dart.
@DefaultAsset('package:pi_sampler/src/sampler_native.dart')
library;

import 'dart:ffi';

@Native<Int32 Function()>(symbol: 'pi_sampler_init')
external int samplerInit();

/// [path] is UTF-8, ending in a 0: a Uint8List's `address` (a leaf call).
@Native<Int32 Function(Pointer<Uint8>, Int32, Int32)>(
  symbol: 'pi_sampler_start',
  isLeaf: true,
)
external int samplerStart(Pointer<Uint8> path, int millis, int interval);

/// Linux' crash handler (native/pi_crash.c): the paths and the header are
/// UTF-8, each ending in a 0 (Uint8Lists' `address`, a leaf call).
@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>(
  symbol: 'pi_crash_install',
  isLeaf: true,
)
external int crashInstall(
  Pointer<Uint8> events,
  Pointer<Uint8> reports,
  Pointer<Uint8> header,
);
