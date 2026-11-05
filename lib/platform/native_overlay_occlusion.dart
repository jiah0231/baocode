import 'package:flutter/widgets.dart';

/// Native child surfaces are above Flutter's compositor. Mark floating UI while
/// it is mounted so those surfaces can hide, including IgnorePointer tooltips
/// which ordinary hit testing deliberately does not see.
class NativeOverlayOcclusion extends StatefulWidget {
  const NativeOverlayOcclusion({super.key, required this.child});

  final Widget child;
  static final _covers = <int, Set<Object>>{};

  static bool coversView(int viewId) => _covers[viewId]?.isNotEmpty ?? false;

  @override
  State<NativeOverlayOcclusion> createState() => _NativeOverlayOcclusionState();
}

class _NativeOverlayOcclusionState extends State<NativeOverlayOcclusion> {
  int? _viewId;

  void _remove() {
    final id = _viewId;
    if (id == null) return;
    final covers = NativeOverlayOcclusion._covers[id];
    covers?.remove(this);
    if (covers?.isEmpty ?? false) NativeOverlayOcclusion._covers.remove(id);
    _viewId = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final id = View.of(context).viewId;
    if (_viewId == id) return;
    _remove();
    _viewId = id;
    (NativeOverlayOcclusion._covers[id] ??= {}).add(this);
  }

  @override
  void dispose() {
    _remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
