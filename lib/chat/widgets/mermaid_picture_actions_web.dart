import 'package:flutter/widgets.dart';

import '../chat_models.dart' show ImageAttachment;

// No desktop picture menu or action is installed in the standalone fixture.
const mermaidPicturePreviewAvailable = false;

void showMermaidPicture(BuildContext context, ImageAttachment picture) {}

Widget mermaidPictureRegion({
  required Future<ImageAttachment> Function() picture,
  required VoidCallback onPreview,
  required Widget child,
}) => child;
