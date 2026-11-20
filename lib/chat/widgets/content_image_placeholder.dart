import 'dart:async';

import 'package:flutter/material.dart';

import '../../base/step_clock.dart';
import '../../theme/app_theme.dart';

/// How wide a picture in the chat's content shows at most; as tall as that
/// makes it.
const contentImageMaxWidth = 480.0;

/// Where a picture yet to be made shows, a light sweeping across it: as
/// big as one of [aspectRatio] (width over height) shows once it is there,
/// as wide as they may be.
class ContentImagePlaceholder extends StatelessWidget {
  const ContentImagePlaceholder({super.key, this.aspectRatio = 1});

  final double aspectRatio;

  @override
  Widget build(BuildContext context) => ContentImageFrame(
    size: Size(contentImageMaxWidth, contentImageMaxWidth / aspectRatio),
    child: const ImageShimmer(startAfter: Duration.zero),
  );
}

/// [child] framed as a picture of the content is: its corners rounded, a
/// line around. [size] (in pixels) is the picture's, kept from the start
/// down to [contentImageMaxWidth]; a 16:9 one's when null.
class ContentImageFrame extends StatelessWidget {
  const ContentImageFrame({this.size, this.hovered = false, required this.child});

  final Size? size;
  final bool hovered;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(8);
    final size = this.size;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: contentImageMaxWidth),
      child: SizedBox(
        width: size?.width ?? contentImageMaxWidth,
        child: AspectRatio(
          aspectRatio: size == null ? 16 / 9 : size.width / size.height,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: radius),
            // Over the picture, clipped to the same corners.
            foregroundDecoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: hovered ? AppColors.borderStrong : AppColors.partBorder,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The place of a picture yet to show, as big as it is given: still at
/// first, so one quick to come only shows; past [startAfter], a skeleton's
/// wave: a soft band of light going across it, left to right, over and
/// over.
class ImageShimmer extends StatefulWidget {
  const ImageShimmer({super.key, this.startAfter = delay});

  static const delay = Duration(milliseconds: 200);

  /// Still until then: [delay], none for one known to take long (a
  /// picture being made).
  final Duration startAfter;

  /// One sweep.
  static const period = Duration(milliseconds: 1600);

  @override
  State<ImageShimmer> createState() => _ImageShimmerState();
}

class _ImageShimmerState extends State<ImageShimmer> {
  // A step each of the shared clock's frames, not every vsync: a band of
  // light that smooth is all it needs.
  final StepClock _clock = StepClock(StepClock.frame);
  late final Timer _start;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _start = Timer(widget.startAfter, () {
      _started = true;
      _clock.keepTo(context);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) _clock.keepTo(context);
  }

  @override
  void dispose() {
    _start.cancel();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = AppColors.code;
    // Lighter than what it is on, in either theme: as skeletons are.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final light = Color.alphaBlend(
      Colors.white.withValues(alpha: dark ? .07 : .6),
      base,
    );
    return ColoredBox(
      color: base,
      child: AnimatedBuilder(
        animation: _clock,
        builder: (context, _) {
          if (!_clock.isRunning) return const SizedBox.expand();
          final period = ImageShimmer.period.inMicroseconds;
          final swept = _clock.time.inMicroseconds % period / period;
          return SizedBox.expand(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: const Alignment(-1, -.3),
                  end: const Alignment(1, .3),
                  colors: [
                    base.withValues(alpha: 0),
                    light,
                    base.withValues(alpha: 0),
                  ],
                  stops: const [.3, .5, .7],
                  // From wholly before it to wholly past it.
                  transform: _Sliding(swept * 2 - 1),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A gradient moved across by [fraction] of its box's width.
class _Sliding extends GradientTransform {
  const _Sliding(this.fraction);

  final double fraction;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * fraction, 0, 0);
}
