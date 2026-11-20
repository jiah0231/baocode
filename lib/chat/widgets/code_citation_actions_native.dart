import 'package:flutter/widgets.dart';

import '../side_panel/file_link.dart' show FileLineRange, FileLink;
import '../side_panel/file_open.dart' show FileOpenScope;

/// Keep the native workspace and known-file resolver in the desktop adapter.
VoidCallback? citationActivation(
  BuildContext context, {
  required String path,
  required int start,
  required int end,
  required String? Function() fallbackPath,
  required void Function(String, int, int)? open,
}) {
  final files = FileOpenScope.maybeOf(context);
  final resolved = files != null ? files.resolve(path) : fallbackPath();
  if (open == null || resolved == null) return null;
  return () {
    if (files != null) {
      files.openLink(FileLink(path, FileLineRange(start, end)));
    } else {
      open(resolved, start, end);
    }
  };
}
