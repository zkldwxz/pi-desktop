import 'package:flutter/material.dart';

import 'agent_kernel.dart';
import 'pi/pi_kernel.dart';
import 'pi/pi_catalog.dart';

/// pi-desktop's runtime and session catalog. Legacy adapters remain available
/// to upstream tests and remote protocol code but are never offered by this app.
abstract final class KernelRegistry {
  static final KernelDescriptor pi = KernelDescriptor(
    id: 'pi',
    label: 'PI',
    icon: Icons.auto_awesome_rounded,
    description: 'Pi coding agent',
    create: (context) => PiKernel(pi, context),
    catalog: PiRemoteCatalog(),
  );

  static List<KernelDescriptor> _all = [pi];

  static List<KernelDescriptor> get all => _all;

  /// Replaces the kernels on offer, e.g. with scripted ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
