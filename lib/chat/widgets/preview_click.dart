import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// [child], a tag for something shown shortened (an image, a long paste),
/// which a click opens whole ([onOpen]). Hears the click itself rather
/// than through a gesture, so a selection of the text around it (in an
/// editor, a message) goes on as it would.
class PreviewClick extends StatefulWidget {
  const PreviewClick({super.key, required this.onOpen, required this.child});

  final VoidCallback onOpen;
  final Widget child;

  @override
  State<PreviewClick> createState() => _PreviewClickState();
}

class _PreviewClickState extends State<PreviewClick> {
  /// Where a primary press went down; null for other presses.
  Offset? _pressedAt;

  void _handleDown(PointerDownEvent event) {
    final primary =
        event.kind != PointerDeviceKind.mouse ||
        event.buttons == kPrimaryMouseButton;
    // Shift extends a selection.
    if (!primary || HardwareKeyboard.instance.isShiftPressed) return;
    _pressedAt = event.position;
    PreviewPressScope.notifyPress(context);
  }

  void _handleUp(PointerUpEvent event) {
    final pressedAt = _pressedAt;
    _pressedAt = null;
    // A click, not the end of a drag selection.
    if (pressedAt == null ||
        (event.position - pressedAt).distance > kTouchSlop) {
      return;
    }
    widget.onOpen();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: Listener(
      onPointerDown: _handleDown,
      onPointerUp: _handleUp,
      onPointerCancel: (_) => _pressedAt = null,
      child: widget.child,
    ),
  );
}

/// Tells what is around images and tags a press on one of them (which opens
/// it whole, see [PreviewClick]) from a press on the rest of it: [onPress]
/// hears it first.
class PreviewPressScope extends InheritedWidget {
  const PreviewPressScope({
    super.key,
    required this.onPress,
    required super.child,
  });

  final VoidCallback onPress;

  /// A preview descendant handles this pointer down before its parent fold.
  static void notifyPress(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PreviewPressScope>()?.onPress();

  @override
  bool updateShouldNotify(PreviewPressScope oldWidget) => false;
}
