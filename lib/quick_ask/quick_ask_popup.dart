import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ide/ide_hover.dart';
import '../theme/workbench_theme.dart' show themeColors;

/// Layout reads only an anchor snapshot, never another render tree's size.
/// The popup refreshes this after the source has finished layout.
class QuickAskLayout extends SingleChildLayoutDelegate {
  QuickAskLayout({required this.anchor, required this.insets})
    : super(relayout: anchor);

  final ValueListenable<Rect?> anchor;
  final EdgeInsets insets;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
      320.0,
      math.max(0.0, constraints.maxWidth - insets.horizontal - 16),
    );
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.min(
        400,
        math.max(0, constraints.maxHeight - insets.vertical - 16),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rect =
        anchor.value ?? Rect.fromLTWH(size.width / 2, size.height / 2, 0, 0);
    final left = insets.left + 8;
    final top = insets.top + 8;
    final right = math.max(
      left,
      size.width - insets.right - childSize.width - 8,
    );
    final bottom = math.max(
      top,
      size.height - insets.bottom - childSize.height - 8,
    );
    final below = rect.bottom + 6;
    final y = below <= bottom ? below : rect.top - childSize.height - 6;
    return Offset(rect.left.clamp(left, right), y.clamp(top, bottom));
  }

  @override
  bool shouldRelayout(QuickAskLayout oldDelegate) => true;
}

/// Icon-only workbench controls with keyboard access and screen-reader names.
/// Labels stay in hover help and accessibility, never a permanent toolbar title.
class QuickAskAction extends StatefulWidget {
  const QuickAskAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.primary = false,
    this.showLabel = false,
    this.help,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
  final bool primary;
  final bool showLabel;
  final String? help;

  @override
  State<QuickAskAction> createState() => _QuickAskActionState();
}

class _QuickAskActionState extends State<QuickAskAction> {
  bool _focus = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    enabled: widget.onPressed != null,
    selected: widget.selected,
    onTap: widget.onPressed,
    excludeSemantics: true,
    child: IdeHover(
      message: widget.help ?? widget.label,
      excludeFromSemantics: true,
      child: FocusableActionDetector(
        enabled: widget.onPressed != null,
        mouseCursor: widget.onPressed == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onShowFocusHighlight: (value) => setState(() => _focus = value),
        onShowHoverHighlight: (value) => setState(() => _hover = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            constraints: const BoxConstraints(minWidth: 30),
            padding: widget.showLabel
                ? const EdgeInsets.symmetric(horizontal: 8)
                : EdgeInsets.zero,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.primary
                  ? themeColors['button.background']
                  : widget.selected
                  ? IdeActionButton.activeBackground
                  : _hover || _focus
                  ? IdeActionButton.hoverBackground
                  : null,
              border: _focus
                  ? Border.all(color: themeColors['focusBorder'])
                  : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.showLabel) ...[
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: themeColors['editorWidget.foreground'],
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                Icon(
                  widget.icon,
                  size: 15,
                  color: widget.onPressed == null
                      ? themeColors['disabledForeground']
                      : widget.primary
                      ? themeColors['button.foreground']
                      : themeColors['editorWidget.foreground'],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
