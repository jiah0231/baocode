import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// How MarkdownBlocks draws and what its links, images and task boxes
/// do: as the chat's by default.
@immutable
class MarkdownOptions {
  const MarkdownOptions({
    this.headingSizes = const [19, 17, 15, 13.5, 13.5, 13.5],
    this.headingRules = false,
    this.gap = 8,
    this.headingGap = 12,
    this.link,
    this.code,
    this.linkIcon,
    this.codeIcon,
    this.fileTag,
    this.image,
    this.onToggleTask,
  });

  /// `h1` to `h6`'s font sizes.
  final List<double> headingSizes;

  /// Whether `h1` and `h2` have a line under them, as GitHub's.
  final bool headingRules;

  /// The space between blocks, and before and after a heading.
  final double gap;
  final double headingGap;

  /// What a tap on a link to `href` does; web and mail links open in the
  /// browser when null, others nothing.
  final GestureRecognizer? Function(String? href)? link;

  /// What a tap on inline code does (it names a file, say); nothing when
  /// null, or it gives none.
  final GestureRecognizer? Function(String code)? code;

  /// What is drawn before a link to `href` (or inline code, see [code]):
  /// the icon of the file or folder it opens, say; nothing when null.
  final Widget? Function(String? href)? linkIcon;
  final Widget? Function(String code)? codeIcon;

  /// What a link to `href` labeled `label` shows in its place, as a tag:
  /// an image file's, say; the link when null, or it gives none.
  final InlineSpan? Function(String? href, String label)? fileTag;

  /// An image (`![alt](src "title")`, or HTML's with its `width` and
  /// `height` in pixels); its alt text in brackets when null.
  final Widget Function(
    String src,
    String alt,
    String? title, {
    double? width,
    double? height,
  })?
  image;

  /// Called with a task list box's number (see numberTasks) when it is
  /// clicked; the boxes are only drawn when null.
  final ValueChanged<int>? onToggleTask;
}
