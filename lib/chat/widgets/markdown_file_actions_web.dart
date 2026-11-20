import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'markdown_options.dart';

/// The standalone Web renderer has no local filesystem. A sidebar connected
/// to a desktop session must provide explicit remote file actions separately.
void collectMarkdownGallery(
  BuildContext context,
  List<String> gallery,
  Iterable<String> Function() sources,
) {}

({MarkdownOptions options, Listenable Function() changes})? markdownFileActions(
  BuildContext context, {
  required TextStyle textStyle,
  required List<String> gallery,
  required GestureRecognizer? Function(String? href) externalLink,
}) => null;

Widget markdownFileIconMenu(Widget icon, GestureRecognizer recognizer) => icon;
