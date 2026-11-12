import 'package:flutter/widgets.dart';

/// Keep the unbounded workspace tree off Windows' accessibility bridge.
/// Its reparenting can crash the bridge and streaming updates are expensive.
/// The separately owned translation tool view has a bounded source/result
/// tree and must expose that text to accessibility clients. Its native
/// TranslationPanelWindow makes the same explicit exception for WM_GETOBJECT.
class AppWindowSemantics extends StatelessWidget {
  const AppWindowSemantics({
    super.key,
    required this.child,
    required this.exclude,
    this.translation = false,
  });

  final Widget child;
  final bool exclude;
  final bool translation;

  @override
  Widget build(BuildContext context) =>
      exclude && !translation ? ExcludeSemantics(child: child) : child;
}
