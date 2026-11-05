import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Brightness;

import 'package:baocode/ide/ide_color_theme_picker.dart';
import 'package:baocode/ide/ide_theme_preview_session.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/theme/code_font.dart';
import 'package:baocode/theme/pebrel_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Storage implements ColorThemeStorage {
  @override
  String colorThemeSetting = 'Pebrel Nord';
  @override
  String? colorThemeData;
  @override
  bool autoDetectColorScheme = true;
  final writes = <(String, bool)>[];
  Completer<void>? gate;

  @override
  Future<void> storeColorTheme({
    required String setting,
    String? data,
    bool autoDetectColorScheme = false,
    bool cacheOnly = false,
  }) async {
    if (!cacheOnly) {
      final pending = gate;
      gate = null;
      await pending?.future;
      colorThemeSetting = setting;
      this.autoDetectColorScheme = autoDetectColorScheme;
      writes.add((setting, autoDetectColorScheme));
    }
    colorThemeData = data;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<WorkbenchThemeService> automatic([ColorThemeStorage? storage]) async {
    final themes = WorkbenchThemeService()
      ..restore(
        setting: 'Pebrel Nord',
        autoDetectColorScheme: true,
        brightness: Brightness.light,
      )
      ..storage = storage;
    addTearDown(themes.dispose);
    await themes.initialize();
    return themes;
  }

  test(
    'gallery Cancel clears the preview and resumes Auto at current brightness',
    () async {
      final storage = _Storage();
      final themes = await automatic(storage);
      final session = IdeThemePreviewSession(themes);
      addTearDown(session.dispose);
      await session.select('Pebrel Warm Sand');
      await themes.setPlatformBrightness(Brightness.dark);
      expect(themes.colorThemeId, 'Pebrel Warm Sand');
      await session.cancel();
      expect(themes.colorThemeId, IdeColorThemeController.autoId);
      expect(themes.colorTheme.settingsId, 'Bao Dark');
      expect(themes.colorThemeSetting, 'Pebrel Nord');
      expect(storage.writes, isEmpty);
      // A lingering preview would prevent this subsequent system change.
      await themes.setPlatformBrightness(Brightness.light);
      expect(themes.colorTheme.settingsId, 'Bao Light');
    },
  );

  test(
    'failed typography Apply restores both the fixed preference and Auto',
    () async {
      final storage = _Storage();
      final themes = await automatic(storage);
      final typography = ValueNotifier(false);
      addTearDown(typography.dispose);
      final session = IdeThemePreviewSession(
        themes,
        typographyPreset: typography,
        persistTypographyPreset: (_) async => throw StateError('Write failed'),
      );
      addTearDown(session.dispose);
      await session.select('Pebrel Warm Sand');
      session.setTypographyEnabled(true);
      expect(await session.apply(), isFalse);
      expect(storage.writes, [
        ('Pebrel Warm Sand', false),
        ('Pebrel Nord', true),
      ]);
      expect(storage.colorThemeSetting, 'Pebrel Nord');
      expect(storage.autoDetectColorScheme, isTrue);
      expect(themes.colorThemeId, IdeColorThemeController.autoId);
      await session.cancel();
      expect(typography.value, isFalse);
      expect(storage.writes, hasLength(2));
    },
  );

  test(
    'failed Apply restores real JSON settings with Auto and comments intact',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'theme_rollback_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final settings = UserSettings('${directory.path}/settings.json');
      addTearDown(settings.dispose);
      await settings.writeText(
        '// Keep this comment\n{\n'
        '  "workbench.colorTheme": "Pebrel Nord",\n'
        '  "window.autoDetectColorScheme": true,\n'
        '  "editor.fontSize": 20\n}\n',
      );
      final storage = ColorThemeSettings(settings: settings, state: _Storage());
      addTearDown(storage.dispose);
      final themes = await automatic(storage);
      storage.follow(themes);
      final typography = ValueNotifier(false);
      addTearDown(typography.dispose);
      final session = IdeThemePreviewSession(
        themes,
        typographyPreset: typography,
        persistTypographyPreset: (_) async => throw StateError('Write failed'),
      );
      addTearDown(session.dispose);
      await session.select('Pebrel Warm Sand');
      session.setTypographyEnabled(true);
      expect(await session.apply(), isFalse);
      expect(settings['workbench.colorTheme'], 'Pebrel Nord');
      expect(settings['window.autoDetectColorScheme'], isTrue);
      expect(settings['editor.fontSize'], 20);
      expect(await settings.readText(), contains('// Keep this comment'));
      expect(themes.colorThemeId, IdeColorThemeController.autoId);
      expect(themes.colorThemeSetting, 'Pebrel Nord');
      await session.cancel();
    },
  );

  test(
    'route removal during Apply restores the complete Auto snapshot',
    () async {
      final storage = _Storage();
      final themes = await automatic(storage);
      final session = IdeThemePreviewSession(themes);
      addTearDown(session.dispose);
      await session.select('Pebrel Warm Sand');
      final gate = storage.gate = Completer<void>();
      final apply = session.apply();
      await Future<void>.delayed(Duration.zero);
      final cancel = session.cancel();
      gate.complete();
      expect(await apply, isFalse);
      await cancel;
      expect(storage.writes, [
        ('Pebrel Warm Sand', false),
        ('Pebrel Nord', true),
      ]);
      expect(themes.colorThemeId, IdeColorThemeController.autoId);
      expect(themes.colorThemeSetting, 'Pebrel Nord');
    },
  );

  test(
    'custom library refresh and removal never turn Auto into a fixed preview',
    () async {
      final themes = await automatic();
      final catalog = jsonDecode(
        File('assets/pebrel/catalog.json').readAsStringSync(),
      ) as Map;
      final definition = PebrelThemeDefinition.fromJson(
        Map<String, dynamic>.from((catalog['themes'] as List).first as Map),
      );
      const id = 'Pebrel Custom 22222222222222222222222222222222';
      await themes.setCustomPebrelThemes({id: definition});
      await themes.setColorTheme(id, preview: true);
      await themes.setCustomPebrelThemes({id: definition});
      expect(themes.colorThemeId, id);
      expect(themes.autoDetectColorScheme, isTrue);
      expect(themes.colorThemeSetting, 'Pebrel Nord');
      await themes.setCustomPebrelThemes({});
      expect(themes.colorThemeId, IdeColorThemeController.autoId);
      await themes.setPlatformBrightness(Brightness.dark);
      expect(themes.colorTheme.settingsId, 'Bao Dark');
    },
  );

  test(
    'Auto and Pebrel transitions preserve global font and explicit sizes',
    () async {
      final original = (
        CodeFont.mapleFont.value,
        CodeFont.families.value,
        CodeFont.size.value,
        CodeFont.terminalSize.value,
        CodeFont.uiScale.value,
      );
      addTearDown(() {
        CodeFont.mapleFont.value = original.$1;
        CodeFont.families.value = original.$2;
        CodeFont.size.value = original.$3;
        CodeFont.terminalSize.value = original.$4;
        CodeFont.uiScale.value = original.$5;
      });
      CodeFont.mapleFont.value = true;
      CodeFont.families.value = ['User Custom Font', 'monospace'];
      CodeFont.size.value = 20;
      CodeFont.terminalSize.value = 18;
      CodeFont.uiScale.value = 125;
      final themes = await automatic();
      await themes.setPlatformBrightness(Brightness.dark);
      await themes.setColorTheme('Pebrel Warm Sand', preview: true);
      await themes.restoreColorThemePreview();
      expect(CodeFont.mapleFont.value, isTrue);
      expect(CodeFont.families.value, ['User Custom Font', 'monospace']);
      expect(CodeFont.size.value, 20);
      expect(CodeFont.terminalSize.value, 18);
      expect(CodeFont.uiScale.value, 125);
    },
  );
}
