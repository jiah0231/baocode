import 'dart:convert';
import 'dart:io';

import 'package:baocode/ide/terminal/terminal_instance.dart';
import 'package:baocode/ide/terminal/terminal_render_metrics.dart';
import 'package:baocode/ide/terminal/terminal_render_theme.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/code_font.dart';
import 'package:baocode/theme/pebrel_theme.dart';
import 'package:baocode/theme/pebrel_typography.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WorkbenchThemeService original;
  late WorkbenchThemeService themes;

  setUp(() async {
    original = WorkbenchThemeService.instance;
    themes = WorkbenchThemeService();
    WorkbenchThemeService.instance = themes;
    await themes.initialize();
    CodeFont.pebrelPreset.value = false;
    CodeFont.families.value = ['User Font', 'Consolas'];
    CodeFont.size.value = 17;
    CodeFont.terminalSize.value = 19;
    CodeFont.ligatures.value = false;
  });

  tearDown(() {
    WorkbenchThemeService.instance = original;
    themes.dispose();
    CodeFont.pebrelPreset.value = false;
    CodeFont.families.value = CodeFont.defaultFamilies;
    CodeFont.size.value = CodeFont.defaultSize;
    CodeFont.terminalSize.value = null;
    CodeFont.ligatures.value = true;
  });

  test('built-in palettes contain no typography override', () async {
    await themes.setColorTheme('Pebrel Nord', preview: true);
    expect(CodeFont.typography.size, isNull);
    expect(CodeFont.effectiveFamilies, ['User Font', 'Consolas']);
    expect(CodeFont.sized(13), 17);
    expect(CodeFont.features, isNotNull);
    expect(vscodeTerminalFontSize(), 19);
  });

  test(
    'screenshot preset affects only Pebrel and never edits preferences',
    () async {
      CodeFont.pebrelPreset.value = true;
      expect(CodeFont.typography.size, isNull);
      await themes.setColorTheme('Pebrel Nord', preview: true);
      expect(CodeFont.typography.size, 15);
      expect(CodeFont.effectiveFamilies.first, 'Maple Mono Normal NF CN');
      expect(
        CodeFont.effectiveFamilies,
        containsAll(['User Font', 'Consolas', 'monospace']),
      );
      expect(CodeFont.families.value, ['User Font', 'Consolas']);
      expect(CodeFont.size.value, 17);
      expect(CodeFont.terminalSize.value, 19);
      expect(CodeFont.ligatures.value, isFalse);
      expect(vscodeTerminalFontSize(), 15);
      expect(
        buildAppTheme().textTheme.bodyMedium!.fontFamily,
        'Maple Mono Normal NF CN',
      );

      final style = AppFonts.codeStyle(13);
      final scaler = TypographyTextScaler(
        TextScaler.noScaling,
        CodeFont.uiTypographyScale,
      );
      expect(scaler.scale(style.fontSize!), closeTo(15, .0001));
      expect(style.fontWeight, FontWeight.w400);
      expect(style.height, 1.45);
      expect(style.letterSpacing, 0);
      expect(style.fontFeatures, isNull);
      // UI font size composes with accessibility, it does not reset zoom.
      expect(
        TypographyTextScaler(
          const TextScaler.linear(2),
          CodeFont.uiTypographyScale,
        ).scale(13),
        closeTo(30, 1e-10),
      );

      await themes.setColorTheme('Bao Dark', preview: true);
      expect(CodeFont.sized(13), 17);
      expect(CodeFont.features, isNotNull);
      expect(CodeFont.effectiveFamilies, ['User Font', 'Consolas']);
      expect(vscodeTerminalFontSize(), 19);
    },
  );

  test('explicit fields override preset, disabled fields remain lossless', () {
    final raw = _snapshot({
      'enabled': true,
      'font_family': 'Not installed, Consolas',
      'font_size': 16.5,
      'font_weight': 350,
      'line_height': .75,
      'letter_spacing': 2,
      'ligatures': false,
      'ui_font_family': 'Test UI',
      'ui_font_size': 14,
    });
    final definition = PebrelThemeDefinition.fromJson(raw);
    final typography = PebrelTypography.resolve(
      definition,
      screenshotPreset: true,
    );
    expect(typography.family, 'Not installed, Consolas');
    expect(typography.size, 16.5);
    expect(typography.weight, 350);
    expect(typography.lineHeight, .75);
    expect(typography.letterSpacing, 2);
    expect(typography.ligatures, isFalse);
    expect(typography.uiFamily, 'Test UI');
    expect(typography.uiSize, 14);
    (raw['typography'] as Map)['enabled'] = false;
    final disabled = PebrelThemeDefinition.fromJson(raw);
    expect(
      PebrelTypography.resolve(disabled, screenshotPreset: true),
      same(PebrelTypography.none),
    );
    expect(disabled.toJson(), raw);
    (raw['typography'] as Map)['enabled'] = 'false';
    expect(() => PebrelThemeDefinition.fromJson(raw), throwsFormatException);
  });

  test(
    'imported missing font falls back and terminal metrics are bounded',
    () async {
      final definition = PebrelThemeDefinition.fromJson(
        _snapshot({
          'enabled': true,
          'font_family': 'Definitely Missing Family 123',
          'font_size': 16.5,
          'font_weight': 350,
          'line_height': .75,
          'letter_spacing': 2,
          'ligatures': false,
        }),
      );
      const id = 'Pebrel Custom 12345678901234567890123456789012';
      await themes.setCustomPebrelThemes({id: definition});
      await themes.setColorTheme(id, preview: true);
      expect(
        CodeFont.effectiveFamilies,
        containsAllInOrder([
          'Definitely Missing Family 123',
          'User Font',
          'Consolas',
        ]),
      );
      final style = AppFonts.codeStyle(13);
      expect(style.fontSize, 16.5);
      expect(style.fontWeight, FontWeight.w400);
      expect(style.height, .75);
      expect(style.letterSpacing, 2);
      expect(style.fontFeatures, isNotNull);
      final options = vscodeTerminalOptions();
      expect(options.fontSize, 16.5);
      expect(options.fontWeight, 350);
      expect(options.lineHeight, 1);
      expect(options.letterSpacing, 2);
      expect(definition.typography['line_height'], .75);
      await themes.setCustomPebrelThemes({});
      expect(CodeFont.typography.size, isNull);
      expect(CodeFont.size.value, 17);
    },
  );

  test('null fields preserve settings and false ligatures is an override', () {
    final definition = PebrelThemeDefinition.fromJson(
      _snapshot({'ligatures': false}),
    );
    final typography = PebrelTypography.resolve(definition);
    expect(typography.size, isNull);
    expect(typography.family, isNull);
    expect(typography.ligatures, isFalse);
    expect(
      PebrelTypography.resolve(null, screenshotPreset: true),
      same(PebrelTypography.none),
    );
  });

  test('live terminal font metrics follow preview, cancellation and repeated toggles', () async {
    final terminal = TerminalInstance(
      id: 777,
      root: '/project',
      backend: fakeTerminalBackend([]),
    );
    addTearDown(terminal.dispose);
    await pumpEventQueue();
    final originalFamily = terminal.xterm.options.fontFamily;
    CodeFont.pebrelPreset.value = true;
    await themes.setColorTheme('Pebrel Nord', preview: true);
    expect(
      terminal.xterm.options.fontFamily,
      startsWith("'Maple Mono Normal NF CN'"),
    );
    expect(terminal.xterm.options.fontWeight, 400);
    expect(terminal.xterm.options.lineHeight, 1.45);
    expect(terminal.xterm.options.letterSpacing, 0);
    CodeFont.pebrelPreset.value = false;
    expect(terminal.xterm.options.fontFamily, originalFamily);
    expect(terminal.xterm.options.lineHeight, 1);
    CodeFont.pebrelPreset.value = true;
    await themes.setColorTheme('Bao Dark', preview: true);
    expect(terminal.xterm.options.fontFamily, originalFamily);
    expect(terminal.xterm.options.fontWeight, 'normal');
    // Cell-by-cell terminal shaping must never silently enable ligatures.
    expect(
      terminalFontFeatures.map((f) => f.feature),
      containsAll(['liga', 'calt']),
    );
    await themes.setColorTheme('Pebrel Nord', preview: true);
    expect(terminal.xterm.options.lineHeight, 1.45);
  });
}
