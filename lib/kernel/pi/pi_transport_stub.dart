import 'pi_transport.dart';

Future<PiTransport> startPi(PiLaunch launch) =>
    Future.error(UnsupportedError('Pi requires the desktop app'));
Future<void> stopPiProcesses() async {}
Future<void> reapPiProcesses() async {}
