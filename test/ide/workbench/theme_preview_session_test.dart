import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:baocode/ide/ide_color_theme_picker.dart';
import 'package:baocode/ide/ide_theme_preview_session.dart';

class _Themes implements IdeColorThemeController {
  @override
  String colorThemeId = 'original';
  @override
  List<IdeColorThemeEntry> get colorThemes => const [];
  final calls = <(String, bool)>[];
  final persisted = <String>[];
  Completer<void>? gate;
  String? fails;

  @override
  Future<void> setColorTheme(String id, {bool preview = false}) async {
    calls.add((id, preview));
    final wait = gate;
    gate = null;
    await wait?.future;
    if (id == fails) throw StateError('Unreadable theme');
    colorThemeId = id;
    if (!preview) persisted.add(id);
  }
}

void main() {
  test('preview and cancellation never persist a preference', () async {
    final themes = _Themes();
    final session = IdeThemePreviewSession(themes);
    await session.select('a');
    expect(themes.colorThemeId, 'a');
    await session.cancel();
    expect(themes.colorThemeId, 'original');
    expect(themes.persisted, isEmpty);
    session.dispose();
  });

  test('rapid selection skips superseded queued loads', () async {
    final themes = _Themes();
    final session = IdeThemePreviewSession(themes);
    final first = session.select('a');
    final second = session.select('b');
    await Future.wait([first, second]);
    expect(themes.calls, [('b', true)]);
    expect(themes.colorThemeId, 'b');
    session.dispose();
  });

  test('cancel waits behind an in-flight preview and wins', () async {
    final themes = _Themes();
    final gate = themes.gate = Completer<void>();
    final session = IdeThemePreviewSession(themes);
    final preview = session.select('a');
    await Future<void>.delayed(Duration.zero);
    final cancel = session.cancel();
    gate.complete();
    await Future.wait([preview, cancel]);
    expect(themes.calls, [('a', true), ('original', true)]);
    expect(themes.colorThemeId, 'original');
    expect(themes.persisted, isEmpty);
    session.dispose();
  });

  test(
    'apply wins over pending previews, persists once and prevents rollback',
    () async {
      final themes = _Themes();
      final gate = themes.gate = Completer<void>();
      final session = IdeThemePreviewSession(themes);
      final preview = session.select('a');
      await Future<void>.delayed(Duration.zero);
      final next = session.select('b');
      final applied = session.apply();
      expect(await session.apply(), isFalse);
      gate.complete();
      await Future.wait([preview, next]);
      expect(await applied, isTrue);
      await session.cancel();
      expect(themes.persisted, ['b']);
      expect(themes.colorThemeId, 'b');
      session.dispose();
    },
  );

  test(
    'failed preview restores original without saving and remains usable',
    () async {
      final themes = _Themes()..fails = 'bad';
      final session = IdeThemePreviewSession(themes);
      await session.select('bad');
      expect(session.error, isA<StateError>());
      expect(themes.colorThemeId, 'original');
      expect(themes.persisted, isEmpty);
      await session.select('good');
      expect(session.error, isNull);
      expect(await session.apply(), isTrue);
      expect(themes.persisted, ['good']);
      session.dispose();
    },
  );

  test('failed Apply stays open and can cancel', () async {
    final themes = _Themes();
    final session = IdeThemePreviewSession(themes);
    await session.select('a');
    themes.fails = 'a';
    expect(await session.apply(), isFalse);
    expect(session.busy, isFalse);
    await session.cancel();
    expect(themes.colorThemeId, 'original');
    session.dispose();
  });

  test(
    'completion after widget disposal never notifies disposed listeners',
    () async {
      final themes = _Themes();
      final gate = themes.gate = Completer<void>();
      final session = IdeThemePreviewSession(themes);
      final preview = session.select('a');
      await Future<void>.delayed(Duration.zero);
      final cancel = session.cancel();
      session.dispose();
      gate.complete();
      await Future.wait([preview, cancel]);
      expect(themes.colorThemeId, 'original');
    },
  );
  test(
    'typography preview restores its snapshot on Cancel without saving',
    () async {
      final typography = ValueNotifier<bool>(true);
      final saves = <bool>[];
      final session = IdeThemePreviewSession(
        _Themes(),
        typographyPreset: typography,
        persistTypographyPreset: (enabled) async => saves.add(enabled),
      );
      session.setTypographyEnabled(false);
      expect(typography.value, isFalse);
      expect(saves, isEmpty);
      await session.cancel();
      expect(typography.value, isTrue);
      expect(saves, isEmpty);
      session.dispose();
      typography.dispose();
    },
  );

  test(
    'Apply keeps typography and subsequent cleanup does not reset it',
    () async {
      final typography = ValueNotifier<bool>(false);
      final saves = <bool>[];
      final session = IdeThemePreviewSession(
        _Themes(),
        typographyPreset: typography,
        persistTypographyPreset: (enabled) async => saves.add(enabled),
      );
      session.setTypographyEnabled(true);
      expect(await session.apply(), isTrue);
      await session.cancel();
      expect(typography.value, isTrue);
      expect(saves, [true]);
      session.dispose();
      typography.dispose();
    },
  );

  test(
    'failed typography persistence rolls back the committed palette',
    () async {
      final typography = ValueNotifier<bool>(false);
      final themes = _Themes();
      final session = IdeThemePreviewSession(
        themes,
        typographyPreset: typography,
        persistTypographyPreset: (_) async =>
            throw StateError('Cannot write settings'),
      );
      await session.select('new');
      session.setTypographyEnabled(true);
      expect(await session.apply(), isFalse);
      expect(themes.colorThemeId, 'original');
      expect(themes.persisted, ['new', 'original']);
      expect(session.error, isA<StateError>());
      await session.cancel();
      expect(typography.value, isFalse);
      session.dispose();
      typography.dispose();
    },
  );

  test(
    'route removed during Apply restores typography and saved palette',
    () async {
      final typography = ValueNotifier<bool>(false);
      final saves = <bool>[];
      final themes = _Themes();
      final session = IdeThemePreviewSession(
        themes,
        typographyPreset: typography,
        persistTypographyPreset: (enabled) async => saves.add(enabled),
      );
      await session.select('new');
      session.setTypographyEnabled(true);
      final gate = themes.gate = Completer<void>();
      final apply = session.apply();
      await Future<void>.delayed(Duration.zero);
      final cancel = session.cancel();
      gate.complete();
      expect(await apply, isFalse);
      await cancel;
      expect(typography.value, isFalse);
      expect(saves, [true, false]);
      expect(themes.persisted, ['new', 'original']);
      expect(themes.colorThemeId, 'original');
      session.dispose();
      typography.dispose();
    },
  );
}
