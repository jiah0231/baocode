import 'dart:math' as math;
import 'dart:ui';

/// Only a numeric major is returned, never the user-agent string or profile data.
/// UA freezing preserves Chrome's major; overrides/forks can still be ambiguous.
const browserChromiumMajorExpression = r'''(() => {
  const brands = navigator.userAgentData?.brands;
  const version = brands?.find(b => b.brand === 'Chromium')?.version ??
      /\b(?:HeadlessChrome|Chrome)\/(\d+)\./.exec(navigator.userAgent)?.[1];
  const major = Number(version);
  return Number.isSafeInteger(major) && major > 0 ? major : 0;
})()''';

/// Chrome <=157 forwards CDP wheel deltas as surface DIPs. The upstream CSS
/// correction is in tagged 158.0.8111.0. Unknown values use the standard CSS
/// contract; this heuristic cannot identify early dev builds or backports.
bool browserWheelUsesSurfacePixels(Object? major) =>
    major is num && major.isFinite && major == major.roundToDouble() &&
    major > 0 && major <= 157;

bool _validSize(Size size) =>
    size.width.isFinite &&
    size.height.isFinite &&
    size.width > 0 &&
    size.height > 0;

/// The page fits the view, centered horizontally and aligned to its top.
/// [page] supplies the image's aspect ratio; it need not use CSS units.
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
  Size? imageSize,
}) {
  if (!local.dx.isFinite || !local.dy.isFinite) return null;
  if (!_validSize(page)) return null;
  final rect = browserFrameRect(view, imageSize ?? page);
  if (rect.isEmpty || (!clamp && !rect.contains(local))) return null;
  final x = clamp ? local.dx.clamp(rect.left, rect.right) : local.dx;
  final y = clamp ? local.dy.clamp(rect.top, rect.bottom) : local.dy;
  return Offset(
    (x - rect.left) / rect.width * page.width,
    (y - rect.top) / rect.height * page.height,
  );
}

/// Maps a logical delta into the supplied surface units, using the drawn
/// image's scale. A CDP wheel delta can use DIP while its position uses CSS.
Offset? browserPageDelta(Offset delta, Size view, Size page, {Size? imageSize}) {
  if (!delta.dx.isFinite || !delta.dy.isFinite) return null;
  if (!_validSize(page)) return null;
  final rect = browserFrameRect(view, imageSize ?? page);
  if (rect.isEmpty) return null;
  final mapped = Offset(
    delta.dx * page.width / rect.width,
    delta.dy * page.height / rect.height,
  );
  return mapped.dx.isFinite && mapped.dy.isFinite ? mapped : null;
}

/// Chrome's content viewport and scale factors. The client size excludes
/// classic scrollbars, so it detects changes but is not the whole image's
/// input extent. Screencast deviceWidth/deviceHeight are DIP, not CSS.
class BrowserFrameViewport {
  const BrowserFrameViewport(this.size, {
    this.zoom = 1, this.scale = 1, this.pixelRatio = 1,
  });

  final Size size;
  final double zoom;
  final double scale;
  /// Chrome's physical pixels per unpinched CSS pixel, not Flutter's DPR.
  final double pixelRatio;

  bool get valid => _validSize(size) && zoom.isFinite && zoom > 0 &&
      scale.isFinite && scale > 0 && pixelRatio.isFinite && pixelRatio > 0;

  bool matches(BrowserFrameViewport other) => size == other.size &&
      zoom == other.zoom && scale == other.scale && pixelRatio == other.pixelRatio;
}

/// An encoded capture. For streams [pageSize] supplies full-surface DIP for
/// conversion to CSS; for screenshots it validates the sampled CSS content
/// size and the decoded pixel dimensions supply the full surface. Neither is
/// used directly as pointer coordinates before scale conversion and decoding.
class BrowserFramePayload {
  const BrowserFramePayload({
    required this.data,
    required this.pageSize,
    required this.stamp,
    this.viewport,
    this.pageScale = 1,
  });

  final String data;
  final Size pageSize;
  final int stamp;
  final BrowserFrameViewport? viewport;
  final double pageScale;
}

/// Keeps only the newest frame until the next render opportunity.
///
/// [schedule] should enqueue its callback on the renderer's next frame.
/// Decode the payload in [onFrame], so superseded images are never decoded.
class BrowserFrameFlow {
  BrowserFrameFlow({
    required this._schedule,
    required this._onFrame,
  });

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
    BrowserFrameViewport? viewport,
    double pageScale = 1,
  }) {
    if (_disposed ||
        epoch != _epoch ||
        data.isEmpty ||
        !_validSize(pageSize) ||
        !pageScale.isFinite || pageScale <= 0 ||
        (viewport != null && !viewport.valid) ||
        (_latestStamp != null && stamp <= _latestStamp!)) {
      return false;
    }
    _latestStamp = stamp;
    _pending = BrowserFramePayload(
      data: data, pageSize: pageSize, stamp: stamp, viewport: viewport,
      pageScale: pageScale,
    );
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
