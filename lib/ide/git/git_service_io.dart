import 'dart:io';

export 'package:pi_remote/local.dart' show runGit, watchRepository;

/// [data] inflated from zlib's format.
List<int> zlibInflate(List<int> data) => ZLibDecoder().convert(data);
