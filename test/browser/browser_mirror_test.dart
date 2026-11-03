import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:baocode/browser/browser_agent_control.dart';
import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_mirror.dart';
import 'package:baocode/browser/browser_tools.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// Real 800x400 and 400x800 RGBA PNGs preserve full-size screenshots.
// Stream metadata and zoomed CSS sizes deliberately differ from encoded pixels.
// No Chrome or JPEG encoder is needed for these synthetic socket tests.
const _red =
    'iVBORw0KGgoAAAANSUhEUgAAAyAAAAGQCAYAAABWJQQ0AAAIUElEQVR4nO3XoQEAIADDsP3/NHxRBBHxtd3ZDgAAQGGvAwAAgH8YEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAjAEBAAAyBgQAAMgYEAAAIGNAAACAzAVfnM3ne3FnMQAAAABJRU5ErkJggg==';
const _blue =
    'iVBORw0KGgoAAAANSUhEUgAAAZAAAAMgCAYAAAAN6jSQAAAMnElEQVR4nO3OoQ3AQBAEseu/6U8NQauRDMx9d+8BwH/zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABN8wAATfMAAE3zAABFH3hWzefJVAdZAAAAAElFTkSuQmCC';

void main() {
  // Its socket queue is real asynchronous work, outside widget fake time.
  final bridge = BrowserBridge.instance;
  setUp(() => expect(bridge.browsers, isEmpty));

  testWidgets('a burst is acknowledged but renders only its newest frame', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await mirror.render(_red);

      final before = mirror.image;
      await mirror.frames([
        for (var i = 0; i < 99; i++) const _Frame(_red, Size(800, 400)),
        const _Frame(_blue, Size(400, 800)),
      ]);
      // All 100 frames reached the real listener, but no render was pumped.
      expect(mirror.image, same(before));
      await mirror.render(_blue);
      expect(find.byType(RawImage), findsOneWidget);
      final page = tester.getRect(mirror.pageListener);
      final drawn = tester.getRect(find.byType(RawImage));
      expect(drawn.top, page.top);
      expect(drawn.height, closeTo(page.height, 0.001));
      expect(drawn.width, closeTo(page.height / 2, 0.001));
      expect(drawn.center.dx, closeTo(page.center.dx, 0.001));
    });
  });

  for (final ratio in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('CSS pointer coordinates do not inherit Flutter DPR $ratio',
        (tester) async {
      tester.view.devicePixelRatio = ratio;
      tester.view.physicalSize = const Size(800, 600) * ratio;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _withMirror(tester, (mirror) async {
        mirror.host.holdScreenshots = true;
        await mirror.pump(ratio: ratio);
        await tester.pump(const Duration(milliseconds: 200));
        await mirror.barrier();
        ui.Image? previous;
        for (final zoom in [1.0, 1.25, 1.5, 2.0]) {
          for (final pinch in [1.0, 1.5]) {
            final css = Size(1200 / (zoom * pinch), 600 / (zoom * pinch));
            await mirror.frames([_Frame(
              _red, const Size(1200, 600), cssSize: css,
              browserZoom: zoom, pageScaleFactor: pinch,
            )]);
            await mirror.render(_red, previous: previous);
            previous = mirror.image;
            final drawn = tester.getRect(find.byType(RawImage));
            final point = drawn.topLeft + Offset(drawn.width * .23, drawn.height * .71);
            mirror.host.calls.clear();
            final gesture = await tester.startGesture(point, kind: PointerDeviceKind.mouse);
            await gesture.up();
            await tester.sendEventToBinding(PointerScrollEvent(
              position: point, scrollDelta: const Offset(11, -17),
            ));
            await mirror.barrier();
            final reason = 'Flutter DPR=$ratio browser zoom=$zoom pinch=$pinch';
            for (final type in ['mousePressed', 'mouseReleased', 'mouseWheel']) {
              final call = mirror.mouseCalls.singleWhere((call) => call.params['type'] == type);
              expect(call.tabId, 1, reason: reason);
              expect(call.params['x'], closeTo(css.width * .23, .001), reason: reason);
              expect(call.params['y'], closeTo(css.height * .71, .001), reason: reason);
            }
            final wheel = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mouseWheel');
            expect(wheel.params['deltaX'], closeTo(11 * css.width / drawn.width, .001), reason: reason);
            expect(wheel.params['deltaY'], closeTo(-17 * css.height / drawn.height, .001), reason: reason);
          }
        }
      });
    });
  }

  testWidgets('fallback and stream each use their own decoded picture and CSS viewport',
      (tester) async {
    await _withMirror(tester, (mirror) async {
      mirror.host.viewport = const Size(600, 300);
      mirror.host.pixelRatio = 4 / 3;
      mirror.host.screenshotData = _red;
      await mirror.pump(visible: false);
      await mirror.barrier();
      final starts = mirror.host.callsFor('Page.startScreencast').length;
      await mirror.pump(visible: true);
      await mirror.until(() => mirror.host.callsFor('Page.startScreencast').length > starts);
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.until(() => mirror.host.callsFor('Page.captureScreenshot').isNotEmpty);
      await mirror.render(_red);
      final fallback = mirror.image;
      final drawn = tester.getRect(find.byType(RawImage));
      await tester.tapAt(drawn.topLeft + Offset(drawn.width * .23, drawn.height * .71));
      await mirror.barrier();
      final first = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mousePressed');
      expect(first.params['x'], closeTo(138, .001));
      expect(first.params['y'], closeTo(213, .001));

      mirror.host.calls.clear();
      await mirror.frames([const _Frame(
        _blue, Size(900, 1800), cssSize: Size(300, 600),
        browserZoom: 1.5, pageScaleFactor: 2,
      )]);
      await mirror.render(_blue, previous: fallback);
      final streamed = tester.getRect(find.byType(RawImage));
      await tester.tapAt(streamed.topLeft + Offset(streamed.width * .69, streamed.height * .21));
      await mirror.barrier();
      final next = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mousePressed');
      expect(next.params['x'], closeTo(207, .001));
      expect(next.params['y'], closeTo(126, .001));
    });
  });

  testWidgets('scrollbar-excluding CSS clients do not squeeze full captured surfaces',
      (tester) async {
    await _withMirror(tester, (mirror) async {
      // At pinch=2, the complete 800x400 surface spans 400x200 CSS pixels.
      // Classic scrollbars leave a smaller client, not a smaller screenshot.
      mirror.host.viewport = const Size(388, 188);
      mirror.host.pageScaleFactor = 2;
      mirror.host.screenshotData = _red;
      await mirror.pump(visible: false);
      await mirror.barrier();
      final starts = mirror.host.callsFor('Page.startScreencast').length;
      await mirror.pump(visible: true);
      await mirror.until(() => mirror.host.callsFor('Page.startScreencast').length > starts);
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.until(() => mirror.host.callsFor('Page.captureScreenshot').isNotEmpty);
      await mirror.render(_red);
      final screenshot = mirror.image;
      for (final stream in [false, true]) {
        if (stream) {
          await mirror.frames([const _Frame(_red, Size(800, 400),
              cssSize: Size(388, 188), pageScaleFactor: 2)]);
          await mirror.render(_red, previous: screenshot);
        }
        mirror.host.calls.clear();
        final drawn = tester.getRect(find.byType(RawImage));
        await tester.tapAt(drawn.topLeft + Offset(drawn.width * .73, drawn.height * .27));
        await mirror.barrier();
        final press = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mousePressed');
        expect(press.params['x'], closeTo(292, .001), reason: stream ? 'stream' : 'screenshot');
        expect(press.params['y'], closeTo(54, .001), reason: stream ? 'stream' : 'screenshot');
      }
    });
  });

  testWidgets('pending decode and pre-build completion keep input on painted pixels',
      (tester) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await mirror.render(_red);
      final before = mirror.image;
      final oldRect = tester.getRect(find.byType(RawImage));
      final oldPoint = oldRect.topLeft + Offset(oldRect.width * .85, oldRect.height * .25);
      final pending = Completer<ui.Image>();
      var decoding = false;
      mirror.frameDecoder = (bytes) {
        expect(base64Encode(bytes), _blue);
        decoding = true;
        return pending.future;
      };
      await mirror.pump();
      try {
        // CSS dimensions stay fixed while the encoded aspect changes. This
        // isolates decode/display pairing from the separate zoom invalidation.
        await mirror.frames([const _Frame(
          _blue, Size(800, 400), cssSize: Size(800, 400),
        )]);
        await mirror.until(() => decoding);
        expect(mirror.image, same(before));
        expect(tester.getRect(find.byType(RawImage)), oldRect);
        mirror.host.calls.clear();
        await tester.tapAt(oldPoint);
        await mirror.barrier();
        final held = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mousePressed');
        expect(held.params['x'], closeTo(680, .001));
        expect(held.params['y'], closeTo(100, .001));

        final metrics = mirror.host.callsFor('Page.getLayoutMetrics').length;
        await mirror.io(() async {
          final codec = await ui.instantiateImageCodec(base64Decode(_blue));
          try {
            pending.complete((await codec.getNextFrame()).image);
          } finally {
            codec.dispose();
          }
        });
        // Process the post-decode CDP metrics, but deliberately do not pump a
        // Flutter frame. The old rendered picture still defines the hit area.
        await mirror.untilWithoutRendering(() =>
            mirror.host.callsFor('Page.getLayoutMetrics').length > metrics);
        await mirror.barrier();
        expect(mirror.image, same(before));
        mirror.host.calls.clear();
        await tester.tapAt(oldPoint);
        await mirror.barrier();
        final beforeBuild = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mousePressed');
        expect(beforeBuild.params['x'], closeTo(680, .001));
        expect(beforeBuild.params['y'], closeTo(100, .001));

        await mirror.render(_blue, previous: before);
        final drawn = tester.getRect(find.byType(RawImage));
        expect(drawn, isNot(oldRect));
        mirror.host.calls.clear();
        await tester.tapAt(drawn.topLeft + Offset(drawn.width * .75, drawn.height * .25));
        await mirror.barrier();
        final afterBuild = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mousePressed');
        expect(afterBuild.params['x'], closeTo(600, .001));
        expect(afterBuild.params['y'], closeTo(100, .001));
      } finally {
        if (decoding && !pending.isCompleted) {
          pending.completeError(const FormatException('test ended'));
        }
      }
    });
  });

  testWidgets('zoom changes block stale-picture input until a fresh stream frame',
      (tester) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await mirror.render(_red);
      final before = mirror.image;
      final oldPoint = tester.getCenter(find.byType(RawImage));
      final starts = mirror.host.callsFor('Page.startScreencast').length;
      final oldTimestamp = mirror.host.wallSeconds + .01;
      const changed = _Frame(_blue, Size(800, 400),
          cssSize: Size(400, 200), browserZoom: 2);
      await mirror.frames([changed]);
      await mirror.until(() => mirror.host.callsFor('Page.startScreencast').length > starts);
      expect(mirror.image, same(before));
      final metrics = mirror.host.callsFor('Page.getLayoutMetrics').length;
      await mirror.frames([_Frame(_red, const Size(800, 400),
          timestamp: oldTimestamp, updateViewport: false)]);
      await tester.pump();
      await mirror.barrier();
      expect(mirror.image, same(before));
      expect(mirror.host.callsFor('Page.getLayoutMetrics'), hasLength(metrics),
          reason: 'An old encoder callback must not enter current-frame preparation.');
      mirror.host.calls.clear();
      await tester.tapAt(oldPoint);
      await tester.sendEventToBinding(PointerScrollEvent(
        position: oldPoint, scrollDelta: const Offset(0, 20),
      ));
      await mirror.barrier();
      expect(mirror.mouseCalls, isEmpty,
          reason: 'Old pixels must not act on the newly zoomed browser.');

      await mirror.frames([changed]);
      await mirror.render(_blue, previous: before);
      final drawn = tester.getRect(find.byType(RawImage));
      await tester.tapAt(drawn.topLeft + Offset(drawn.width * .31, drawn.height * .67));
      await mirror.barrier();
      final press = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mousePressed');
      expect(press.params['x'], closeTo(124, .001));
      expect(press.params['y'], closeTo(134, .001));
    });
  });

  for (final resizeDpr in [false, true]) {
    testWidgets('${resizeDpr ? 'DPR' : 'panel'} resize releases an active drag before invalidation',
        (tester) async {
      await _withMirror(tester, (mirror) async {
        await mirror.frames([const _Frame(_red, Size(800, 400))]);
        await mirror.render(_red);
        final before = mirror.image;
        final drawn = tester.getRect(find.byType(RawImage));
        final point = drawn.topLeft + Offset(drawn.width * .23, drawn.height * .31);
        mirror.host.calls.clear();
        final gesture = await tester.startGesture(point, kind: PointerDeviceKind.mouse);
        await mirror.barrier();
        await mirror.pump(
          ratio: resizeDpr ? 2 : 1,
          panelSize: resizeDpr ? null : const Size(640, 480),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await mirror.until(() => mirror.mouseCalls.any(
          (call) => call.params['type'] == 'mouseReleased',
        ));
        final release = mirror.mouseCalls.singleWhere(
          (call) => call.params['type'] == 'mouseReleased',
        );
        expect(release.tabId, 1);
        expect(release.params['button'], 'left');
        expect(release.params['buttons'], 0);
        // The release belongs to the original captured page, before its
        // capture generation is invalidated. Exact position is secondary to
        // releasing Chrome's held button when the Flutter layout has changed.
        await gesture.up();
        await mirror.barrier();
        expect(mirror.mouseCalls.where((call) => call.params['type'] == 'mouseReleased'),
            hasLength(1));
        mirror.host.calls.clear();
        await tester.tapAt(point);
        await tester.sendEventToBinding(PointerScrollEvent(
          position: point, scrollDelta: const Offset(0, 20),
        ));
        await mirror.barrier();
        expect(mirror.mouseCalls, isEmpty);
        await mirror.frames([const _Frame(_red, Size(800, 400))]);
        await mirror.render(_red, previous: before);
        await tester.tapAt(tester.getCenter(find.byType(RawImage)));
        await mirror.barrier();
        expect(mirror.mouseCalls.where((call) => call.params['type'] == 'mousePressed'),
            hasLength(1));
      });
    });
  }

  testWidgets('a decoded frame from a stopped capture cannot replace its successor',
      (tester) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await mirror.render(_red);
      final before = mirror.image;
      final pending = Completer<ui.Image>();
      var decoding = false;
      mirror.frameDecoder = (_) {
        decoding = true;
        return pending.future;
      };
      await mirror.pump();
      try {
        await mirror.frames([const _Frame(_blue, Size(800, 400))]);
        await mirror.until(() => decoding);
        final starts = mirror.host.callsFor('Page.startScreencast').length;
        await mirror.pump(visible: false);
        await mirror.pump(visible: true);
        await mirror.until(() => mirror.host.callsFor('Page.startScreencast').length > starts);
        await mirror.io(() async {
          final codec = await ui.instantiateImageCodec(base64Decode(_blue));
          try {
            pending.complete((await codec.getNextFrame()).image);
          } finally {
            codec.dispose();
          }
        });
        await mirror.barrier();
        await tester.pump();
        expect(mirror.image, same(before));
        mirror.host.calls.clear();
        await tester.tapAt(tester.getCenter(find.byType(RawImage)));
        await mirror.barrier();
        expect(mirror.mouseCalls, isEmpty);
        mirror.frameDecoder = null;
        await mirror.pump();
        await mirror.frames([const _Frame(_red, Size(800, 400))]);
        await mirror.render(_red, previous: before);
        await tester.tapAt(tester.getCenter(find.byType(RawImage)));
        await mirror.barrier();
        expect(mirror.mouseCalls.where((call) => call.params['type'] == 'mousePressed'),
            hasLength(1));
      } finally {
        if (decoding && !pending.isCompleted) {
          pending.completeError(const FormatException('test ended'));
        }
      }
    });
  });

  testWidgets('a failed decode preserves the previous pixel and coordinate pair',
      (tester) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await mirror.render(_red);
      final before = mirror.image;
      final pending = Completer<ui.Image>();
      var decoding = false;
      mirror.frameDecoder = (_) {
        decoding = true;
        return pending.future;
      };
      await mirror.pump();
      try {
        await mirror.frames([const _Frame(_blue, Size(800, 400))]);
        await mirror.until(() => decoding);
        pending.completeError(const FormatException('deliberately invalid image'));
        await tester.idle();
        await tester.pump();
        expect(mirror.image, same(before));
        await mirror.expectImage(_red);
        mirror.host.calls.clear();
        final drawn = tester.getRect(find.byType(RawImage));
        await tester.tapAt(drawn.topLeft + Offset(drawn.width * .19, drawn.height * .61));
        await mirror.barrier();
        final press = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mousePressed');
        expect(press.params['x'], closeTo(152, .001));
        expect(press.params['y'], closeTo(244, .001));
        expect(tester.takeException(), isNull);
      } finally {
        if (decoding && !pending.isCompleted) {
          pending.completeError(const FormatException('test ended'));
        }
      }
    });
  });

  testWidgets('agent last-tab changes do not retarget the pinned mirror', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await mirror.render(_red);
      mirror.host.calls.clear();

      BrowserTools.lastTab.value = BrowserTab(mirror.connection, 2);
      await tester.pump();
      await mirror.io(() async {
        mirror.host.sendFrame(const _Frame(_blue, Size(400, 800)), tabId: 2);
      });
      await mirror.barrier();
      await tester.pump();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('browser-panel-address')),
      );
      expect(field.controller!.text, 'https://one.example/');
      await mirror.expectImage(_red);
      expect(mirror.selected, [BrowserTab(mirror.connection, 1)]);
      expect(mirror.host.calls.where((call) => call.tabId == 2), isEmpty);
    });
  });

  testWidgets('pre-cutoff encoded callbacks are ACKed but cannot become the first frame',
      (tester) async {
    await _withMirror(tester, (mirror) async {
      final metrics = mirror.host.callsFor('Page.getLayoutMetrics').length;
      await mirror.frames([
        _Frame(_red, const Size(800, 400),
            timestamp: mirror.host.wallSeconds - 1, updateViewport: false),
        _Frame(_red, const Size(800, 400),
            timestamp: mirror.host.wallSeconds + .0005, updateViewport: false),
      ]);
      await tester.pump();
      await mirror.barrier();
      expect(find.byType(RawImage), findsNothing);
      expect(mirror.host.callsFor('Page.getLayoutMetrics'), hasLength(metrics),
          reason: 'The pre-cutoff callback is not a current capture.');
      // The host always allocates a fresh sessionId when emitting a callback,
      // including the stale one above. Timestamp, not that ID, proves freshness.
      await mirror.frames([const _Frame(_blue, Size(400, 800))]);
      await mirror.render(_blue);
      mirror.host.calls.clear();
      await tester.tapAt(tester.getCenter(find.byType(RawImage)));
      await mirror.barrier();
      final press = mirror.mouseCalls.singleWhere((call) => call.params['type'] == 'mousePressed');
      expect(press.params['x'], closeTo(200, .001));
      expect(press.params['y'], closeTo(400, .001));
    });
  });

  testWidgets('frames can arrive before the startScreencast reply', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      final stops = mirror.host.callsFor('Page.stopScreencast').length;
      await mirror.pump(visible: false);
      await mirror.until(
        () => mirror.host.callsFor('Page.stopScreencast').length > stops,
      );
      mirror.host.viewport = const Size(800, 400);
      mirror.host.holdNextStart = true;
      await mirror.pump(visible: true);
      await mirror.until(() => mirror.host.pendingStarts.isNotEmpty);
      expect(mirror.host.pendingStarts, hasLength(1));

      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      expect(find.byType(RawImage), findsNothing);
      await mirror.render(_red);
      expect(
        mirror.host.pendingStarts,
        hasLength(1),
        reason: 'the frame was acknowledged and rendered before the start reply',
      );

      await mirror.io(() async {
        mirror.host.completeStarts();
      });
      await mirror.barrier();
      await tester.idle();
      expect(mirror.host.pendingStarts, isEmpty);
      await mirror.frames([const _Frame(_blue, Size(400, 800))]);
      await mirror.render(_blue);
    });
  });

  testWidgets('blank margins reject input and pointer cancel releases a drag', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      await mirror.frames([const _Frame(_blue, Size(400, 800))]);
      await mirror.render(_blue);
      final page = tester.getRect(mirror.pageListener);
      final margin = page.topLeft + Offset(2, page.height / 2);
      mirror.host.calls.clear();

      await tester.tapAt(margin);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: margin, scrollDelta: const Offset(0, 30)),
      );
      await mirror.barrier();
      expect(mirror.mouseCalls, isEmpty);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RawImage)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(margin);
      await gesture.cancel();
      await mirror.until(
        () => mirror.mouseCalls.any(
          (call) => call.params['type'] == 'mouseReleased',
        ),
      );
      final press = mirror.mouseCalls.singleWhere(
        (call) => call.params['type'] == 'mousePressed',
      );
      final release = mirror.mouseCalls.singleWhere(
        (call) => call.params['type'] == 'mouseReleased',
      );
      expect(press.tabId, 1);
      expect(release.tabId, 1);
      expect(release.params['button'], 'left');
      expect(release.params['buttons'], 0);
      expect(release.params['x'], 0);
      expect(release.params['y'], closeTo(400, 0.001));

      await tester.pumpWidget(const SizedBox.shrink());
      await mirror.barrier();
      expect(
        mirror.mouseCalls.where((call) => call.params['type'] == 'mouseReleased'),
        hasLength(1),
        reason: 'cancel cleared the capture; disposal must not release twice',
      );
    });
  });

  testWidgets('hidden TickerMode stops polling and resumes capture when shown', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      await mirror.pump(visible: false);
      await mirror.until(
        () => mirror.host.callsFor('Page.stopScreencast').isNotEmpty,
      );
      mirror.host.calls.clear();
      await tester.pump(const Duration(seconds: 3));
      await mirror.barrier();
      expect(mirror.host.callsFor('Page.getLayoutMetrics'), isEmpty);
      expect(mirror.host.callsFor('Page.captureScreenshot'), isEmpty);
      expect(mirror.host.callsFor('Page.startScreencast'), isEmpty);

      await mirror.pump(visible: true);
      await mirror.until(
        () => mirror.host.callsFor('Page.startScreencast').isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await mirror.until(
        () => mirror.host.callsFor('Page.captureScreenshot').isNotEmpty,
      );
      await mirror.barrier();
      await mirror.render(_blue);
    });
  });

  testWidgets('a screenshot from an old capture epoch cannot replace a new stream', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      mirror.host.holdScreenshots = true;
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.until(() => mirror.host.pendingScreenshots.isNotEmpty);

      await mirror.pump(visible: false);
      await mirror.barrier();
      mirror.host.calls.clear();
      await mirror.pump(visible: true);
      await mirror.until(
        () => mirror.host.callsFor('Page.startScreencast').isNotEmpty,
      );
      await mirror.frames([const _Frame(_blue, Size(400, 800))]);
      await mirror.render(_blue);
      final current = mirror.image;
      final metrics = mirror.host.callsFor('Page.getLayoutMetrics').length;

      await mirror.io(() async {
        mirror.host.completeScreenshots(_red);
      });
      await mirror.barrier();
      await tester.pump();
      expect(mirror.image, same(current));
      expect(mirror.host.callsFor('Page.getLayoutMetrics'), hasLength(metrics),
          reason: 'An obsolete screenshot must not issue follow-on CDP reads.');
      await mirror.expectImage(_blue);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('external detach stays silent until explicit Reconnect', (
    tester,
  ) async {
    await _withMirror(tester, (mirror) async {
      final control = BrowserAgentControl.instance;
      final target = BrowserTab(mirror.connection, 1);
      expect(control.manualControl, isTrue);
      mirror.host.holdScreenshots = true;
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.until(() => mirror.host.pendingScreenshots.isNotEmpty);
      await mirror.frames([const _Frame(_blue, Size(400, 800))]);
      await mirror.render(_blue);
      final beforeDetach = mirror.image;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RawImage)),
        kind: PointerDeviceKind.mouse,
      );
      await mirror.until(
        () => mirror.mouseCalls.any(
          (call) => call.params['type'] == 'mousePressed',
        ),
      );
      await mirror.barrier();
      mirror.host.calls.clear();

      void expectNoCdp(String phase) {
        expect(
          mirror.host.calls.where((call) => call.request['method'] == 'cdp'),
          isEmpty,
          reason: phase,
        );
        expect(control.isDetached(target), isTrue, reason: phase);
      }

      await mirror.io(() async {
        mirror.host.send({
          'type': 'event',
          'event': 'detached',
          'tabId': 1,
          'reason': 'canceled_by_user',
        });
        // A frame already in transit must not even be acknowledged: doing
        // so could attach the debugger again after the user cancelled it.
        mirror.host.sendFrame(const _Frame(_red, Size(800, 400)));
      });
      await mirror.barrier();
      await tester.pump();
      expectNoCdp('detach and stale frame must not release, ACK, or reattach');
      expect(mirror.image, same(beforeDetach));

      await gesture.cancel();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await mirror.barrier();
      expectNoCdp('capture cancellation, keyboard input, and blur stay local');

      await mirror.pump(visible: false, ratio: 2);
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.pump(visible: true, ratio: 2);
      await tester.pump(const Duration(seconds: 2));
      await mirror.barrier();
      expectNoCdp('visibility, DPR debounce, and polling cannot reconnect');

      await mirror.io(() async {
        mirror.host.completeScreenshots(_red);
        mirror.host.sendFrame(const _Frame(_red, Size(800, 400)));
      });
      await mirror.barrier();
      await tester.pump();
      expectNoCdp('late screenshot completion and further frames stay inert');
      expect(mirror.image, same(beforeDetach));

      final reconnect = find.byWidgetPredicate(
        (widget) => widget is IdeActionButton && widget.tooltip == 'Reconnect',
      );
      expect(reconnect, findsOneWidget);

      // Restoring a saved panel selection is passive, even if the entire
      // widget and its controller are recreated. It cannot undo cancellation.
      final previousState = tester.state(find.byType(BrowserMirror));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await mirror.barrier();
      expect(find.byType(BrowserMirror), findsNothing);
      expectNoCdp('unmount must not send teardown to the cancelled debugger');

      await mirror.pump(ratio: 2);
      await mirror.until(() => reconnect.evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      await mirror.barrier();
      expect(tester.state(find.byType(BrowserMirror)), isNot(same(previousState)));
      expect(reconnect, findsOneWidget);
      expectNoCdp('remounting the saved initialTab must preserve cancellation');
      final restoredAddress = tester.widget<TextField>(
        find.byKey(const ValueKey('browser-panel-address')),
      );
      expect(restoredAddress.controller!.text, 'https://one.example/');

      await tester.tap(reconnect);
      await mirror.until(
        () => mirror.host.callsFor('Page.startScreencast').isNotEmpty,
      );
      expect(control.isDetached(target), isFalse);
      expect(control.manualControl, isTrue, reason: 'Reconnect is not Resume');
      await mirror.frames([const _Frame(_red, Size(800, 400))]);
      await mirror.render(_red);
    });
  });

  for (final paused in [true, false]) {
    testWidgets(
      'Reconnect this chat changes only the dead binding while '
      '${paused ? 'paused' : 'resumed'}',
      (tester) async {
        await _withMirror(tester, (mirror) async {
          const sessionId = 'mirror-widget-test';
          final control = BrowserAgentControl.instance;
          final original = mirror.connection;
          if (!paused) {
            await tester.tap(find.text('Resume agent'));
            await tester.pump();
          }
          expect(control.manualControl, paused);
          expect(control.resolveBrowser(sessionId: sessionId), same(original));

          final (replacementHost, replacement) = await mirror.connectHost(
            'Replacement Chrome',
          );
          final target = BrowserTab(replacement, 1);
          expect(replacement, isNot(same(original)));
          await mirror.pump(initialTab: target);
          await mirror.until(
            () => replacementHost.callsFor('Page.startScreencast').isNotEmpty,
          );
          // Both connections expose tab 1. Viewing the second must not
          // silently replace this chat's original connection binding.
          expect(mirror.selected.last, target);
          expect(control.resolveBrowser(sessionId: sessionId), same(original));
          expect(find.textContaining('Agent is bound to'), findsOneWidget);
          expect(find.textContaining('explicitly shared tabs'), findsOneWidget);
          expect(find.text('Reconnect this chat'), findsNothing);

          await mirror.io(() async {
            mirror.host.destroy();
            await _waitUntil(() => !original.connected);
          });
          await mirror.until(
            () => find.text('Reconnect this chat').evaluate().isNotEmpty,
          );
          expect(control.canRebindSession(sessionId, target), isTrue);
          expect(
            () => control.resolveBrowser(sessionId: sessionId),
            throwsA(isA<BrowserControlError>()),
            reason: 'disconnect alone cannot fall back to the visible browser',
          );

          await tester.tap(find.text('Reconnect this chat'));
          await mirror.until(() => !control.canRebindSession(sessionId, target));
          expect(find.text('Reconnect this chat'), findsNothing);
          expect(find.textContaining('Agent is bound to'), findsNothing);
          expect(control.resolveBrowser(sessionId: sessionId), same(replacement));
          expect(control.manualControl, paused);

          BrowserConnection? routed;
          Future<void> probe() => control.runAgent<void>(
            sessionId: sessionId,
            action: () async {
              final browser = BrowserAgentControl.currentLease!.browser!;
              routed = browser;
              await browser.cdp(1, 'Runtime.evaluate', {
                'expression': '"reconnected-chat-test"',
              });
            },
          );

          if (paused) {
            await expectLater(probe(), throwsA(isA<BrowserControlError>()));
            expect(routed, isNull, reason: 'Reconnect this chat is not Resume');
            await tester.tap(find.text('Resume agent'));
            await tester.pump();
          }
          await mirror.transport(probe, label: 'reconnected agent probe');
          expect(routed, same(replacement));
          final probes = replacementHost.callsFor('Runtime.evaluate').where(
            (call) => call.params['expression'] == '"reconnected-chat-test"',
          );
          expect(probes, hasLength(1));
          expect(probes.single.tabId, 1);
          expect(
            mirror.host.callsFor('Runtime.evaluate').where(
              (call) => call.params['expression'] == '"reconnected-chat-test"',
            ),
            isEmpty,
          );
        });
      },
    );
  }
}

