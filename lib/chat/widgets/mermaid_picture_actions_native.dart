import 'package:flutter/widgets.dart';

import '../chat_models.dart' show ImageAttachment;
import '../side_panel/file_link_menu.dart';
import 'image_thumbnails.dart' show ImageMenu, showImagePreview;

const mermaidPicturePreviewAvailable = true;

void showMermaidPicture(BuildContext context, ImageAttachment picture) {
  showImagePreview(context, picture);
}

Widget mermaidPictureRegion({
  required Future<ImageAttachment> Function() picture,
  required VoidCallback onPreview,
  required Widget child,
}) => FileLinkMenuRegion(
  menu: _PictureMenu(picture),
  child: MouseRegion(
    cursor: SystemMouseCursors.zoomIn,
    child: GestureDetector(onTap: onPreview, child: child),
  ),
);

/// A right click's on a diagram: a picture's (see [ImageMenu]), the
/// picture made as it is asked for.
class _PictureMenu implements ChatItemMenu {
  const _PictureMenu(this.picture);

  final Future<ImageAttachment> Function() picture;

  @override
  Future<void> show(BuildContext context, Offset position) async {
    final made = await picture();
    if (context.mounted) await ImageMenu(made).show(context, position);
  }
}
