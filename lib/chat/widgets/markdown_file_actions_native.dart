import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../ide/ide_hover.dart';
import '../../theme/app_theme.dart';
import '../../theme/material_file_icons.dart';
import '../composer/composer_embeds.dart' show FileImageChip;
import '../side_panel/file_link.dart';
import '../side_panel/file_link_menu.dart';
import '../side_panel/file_open.dart';
import 'content_image.dart';
import 'markdown_options.dart';

/// Update the same list: cached segments' image actions retain its identity.
void collectMarkdownGallery(
  BuildContext context,
  List<String> gallery,
  Iterable<String> Function() sources,
) {
  final files = FileOpenScope.maybeOf(context);
  if (files != null) {
    for (final src in sources()) {
      if (markdownImagePath(src, files) case final path?) gallery.add(path);
    }
  }
}

({MarkdownOptions options, Listenable Function() changes})? markdownFileActions(
  BuildContext context, {
  required TextStyle textStyle,
  required List<String> gallery,
  required GestureRecognizer? Function(String? href) externalLink,
}) {
  final files = FileOpenScope.maybeOf(context);
  if (files == null) return null;
  Widget? icon(FileLink? link) {
    // Another machine's (see FileLink.machine): not looked for here.
    if (link != null && link.machine != null) {
      return _isFolder(link.path, null)
          ? FolderIcon(link.path, size: _fileIconSize)
          : FileIcon(link.path, size: _fileIconSize);
    }
    final path = link == null ? null : files.resolve(link.path);
    if (path == null) return null;
    return _isFolder(link!.path, files.existence.known(path))
        ? FolderIcon(path, size: _fileIconSize)
        : FileIcon(path, size: _fileIconSize);
  }

  final options = MarkdownOptions(
    link: (href) =>
        externalLink(href) ?? files.linkRecognizer(href, context: context),
    code: (code) => files.codeRecognizer(code, context: context),
    linkIcon: (href) => icon(FileLink.parseHref(href)),
    codeIcon: (code) => icon(FileLink.parseText(code)),
    // An image as an attached one's tag.
    fileTag: (href, label) {
      final link = FileLink.parseHref(href);
      final path = link == null || link.range != null || link.machine != null
          ? null
          : files.resolveShown(link.path);
      if (path == null || !files.showsImage(path)) return null;
      return FileImageChip.span(
        path: path,
        label: label.trim().isEmpty
            ? (files.paths ?? p.context).basename(path)
            : label.trim(),
        files: files,
        textStyle: textStyle,
      );
    },
    // An image file as it is; the others of the message a click away.
    image: (src, alt, title, {width, height}) {
      final path = markdownImagePath(src, files);
      if (path == null) return _imageLink(src, alt, externalLink);
      return MarkdownImage(
        path: path,
        alt: alt,
        files: files,
        gallery: gallery,
      );
    },
  );
  return (
    options: options,
    changes: () => switch (files.folders) {
      final folders? => Listenable.merge([files.existence, folders]),
      null => files.existence,
    },
  );
}

Widget markdownFileIconMenu(Widget icon, GestureRecognizer recognizer) =>
    recognizer is FileLinkRecognizer
        ? FileLinkMenuRegion(menu: recognizer.menu, child: icon)
        : icon;

/// An image the chat does not show (one on the web: its address could
/// tell a server what the agent read): its alt text, a link to it.
Widget _imageLink(
  String src,
  String alt,
  GestureRecognizer? Function(String?) externalLink,
) {
  final label = '[${alt.isEmpty ? 'image' : alt}]';
  final recognizer = externalLink(src);
  if (recognizer is! TapGestureRecognizer) {
    return Text(label, style: TextStyle(color: AppColors.textMuted));
  }
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: recognizer.onTap,
      child: IdeHover(
        message: src,
        child: Text(label, style: TextStyle(color: AppColors.link)),
      ),
    ),
  );
}

const _fileIconSize = 14.0;

/// Whether a link to [written] (as the agent wrote it), [known] to be a
/// file or not (see [FileExistence.known]), goes to a folder: one written
/// with a slash after it, or a name without an extension that is not a
/// file found (`lib/ide`, not `LICENSE`).
bool _isFolder(String written, bool? known) {
  if (written.endsWith('/') || written.endsWith(r'\')) return true;
  if (known == true) return false;
  final name = written.split(RegExp(r'[/\\]')).last;
  // A leading dot is not an extension's (`.github`).
  return name.lastIndexOf('.') <= 0;
}