Future<void> _withMirror(
  WidgetTester tester,
  Future<void> Function(_MirrorHarness) test,
) async {
  final mirror = _MirrorHarness(tester);
  try {
    await mirror.open();
    await test(mirror);
  } finally {
    await mirror.close();
  }
}

class _MirrorHarness {
  _MirrorHarness(this.tester);

  final WidgetTester tester;
  final bridge = BrowserBridge.instance;
  final oldHome = BrowserBridge.home;
  final oldSocketFolder = BrowserBridge.socketFolder;
  final oldLoopback = BrowserBridge.loopback;
  final oldDataDirectory = DataDirectory.current;
  final oldLastTab = BrowserTools.lastTab.value;
  final selected = <BrowserTab>[];
  Future<ui.Image> Function(Uint8List)? frameDecoder;
  Directory? _temporary;
  _SocketHost? _host;
  final _additionalHosts = <_SocketHost>[];
  _SocketHost get host => _host!;
  late BrowserConnection connection;

  Finder get pageListener => find.descendant(
    of: find.byType(BrowserMirror),
    matching: find.byWidgetPredicate(
      (widget) => widget is Listener &&
          widget.onPointerHover != null &&
          widget.onPointerPanZoomUpdate != null,
    ),
  );

  ui.Image get image => tester.widget<RawImage>(find.byType(RawImage)).image!;

