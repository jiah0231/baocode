import 'package:flutter/widgets.dart';

/// A standalone renderer must not treat a path as a host file grant.
/// Sidebar opening will need an explicit selected-session action.
VoidCallback? citationActivation(
  BuildContext context, {
  required String path,
  required int start,
  required int end,
  required String? Function() fallbackPath,
  required void Function(String, int, int)? open,
}) => null;
