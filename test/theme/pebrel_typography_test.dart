import 'dart:convert';
import 'dart:io';

import 'package:baocode/ide/ide_theme_preview_session.dart';
import 'package:baocode/ide/terminal/terminal_instance.dart';
import 'package:baocode/ide/terminal/terminal_render_metrics.dart';
import 'package:baocode/ide/terminal/terminal_render_theme.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/code_font.dart';
import 'package:baocode/theme/pebrel_theme.dart';
import 'package:baocode/theme/pebrel_typography.dart';
import 'package:baocode/theme/pixel_snapped_text_scaler.dart';
import 'package:baocode/theme/ui_zoom.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ide/terminal/fake_terminal.dart';

Map<String, dynamic> _snapshot([Map<String, dynamic>? typography]) {
  final catalog =
      jsonDecode(File('assets/pebrel/catalog.json').readAsStringSync()) as Map;
  final raw = Map<String, dynamic>.from(
    (catalog['themes'] as List).first as Map,
  );
  if (typography != null) raw['typography'] = typography;
  return raw;
}

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();

  @override
  double scale(double size) => size * (size < 20 ? 1.5 : 1.2);

  @override
  @Deprecated('Use scale instead.')
  double get textScaleFactor => 1.5;
}

// Match Theme.of: Material text geometry is merged for the current script.
// Raw ThemeData text styles contain colors/families but may have no font size.
double _localizedUiFontSize() {
  final theme = buildAppTheme();
  final localized = ThemeData.localize(theme, theme.typography.englishLike);
  return localized.textTheme.bodyMedium!.fontSize!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WorkbenchThemeService original;
  late WorkbenchThemeService themes;
  late int originalZoom;

  setUp(() async {
    original = WorkbenchThemeService.instance;
    originalZoom = CodeFont.uiScale.value;
    themes = WorkbenchThemeService();
    WorkbenchThemeService.instance = themes;
    await themes.initialize();
    CodeFont.mapleFont.value = false;
    CodeFont.families.value = ['User Font', 'Consolas'];
    CodeFont.size.value = 17;
    CodeFont.terminalSize.value = 19;
    CodeFont.ligatures.value = false;
    CodeFont.uiScale.value = 125;
  });

  tearDown(() {
    WorkbenchThemeService.instance = original;
    themes.dispose();
    CodeFont.mapleFont.value = false;
    CodeFont.families.value = CodeFont.defaultFamilies;
    CodeFont.size.value = CodeFont.defaultSize;
    CodeFont.terminalSize.value = null;
    CodeFont.ligatures.value = true;
    CodeFont.uiScale.value = originalZoom;
  });

  test(
    'global Maple changes only families across ordinary and Pebrel themes',
    () async {
      for (final id in ['Bao Dark', 'Pebrel Nord', 'Bao Light']) {
        await themes.setColorTheme(id, preview: true);
        final bodySize = buildAppTheme().textTheme.bodyMedium!.fontSize;
        CodeFont.mapleFont.value = true;
        expect(CodeFont.effectiveFamilies.first, 'Maple Mono Normal NF CN');
        expect(
          CodeFont.effectiveFamilies,
          containsAll(['User Font', 'Consolas']),
        );
        expect(
          buildAppTheme().textTheme.bodyMedium!.fontFamily,
          'Maple Mono Normal NF CN',
        );
        expect(buildAppTheme().textTheme.bodyMedium!.fontSize, bodySize);
        expect(CodeFont.typography.size, isNull);
        expect(CodeFont.typography.uiSize, isNull);
        final style = AppFonts.codeStyle(13);
        expect(style.fontSize, 17);
        expect(style.fontWeight, isNull);
        expect(style.height, isNull);
        expect(style.letterSpacing, isNull);
        expect(style.fontFeatures, isNotNull);
        expect(vscodeTerminalFontSize(), 19);
        expect(CodeFont.uiScale.value, 125);
        expect(CodeFont.families.value, ['User Font', 'Consolas']);
        CodeFont.mapleFont.value = false;
        expect(CodeFont.effectiveFamilies, ['User Font', 'Consolas']);
        expect(AppFonts.codeStyle(13).fontSize, 17);
        expect(vscodeTerminalFontSize(), 19);
      }
    },
  );

  test(
    'font toggle preserves sizes with zoom, accessibility and pixel snapping',
    () async {
      await themes.setColorTheme('Pebrel Nord', preview: true);
      for (final zoom in [0.9, 1.0, 1.25, 1.5]) {
        for (final system in [
          TextScaler.noScaling,
          const TextScaler.linear(1.5),
          const TextScaler.linear(2),
          const _NonlinearScaler(),
        ]) {
          for (final dpr in [1.0, 1.25, 2.0]) {
            final media = UiZoom.zoomed(
              MediaQueryData(
                size: const Size(1200, 800),
                devicePixelRatio: dpr,
                textScaler: system,
              ),
              zoom,
            );
            final snapped = PixelSnappedTextScaler(
              media.textScaler,
              media.devicePixelRatio,
            );
            for (final scaler in [media.textScaler, snapped]) {
              CodeFont.mapleFont.value = false;
              final editorSize = scaler.scale(AppFonts.codeStyle(13).fontSize!);
              final inlineSize = scaler.scale(
                AppFonts.uiCodeStyle(12.5).fontSize!,
              );
              final uiSize = scaler.scale(_localizedUiFontSize());
              final terminalSize = vscodeTerminalFontSize(scaler, system);
              CodeFont.mapleFont.value = true;
              expect(
                scaler.scale(AppFonts.codeStyle(13).fontSize!),
                editorSize,
              );
              expect(
                scaler.scale(AppFonts.uiCodeStyle(12.5).fontSize!),
                inlineSize,
              );
              expect(
                scaler.scale(_localizedUiFontSize()),
                uiSize,
              );
              expect(vscodeTerminalFontSize(scaler, system), terminalSize);
              expect(CodeFont.typography.uiSize, isNull);
              expect(CodeFont.typography.size, isNull);
            }
          }
        }
      }
      // A settings change remains authoritative while the font is enabled.
      CodeFont.size.value = 22;
      CodeFont.terminalSize.value = 21;
      expect(AppFonts.codeStyle(13).fontSize, 22);
      expect(vscodeTerminalFontSize(), 21);
      CodeFont.terminalSize.value = null;
      expect(vscodeTerminalFontSize(), CodeFont.uiSized(terminalBaseFontSize));
    },
  );

  test(
    'new explicit false overrides old true without rewriting old settings',
    () {
      expect(CodeFont.parseMapleFont(null, null), isFalse);
      expect(CodeFont.parseMapleFont(null, true), isTrue);
      expect(CodeFont.parseMapleFont(false, true), isFalse);
      expect(CodeFont.parseMapleFont(true, false), isTrue);
      expect(identical(CodeFont.mapleFont, CodeFont.pebrelPreset), isTrue);
      final values = <String, Object?>{
        CodeFont.pebrelPresetSettingKey: true,
        CodeFont.sizeSettingKey: 17,
        CodeFont.terminalSizeSettingKey: 19,
        CodeFont.uiScaleSettingKey: 125,
      };
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      CodeFont.follow(changes, (key) => values[key]);
      expect(CodeFont.mapleFont.value, isTrue);
      values[CodeFont.mapleFontSettingKey] = false;
      changes.notifyListeners();
      expect(CodeFont.mapleFont.value, isFalse);
      expect(values[CodeFont.pebrelPresetSettingKey], isTrue);
      expect(CodeFont.size.value, 17);
      expect(CodeFont.terminalSize.value, 19);
      expect(CodeFont.uiScale.value, 125);
    },
  );

  test(
    'imported sizes stay lossless but cannot override app size preferences',
    () async {
      final raw = _snapshot({
        'enabled': true,
        'font_family': 'Not installed, Consolas',
        'font_size': 31,
        'font_weight': 350,
        'line_height': .75,
        'letter_spacing': 2,
        'ligatures': false,
        'ui_font_family': 'Test UI',
        'ui_font_size': 20,
      });
      final definition = PebrelThemeDefinition.fromJson(raw);
      const id = 'Pebrel Custom 12345678901234567890123456789012';
      await themes.setCustomPebrelThemes({id: definition});
      await themes.setColorTheme(id, preview: true);
      for (final enabled in [false, true, false]) {
        CodeFont.mapleFont.value = enabled;
        expect(AppFonts.codeStyle(13).fontSize, 17);
        expect(vscodeTerminalFontSize(), 19);
        expect(CodeFont.typography.size, isNull);
        expect(CodeFont.typography.uiSize, isNull);
        expect(
          CodeFont.typography.family,
          enabled ? 'Maple Mono Normal NF CN' : 'Not installed, Consolas',
        );
        expect(CodeFont.typography.weight, 350);
        expect(CodeFont.typography.lineHeight, .75);
        expect(vscodeTerminalOptions().lineHeight, 1);
        expect(definition.toJson(), raw);
      }
      (raw['typography'] as Map)['enabled'] = false;
      final disabled = PebrelThemeDefinition.fromJson(raw);
      expect(PebrelTypography.resolve(disabled), same(PebrelTypography.none));
      expect(
        PebrelTypography.resolve(disabled, globalMapleFont: true),
        same(PebrelTypography.maple),
      );
    },
  );

  test(
    'cancel restores global font selection and original theme without writes',
    () async {
      for (final initial in [false, true]) {
        await themes.setColorTheme('Bao Dark', preview: true);
        CodeFont.mapleFont.value = initial;
        final writes = <bool>[];
        final session = IdeThemePreviewSession(
          themes,
          typographyPreset: CodeFont.mapleFont,
          persistTypographyPreset: (value) async => writes.add(value),
        );
        await session.select('Pebrel Nord');
        session.setTypographyEnabled(!initial);
        expect(AppFonts.codeStyle(13).fontSize, 17);
        await session.cancel();
        expect(themes.colorThemeId, 'Bao Dark');
        expect(CodeFont.mapleFont.value, initial);
        expect(AppFonts.codeStyle(13).fontSize, 17);
        expect(vscodeTerminalFontSize(), 19);
        expect(CodeFont.uiScale.value, 125);
        expect(writes, isEmpty);
        session.dispose();
      }
    },
  );

  test(
    'live terminals follow global family without changing their metrics',
    () async {
      final terminal = TerminalInstance(
        id: 777,
        root: '/project',
        backend: fakeTerminalBackend([]),
      );
      addTearDown(terminal.dispose);
      await pumpEventQueue();
      final originalFamily = terminal.xterm.options.fontFamily;
      for (final id in ['Bao Dark', 'Pebrel Nord', 'Bao Light']) {
        await themes.setColorTheme(id, preview: true);
        CodeFont.mapleFont.value = true;
        expect(
          terminal.xterm.options.fontFamily,
          startsWith("'Maple Mono Normal NF CN'"),
        );
        expect(terminal.xterm.options.fontSize, 19);
        expect(terminal.xterm.options.fontWeight, 'normal');
        expect(terminal.xterm.options.lineHeight, 1);
        expect(terminal.xterm.options.letterSpacing, 0);
        CodeFont.mapleFont.value = false;
        expect(terminal.xterm.options.fontFamily, originalFamily);
        expect(terminal.xterm.options.fontSize, 19);
      }
      expect(
        terminalFontFeatures.map((f) => f.feature),
        containsAll(['liga', 'calt']),
      );
    },
  );
}
