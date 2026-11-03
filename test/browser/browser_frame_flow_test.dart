import 'dart:ui';

import 'package:baocode/browser/browser_frame_flow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('browser frame geometry', () {
    test('encoded aspect and CSS input extents remain separate under zoom', () {
      const view = Size(800, 600);
      const image = Size(1200, 800);
      final drawn = browserFrameRect(view, image);
      final local = Offset(drawn.left + drawn.width * .31,
          drawn.top + drawn.height * .67);
      for (final zoom in [1.0, 1.25, 1.5, 2.0]) {
        for (final pinch in [1.0, 1.5]) {
          final css = Size(1200 / zoom / pinch, 800 / zoom / pinch);
          final mapped = browserPagePoint(local, view, css, imageSize: image)!;
          expect(mapped.dx, closeTo(css.width * .31, 1e-8));
          expect(mapped.dy, closeTo(css.height * .67, 1e-8));
          final wheel = browserPageDelta(const Offset(20, -30), view, css,
              imageSize: image)!;
          expect(wheel.dx, closeTo(20 * css.width / drawn.width, 1e-8));
          expect(wheel.dy, closeTo(-30 * css.height / drawn.height, 1e-8));
          expect(browserPagePoint(const Offset(400, 590), view, css,
              imageSize: image), isNull);
        }
      }
    });

    test('actual decoded aspect controls paint and both input axes', () {
      const view = Size(800, 600);
      const image = Size(400, 800);
      const css = Size(390, 800);
      expect(browserFrameRect(view, image), const Rect.fromLTWH(250, 0, 300, 600));
      final point = browserPagePoint(const Offset(343, 402), view, css,
          imageSize: image)!;
      expect(point.dx, closeTo(120.9, 1e-8));
      expect(point.dy, closeTo(536, 1e-8));
      final wheel = browserPageDelta(const Offset(30, 30), view, css,
          imageSize: image)!;
      expect(wheel.dx, closeTo(39, 1e-8));
      expect(wheel.dy, closeTo(40, 1e-8));
    });

    test('viewport signatures include browser zoom and pinch independently', () {
      const baseline = BrowserFrameViewport(Size(800, 600));
      expect(baseline.valid, isTrue);
      expect(baseline.matches(const BrowserFrameViewport(Size(800, 600))), isTrue);
      expect(baseline.matches(const BrowserFrameViewport(Size(800, 600), zoom: 1.25)), isFalse);
      expect(baseline.matches(const BrowserFrameViewport(Size(800, 600), scale: 1.5)), isFalse);
      for (final viewport in [
        const BrowserFrameViewport(Size.zero),
        const BrowserFrameViewport(Size(800, 600), zoom: double.nan),
        const BrowserFrameViewport(Size(800, 600), scale: 0),
      ]) {
        expect(viewport.valid, isFalse);
      }
    });

    test('wide pages leave a bottom margin, not a vertical center gap', () {
      const view = Size(800, 600);
      const page = Size(1600, 800);
      expect(browserFrameRect(view, page), const Rect.fromLTWH(0, 0, 800, 400));
      expect(browserPagePoint(Offset.zero, view, page), Offset.zero);
      expect(
        browserPagePoint(const Offset(400, 200), view, page),
        const Offset(800, 400),
      );
      expect(browserPagePoint(const Offset(400, 450), view, page), isNull);
    });

    test('tall pages reject both horizontal letterbox margins', () {
      const view = Size(800, 600);
      const page = Size(600, 1200);
      expect(
        browserFrameRect(view, page),
        const Rect.fromLTWH(250, 0, 300, 600),
      );
      expect(browserPagePoint(const Offset(249, 300), view, page), isNull);
      expect(browserPagePoint(const Offset(551, 300), view, page), isNull);
      expect(
        browserPagePoint(const Offset(400, 300), view, page),
        const Offset(300, 600),
      );
    });

    test('top and left edges hit; bottom and right edges do not', () {
      const view = Size(800, 600);
      const page = Size(600, 1200);
      expect(
        browserPagePoint(const Offset(250, 0), view, page),
        Offset.zero,
      );
      expect(browserPagePoint(const Offset(550, 300), view, page), isNull);
      expect(browserPagePoint(const Offset(400, 600), view, page), isNull);
      expect(browserPagePoint(const Offset(400, -0.01), view, page), isNull);
      expect(browserPagePoint(const Offset(249.99, 300), view, page), isNull);
      expect(
        browserPagePoint(const Offset(549.5, 599.5), view, page),
        const Offset(599, 1199),
      );
    });

    test('captured drags and releases can clamp to the page edges', () {
      const view = Size(800, 600);
      const page = Size(600, 1200);
      expect(
        browserPagePoint(const Offset(-20, -10), view, page, clamp: true),
        Offset.zero,
      );
      expect(
        browserPagePoint(const Offset(900, 700), view, page, clamp: true),
        const Offset(600, 1200),
      );
      expect(
        browserPagePoint(const Offset(600, 300), view, page, clamp: true),
        const Offset(600, 600),
      );
    });

    test('wheel delta uses the drawn frame scale on both axes', () {
      expect(
        browserPageDelta(
          const Offset(15, -30),
          const Size(800, 600),
          const Size(600, 1200),
        ),
        const Offset(30, -60),
      );
      expect(
        browserPageDelta(Offset.zero, const Size(800, 600), const Size(600, 1200)),
        Offset.zero,
      );
    });

    test('CSS mapping is unchanged by display pixel density', () {
      const page = Size(600, 1200);
      for (final ratio in [1.0, 1.25, 2.0, 3.0]) {
        final physicalView = const Size(800, 600) * ratio;
        final physicalPoint = const Offset(400, 300) * ratio;
        final physicalDelta = const Offset(10, -20) * ratio;
        expect(
          browserPagePoint(physicalPoint / ratio, physicalView / ratio, page),
          const Offset(300, 600),
          reason: 'devicePixelRatio $ratio',
        );
        expect(
          browserPageDelta(physicalDelta / ratio, physicalView / ratio, page),
          const Offset(20, -40),
          reason: 'devicePixelRatio $ratio',
        );
      }
    });

    test('zero, negative and nonfinite dimensions have no drawable frame', () {
      const valid = Size(800, 600);
      const invalidSizes = [
        Size.zero,
        Size(0, 600),
        Size(800, 0),
        Size(-800, 600),
        Size(800, -600),
        Size(double.infinity, 600),
        Size(800, double.negativeInfinity),
        Size(double.nan, 600),
        Size(800, double.nan),
      ];
      for (final invalid in invalidSizes) {
        for (final sizes in [(invalid, valid), (valid, invalid)]) {
          final (view, page) = sizes;
          expect(browserFrameRect(view, page), Rect.zero);
          expect(browserPagePoint(Offset.zero, view, page), isNull);
          expect(browserPagePoint(Offset.zero, view, page, clamp: true), isNull);
          expect(browserPageDelta(const Offset(1, 1), view, page), isNull);
        }
      }
    });

    test('nonfinite input cannot reach browser coordinates, even when clamped', () {
      const view = Size(800, 600);
      const page = Size(600, 1200);
      const invalidPoints = [
        Offset(double.nan, 1),
        Offset(1, double.nan),
        Offset(double.infinity, 1),
        Offset(1, double.negativeInfinity),
      ];
      for (final point in invalidPoints) {
        expect(browserPagePoint(point, view, page), isNull);
        expect(browserPagePoint(point, view, page, clamp: true), isNull);
        expect(browserPageDelta(point, view, page), isNull);
      }
    });

    test('extreme finite dimensions and wheel deltas do not emit infinity', () {
      expect(
        browserFrameRect(const Size(1e-300, 1e-300), const Size(1e300, 1e300)),
        Rect.zero,
      );
      expect(
        browserFrameRect(const Size(1e300, 1e300), const Size(1e-300, 1e-300)),
        Rect.zero,
      );
      expect(
        browserPageDelta(
          const Offset(1e308, -1e308),
          const Size(800, 600),
          const Size(600, 1200),
        ),
        isNull,
      );
    });
  });

  group('browser frame flow', () {
    late List<void Function()> scheduled;
    late List<BrowserFramePayload> delivered;
    late BrowserFrameFlow flow;

    setUp(() {
      scheduled = [];
      delivered = [];
      flow = BrowserFrameFlow(schedule: scheduled.add, onFrame: delivered.add);
    });

    tearDown(() => flow.dispose());

    bool push(int stamp, {int? epoch, String? data, Size? size}) => flow.push(
      data: data ?? 'frame-$stamp',
      pageSize: size ?? const Size(800, 600),
      epoch: epoch ?? flow.epoch,
      stamp: stamp,
    );

    void render() => scheduled.removeAt(0)();

    test('rapid frames schedule once and retain only the newest payload', () {
      for (var stamp = 1; stamp <= 1000; stamp++) {
        expect(push(stamp, size: Size(stamp.toDouble(), 600)), isTrue);
      }
      expect(delivered, isEmpty);
      expect(scheduled, hasLength(1));
      render();
      expect(scheduled, isEmpty);
      expect(delivered, hasLength(1));
      expect(delivered.single.data, 'frame-1000');
      expect(delivered.single.pageSize, const Size(1000, 600));
      expect(delivered.single.stamp, 1000);
    });

    test('new frames after delivery schedule the next render', () {
      push(1);
      render();
      push(2);
      push(3);
      expect(scheduled, hasLength(1));
      render();
      expect(delivered.map((frame) => frame.stamp), [1, 3]);
    });

    test('late and duplicate captures cannot overwrite newer images or sizes', () {
      expect(push(20), isTrue);
      expect(push(19, size: const Size(1, 1)), isFalse);
      expect(push(20, size: const Size(2, 2)), isFalse);
      render();
      expect(delivered.single.stamp, 20);
      expect(delivered.single.pageSize, const Size(800, 600));
      expect(push(19), isFalse);
      expect(push(20), isFalse);
      expect(scheduled, isEmpty);
    });

    test('reset drops pending frames and rejects late work from the old epoch', () {
      final oldEpoch = flow.epoch;
      push(100);
      expect(flow.reset(), oldEpoch + 1);
      expect(push(101, epoch: oldEpoch), isFalse);
      render();
      expect(delivered, isEmpty);
      expect(push(1), isTrue);
      render();
      expect(delivered.single.stamp, 1);
    });

    test('rapid epoch changes reuse one callback for the latest target', () {
      push(10);
      for (var epoch = 1; epoch <= 1000; epoch++) {
        expect(flow.reset(), epoch);
        expect(push(1, data: 'target-$epoch'), isTrue);
      }
      expect(scheduled, hasLength(1));
      render();
      expect(delivered, hasLength(1));
      expect(delivered.single.data, 'target-1000');
    });

    test('invalid payloads do not displace good frames or advance the stamp', () {
      expect(push(1), isTrue);
      expect(push(100, data: ''), isFalse);
      for (final size in [
        Size.zero,
        const Size(-1, 1),
        const Size(1, double.infinity),
        const Size(double.nan, 1),
      ]) {
        expect(push(100, size: size), isFalse);
      }
      render();
      expect(delivered.single.stamp, 1);
      expect(push(2), isTrue);
      render();
      expect(delivered.last.stamp, 2);
    });

    test('delivery can queue the next frame without losing it', () {
      flow.dispose();
      flow = BrowserFrameFlow(
        schedule: scheduled.add,
        onFrame: (frame) {
          delivered.add(frame);
          if (frame.stamp == 1) push(2);
        },
      );
      push(1);
      render();
      expect(delivered.single.stamp, 1);
      expect(scheduled, hasLength(1));
      render();
      expect(delivered.map((frame) => frame.stamp), [1, 2]);
    });

    test('dispose discards queued frames and cannot be revived by reset', () {
      push(1);
      flow.dispose();
      render();
      expect(delivered, isEmpty);
      expect(push(2), isFalse);
      flow.reset();
      expect(push(3), isFalse);
      flow.dispose();
      expect(scheduled, isEmpty);
    });
  });
}