  Future<void> render(String data, {ui.Image? previous}) async {
    final expected = data == _red ? const Size(800, 400) : const Size(400, 800);
    var starts = host.callsFor('Page.startScreencast').length;
    for (var attempt = 0; attempt < 100; attempt++) {
      final found = find.byType(RawImage);
      if (found.evaluate().length == 1) {
        final decoded = tester.widget<RawImage>(found).image;
        if (decoded != null && !identical(decoded, previous) &&
            Size(decoded.width.toDouble(), decoded.height.toDouble()) == expected) {
          await expectImage(data);
          return;
        }
      }
      await tester.pump();
      await io(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      final latestStarts = host.callsFor('Page.startScreencast').length;
      if (latestStarts > starts && host.lastFrame?.data == data) {
        // Changed CSS metrics invalidate an in-flight capture. Model Chrome's
        // new post-restart frame, not permission to reinterpret the old one.
        starts = latestStarts;
        await frames([host.lastFrame!]);
      }
    }
    fail('The expected decoded frame never became visible.');
  }

  Future<void> expectImage(String data) async {
    final decoded = image;
    final expectedSize = data == _red ? const Size(800, 400) : const Size(400, 800);
    expect(Size(decoded.width.toDouble(), decoded.height.toDouble()), expectedSize);
    final rgba = (await tester.runAsync(
      () => decoded.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    expect(rgba.buffer.asUint8List(rgba.offsetInBytes, 4),
        data == _red ? [255, 0, 0, 255] : [0, 0, 255, 255]);
  }

  List<_Call> get mouseCalls => host.callsFor('Input.dispatchMouseEvent');

  Future<void> io(Future<void> Function() action) async {
    await tester.runAsync(action);
  }

  Future<void> open() async {
    _temporary = Directory.systemTemp.createTempSync('bao-mirror-');
    BrowserBridge.home = p.join(_temporary!.path, 'empty-home');
    BrowserBridge.socketFolder = _temporary!.path;
    BrowserBridge.loopback = true;
    DataDirectory.current = DataDirectory(p.join(_temporary!.path, 'data'));
    BrowserAgentControl.instance.resetForTesting();
    BrowserTools.lastTab.value = null;
    await io(() async {
      await bridge.start();
      _host = await _SocketHost.connect();
      await _waitUntil(() => bridge.browsers.length == 1);
      connection = bridge.browsers.single;
    });
    await pump();
    await until(() => host.callsFor('Page.startScreencast').isNotEmpty);
    // Finish the initial layout's resize debounce without firing the 300 ms
    // polling timer. Tests then control when fallback screenshots can start.
    final starts = host.callsFor('Page.startScreencast').length;
    await tester.pump(const Duration(milliseconds: 200));
    await until(() => host.callsFor('Page.startScreencast').length > starts);
  }

  Future<(_SocketHost, BrowserConnection)> connectHost(String name) async {
    late _SocketHost added;
    late BrowserConnection browser;
    await io(() async {
      added = await _SocketHost.connect(browserName: name);
      _additionalHosts.add(added);
      await _waitUntil(() => bridge.browsers.any((entry) => entry.browser == name));
      browser = bridge.browsers.singleWhere((entry) => entry.browser == name);
    });
    return (added, browser);
  }

  Future<void> pump({
    bool visible = true,
    double ratio = 1,
    BrowserTab? initialTab,
    Size? panelSize,
  }) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(devicePixelRatio: ratio),
        child: child!,
      ),
      home: Scaffold(
        body: SizedBox(
          width: panelSize?.width,
          height: panelSize?.height,
          child: TickerMode(
            enabled: visible,
            child: BrowserMirror(
              key: const ValueKey('test-browser-mirror'),
              sessionId: 'mirror-widget-test',
              frameDecoder: frameDecoder,
              initialTab: initialTab ?? BrowserTab(connection, 1),
              onSelectionChanged: selected.add,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> until(bool Function() done) async {
    for (var attempt = 0; attempt < 100 && !done(); attempt++) {
      await tester.pump();
      await io(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(done(), isTrue, reason: 'synthetic browser did not receive the request');
    await tester.pump();
  }

  Future<void> untilWithoutRendering(bool Function() done) async {
    for (var attempt = 0; attempt < 100 && !done(); attempt++) {
      await tester.idle();
      await io(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    await tester.idle();
    expect(done(), isTrue, reason: 'Asynchronous frame preparation did not settle.');
  }

  Future<void> transport(
    Future<void> Function() action, {
    required String label,
  }) async {
    var completed = false;
    Object? failure;
    StackTrace? failureStack;
    // Start in real I/O, but do not wait there: socket writes and response
    // continuations may also need the widget's fake microtask queue drained.
    await tester.runAsync(() async {
      unawaited(Future<void>.sync(action).then<void>(
        (_) {
          completed = true;
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
          failureStack = stack;
          completed = true;
        },
      ));
    });
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (!completed && DateTime.now().isBefore(end)) {
      await tester.idle();
      await io(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    await tester.idle();
    if (!completed || failure != null) {
      final originalFailure = failure;
      final originalStack = failureStack;
      final counts = [
        for (final host in [?_host, ..._additionalHosts]) host.calls.length,
      ];
      // Closing only this fixture's sockets settles pending requests before
      // another test can start; a timed-out continuation is not left running.
      await io(() async {
        for (final host in [?_host, ..._additionalHosts]) {
          host.destroy();
        }
        await bridge.stop();
      });
      await tester.idle();
      await io(() => Future<void>.delayed(Duration.zero));
      await tester.idle();
      if (originalFailure != null) {
        Error.throwWithStackTrace(originalFailure, originalStack!);
      }
      fail('$label did not complete within the fixture deadline; '
          'host request counts=$counts, settled after disconnect=$completed');
    }
  }

  Future<void> barrier({BrowserConnection? browser}) async {
    expect(BrowserAgentControl.currentLease, isNull);
    final target = browser ?? connection;
    await transport(() async {
      // Only the synthetic host implements this transport echo. This is not
      // CDP or a tabless browser observation, so it must not acquire authority
      // that a preceding detached event is supposed to revoke.
      await target.request(
        'test.transportBarrier',
        {'tabId': 1},
        const Duration(seconds: 3),
      );
    }, label: 'transport barrier (connected=${target.connected})');
  }

  Future<void> frames(List<_Frame> frames) async {
    final acknowledged = host.callsFor('Page.screencastFrameAck').length;
    final expected = acknowledged + frames.length;
    await io(() async {
      for (final frame in frames) {
        host.sendFrame(frame);
      }
    });
    // Socket I/O is real, but the mirror's listeners and buffered work can
    // schedule microtasks in widget FakeAsync. Waiting for every ACK inside
    // one runAsync blocks that queue. idle drains it without rendering or
    // advancing fake time, preserving the whole burst for one later pump.
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (host.callsFor('Page.screencastFrameAck').length < expected &&
        DateTime.now().isBefore(end)) {
      await tester.idle();
      await io(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    await tester.idle();
    final observed = host.callsFor('Page.screencastFrameAck').length;
    final requestCounts = <String, int>{};
    for (final call in host.calls) {
      requestCounts.update(call.method, (count) => count + 1, ifAbsent: () => 1);
    }
    final detached = BrowserAgentControl.instance.isDetached(
      BrowserTab(connection, 1),
    );
    expect(
      observed,
      expected,
      reason: 'Expected $expected total ACKs (${frames.length} new), '
          'observed $observed before rendering. '
          'Connected=${connection.connected}, detached=$detached, '
          'request counts=$requestCounts',
    );
  }

  Future<void> close() async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      // Flush the focus/click check timers after disposing the mirror itself.
      await tester.pump(const Duration(milliseconds: 100));
      final hosts = [?_host, ..._additionalHosts];
      try {
        await io(() async {
          for (final host in hosts) {
            host.completeStarts();
            host.completeScreenshots(_red);
          }
        });
        for (final browser in bridge.browsers) {
          await barrier(browser: browser);
        }
      } finally {
        await io(() async {
          try {
            await bridge.stop();
          } finally {
            for (final host in hosts) {
              host.destroy();
            }
          }
        });
        // Let completed CDP futures cancel their request timeout timers.
        await tester.pump();
      }
    } finally {
      BrowserAgentControl.instance.resetForTesting();
      BrowserTools.lastTab.value = oldLastTab;
      BrowserBridge.home = oldHome;
      BrowserBridge.socketFolder = oldSocketFolder;
      BrowserBridge.loopback = oldLoopback;
      DataDirectory.current = oldDataDirectory;
      _temporary?.deleteSync(recursive: true);
    }
  }
}

Future<void> _waitUntil(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'synthetic browser handshake or frame timed out');
}

class _Frame {
  const _Frame(this.data, this.size, {
    this.cssSize,
    this.pageScaleFactor = 1,
    this.browserZoom = 1,
    this.timestamp,
    this.updateViewport = true,
  });

  final String data;
  final Size size;
  final Size? cssSize;
  final double pageScaleFactor;
  final double browserZoom;
  final double? timestamp;
  final bool updateViewport;
}

class _Call {
  _Call(this.request);

  final Map<String, Object?> request;
  Map<String, Object?> get outerParams =>
      (request['params'] as Map).cast<String, Object?>();
  String get method => request['method'] == 'cdp'
      ? outerParams['method'] as String
      : request['method'] as String;
  int? get tabId => outerParams['tabId'] as int?;
  Map<String, Object?> get params => request['method'] == 'cdp'
      ? (outerParams['params'] as Map).cast<String, Object?>()
      : outerParams;
}

/// A native host speaking only to this test's real bridge over loopback.
class _SocketHost {
  _SocketHost(this.socket) {
    socket.listen(_read);
  }

  final Socket socket;
  final calls = <_Call>[];
  final pendingStarts = <Map<String, Object?>>[];
  final pendingScreenshots = <Map<String, Object?>>[];
  final _buffer = <int>[];
  _Frame? lastFrame;
  var screenshotData = _blue;
  var viewport = const Size(400, 800);
  var browserZoom = 1.0;
  var pixelRatio = 1.0;
  var pageScaleFactor = 1.0;
  var wallSeconds = 1000.0;
  var holdScreenshots = false;
  var holdNextStart = false;
  var _frameId = 0;
  var _destroyed = false;

  static Future<_SocketHost> connect({
    String browserName = 'Synthetic Chrome',
  }) async {
    final [port, token] = File(BrowserBridge.portPath)
        .readAsStringSync()
        .split(' ');
    final host = _SocketHost(
      await Socket.connect(InternetAddress.loopbackIPv4, int.parse(port)),
    );
    host.send({
      'type': 'hello',
      'origin': 'chrome-extension://${BrowserBridge.extensionIds.first}/',
      'token': token,
    });
    host.send({
      'type': 'hello',
      'browser': browserName,
      'protocol': BrowserBridge.protocol,
    });
    return host;
  }

  List<_Call> callsFor(String method) =>
      calls.where((call) => call.method == method).toList();

  void send(Map<String, Object?> message) {
    if (_destroyed) return;
    // Do not flush this live duplex sink: _read can write a reply while
    // flush temporarily binds it. Handshake, ACKs and reply barriers below
    // establish delivery without racing those writes.
    final body = utf8.encode(jsonEncode(message));
    socket
      ..add(
        (ByteData(4)..setUint32(0, body.length, Endian.little))
            .buffer
            .asUint8List(),
      )
      ..add(body);
  }

  void sendFrame(_Frame frame, {int tabId = 1}) {
    if (tabId == 1 && frame.updateViewport) {
      lastFrame = frame;
      viewport = frame.cssSize ?? frame.size;
      browserZoom = frame.browserZoom;
      pixelRatio = frame.browserZoom;
      pageScaleFactor = frame.pageScaleFactor;
    }
    send({
      'type': 'event',
      'event': 'cdp',
      'tabId': tabId,
      'method': 'Page.screencastFrame',
      'params': {
        'sessionId': ++_frameId,
        'data': frame.data,
        'metadata': {
          'deviceWidth': frame.size.width,
          'deviceHeight': frame.size.height,
          'pageScaleFactor': frame.pageScaleFactor,
          'offsetTop': 0,
          'timestamp': frame.timestamp ?? wallSeconds + .01,
          'scrollOffsetX': 0,
          'scrollOffsetY': 0,
        },
      },
    });
  }

  void _read(Uint8List bytes) {
    _buffer.addAll(bytes);
    while (_buffer.length >= 4) {
      final length = ByteData.sublistView(
        Uint8List.fromList(_buffer.sublist(0, 4)),
      ).getUint32(0, Endian.little);
      if (_buffer.length < length + 4) return;
      final request = (jsonDecode(
        utf8.decode(_buffer.sublist(4, length + 4)),
      ) as Map).cast<String, Object?>();
      _buffer.removeRange(0, length + 4);
      final call = _Call(request);
      calls.add(call);
      if (call.method == 'Page.startScreencast' && holdNextStart) {
        holdNextStart = false;
        pendingStarts.add(request);
        continue;
      }
      if (call.method == 'Page.captureScreenshot' && holdScreenshots) {
        pendingScreenshots.add(request);
        continue;
      }
      final Object result = switch (call.method) {
        'tabs.list' => [
          {'tabId': 1, 'title': 'Human page', 'url': 'https://one.example/'},
          {'tabId': 2, 'title': 'Agent page', 'url': 'https://two.example/'},
        ],
        'Page.getLayoutMetrics' => {
          'visualViewport': {
            'clientWidth': viewport.width * pixelRatio,
            'clientHeight': viewport.height * pixelRatio,
            'scale': pageScaleFactor,
          },
          'cssVisualViewport': {
            'pageX': 0,
            'pageY': 0,
            'clientWidth': viewport.width,
            'clientHeight': viewport.height,
            'zoom': browserZoom,
            'scale': pageScaleFactor,
          },
        },
        'Page.captureScreenshot' => {'data': screenshotData},
        'Runtime.evaluate' => {
          'result': {
            'value': call.params['expression'] == 'Date.now() / 1000'
                ? ++wallSeconds : false,
          },
        },
        _ => <String, Object?>{},
      };
      send({'id': request['id'], 'result': result});
    }
  }

  void completeScreenshots(String data) {
    for (final request in pendingScreenshots) {
      send({'id': request['id'], 'result': {'data': data}});
    }
    pendingScreenshots.clear();
  }

  void completeStarts() {
    for (final request in pendingStarts) {
      send({'id': request['id'], 'result': <String, Object?>{}});
    }
    pendingStarts.clear();
  }

  void destroy() {
    _destroyed = true;
    pendingStarts.clear();
    pendingScreenshots.clear();
    socket.destroy();
  }
}
