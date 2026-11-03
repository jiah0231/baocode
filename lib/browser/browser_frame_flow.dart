import 'dart:math' as math;
import 'dart:ui';

bool _validSize(Size size) =>
    size.width.isFinite &&
    size.height.isFinite &&
    size.width > 0 &&
    size.height > 0;

/// The page fits the view, centered horizontally and aligned to its top.
/// Both sizes are logical/CSS pixels, not the encoded image's pixel size.
Rect browserFrameRect(Size view, Size page) {
  if (!_validSize(view) || !_validSize(page)) return Rect.zero;
  final scale = math.min(view.width / page.width, view.height / page.height);
  final width = page.width * scale;
  final height = page.height * scale;
  if (!_validSize(Size(width, height))) return Rect.zero;
  return Rect.fromLTWH((view.width - width) / 2, 0, width, height);
}

/// Maps a local point to CSS pixels. Blank margins do not hit the page.
/// [clamp] is for an already captured drag or release, not a fresh press.
Offset? browserPagePoint(
  Offset local,
  Size view,
  Size page, {
  bool clamp = false,
}) {
  if (!local.dx.isFinite || !local.dy.isFinite) return null;
  final rect = browserFrameRect(view, page);
  if (rect.isEmpty || (!clamp && !rect.contains(local))) return null;
  final x = clamp ? local.dx.clamp(rect.left, rect.right) : local.dx;
  final y = clamp ? local.dy.clamp(rect.top, rect.bottom) : local.dy;
  return Offset(
    (x - rect.left) / rect.width * page.width,
    (y - rect.top) / rect.height * page.height,
  );
}

/// Maps a logical wheel delta by the same scale used to draw the page.
Offset? browserPageDelta(Offset delta, Size view, Size page) {
  if (!delta.dx.isFinite || !delta.dy.isFinite) return null;
  final rect = browserFrameRect(view, page);
  if (rect.isEmpty) return null;
  final mapped = delta * (page.width / rect.width);
  return mapped.dx.isFinite && mapped.dy.isFinite ? mapped : null;
}

/// The encoded image and its matching CSS viewport travel together.
class BrowserFramePayload {
  const BrowserFramePayload({
    required this.data,
    required this.pageSize,
    required this.stamp,
  });

  final String data;
  final Size pageSize;
  final int stamp;
}

/// Keeps only the newest frame until the next render opportunity.
///
/// [schedule] should enqueue its callback on the renderer's next frame.
/// Decode the payload in [onFrame], so superseded images are never decoded.
class BrowserFrameFlow {
  BrowserFrameFlow({
    required void Function(void Function()) schedule,
    required void Function(BrowserFramePayload) onFrame,
  }) : _schedule = schedule,
       _onFrame = onFrame;

  final void Function(void Function()) _schedule;
  final void Function(BrowserFramePayload) _onFrame;
  BrowserFramePayload? _pending;
  int? _latestStamp;
  int _epoch = 0;
  bool _scheduled = false;
  bool _disposed = false;

  int get epoch => _epoch;

  /// Invalidates work begun for the previous target or stream.
  int reset() {
    if (_disposed) return _epoch;
    _epoch++;
    _pending = null;
    _latestStamp = null;
    // Keep the existing callback: it reads only the current pending slot.
    // Rapid target changes therefore cannot queue unbounded callbacks.
    return _epoch;
  }

  /// [stamp] is a monotonic capture order, reserved before asynchronous work.
  /// A late screenshot cannot replace a newer screencast frame.
  bool push({
    required String data,
    required Size pageSize,
    required int epoch,
    required int stamp,
  }) {
    if (_disposed ||
        epoch != _epoch ||
        data.isEmpty ||
        !_validSize(pageSize) ||
        (_latestStamp != null && stamp <= _latestStamp!)) {
      return false;
    }
    _latestStamp = stamp;
    _pending = BrowserFramePayload(data: data, pageSize: pageSize, stamp: stamp);
    if (!_scheduled) {
      _scheduled = true;
      _schedule(_deliver);
    }
    return true;
  }

  void _deliver() {
    _scheduled = false;
    if (_disposed) return;
    final frame = _pending;
    _pending = null;
    if (frame != null) _onFrame(frame);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _pending = null;
    _latestStamp = null;
  }
}
