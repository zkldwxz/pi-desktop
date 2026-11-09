import 'dart:convert';

import 'pi_package_catalog_stub.dart'
    if (dart.library.io) 'pi_package_catalog_io.dart'
    as platform;

/// One package of Pi's package gallery: an npm package with the
/// `pi-package` keyword (https://pi.dev/packages lists the same).
class PiPackageListing {
  const PiPackageListing({
    required this.name,
    required this.version,
    this.description = '',
    this.author,
    this.homepage,
    this.updated,
    this.weeklyDownloads,
  });

  final String name;
  final String version;
  final String description;
  final String? author;
  final String? homepage;
  final DateTime? updated;
  final int? weeklyDownloads;

  /// What `pi install` takes for it.
  String get source => 'npm:$name';
}

/// The packages of the gallery matching [query] (all, most used first,
/// when empty). Throws where the registry cannot be reached.
Future<List<PiPackageListing>> searchPiPackages(
  String query, {
  int limit = 30,
}) async => parsePiPackageSearch(
  await platform.fetchNpmSearch(piPackageSearchUri(query, limit: limit)),
);

/// The registry's search for the gallery's packages.
Uri piPackageSearchUri(String query, {int limit = 30}) {
  final text = [
    'keywords:pi-package',
    query.trim(),
  ].where((part) => part.isNotEmpty).join(' ');
  return Uri.https('registry.npmjs.org', '/-/v1/search', {
    'text': text,
    'size': '$limit',
    'popularity': '1.0',
    'quality': '0.0',
    'maintenance': '0.0',
  });
}

/// The packages in the registry's [body] (its `objects`); what is not one
/// is left out.
List<PiPackageListing> parsePiPackageSearch(String body) {
  final json = jsonDecode(body);
  final objects = json is Map<String, Object?> ? json['objects'] : null;
  if (objects is! List<Object?>) return const [];
  final found = <PiPackageListing>[];
  for (final object in objects.whereType<Map<String, Object?>>()) {
    final package = object['package'];
    if (package is! Map<String, Object?>) continue;
    final name = package['name'];
    final version = package['version'];
    if (name is! String || version is! String) continue;
    final links = package['links'];
    final downloads = object['downloads'];
    found.add(
      PiPackageListing(
        name: name,
        version: version,
        description: package['description'] as String? ?? '',
        author: switch (package['publisher']) {
          {'username': final String user} => user,
          _ => null,
        },
        homepage: switch (links) {
          {'homepage': final String page} => page,
          {'npm': final String page} => page,
          _ => null,
        },
        updated: DateTime.tryParse(package['date'] as String? ?? ''),
        weeklyDownloads: switch (downloads) {
          {'weekly': final num weekly} => weekly.toInt(),
          _ => null,
        },
      ),
    );
  }
  return found;
}
