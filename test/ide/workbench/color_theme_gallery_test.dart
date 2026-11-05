import 'package:flutter/material.dart' hide ColorScheme;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_color_theme_gallery.dart';
import 'package:baocode/ide/ide_color_theme_picker.dart';
import 'package:baocode/theme/code_font.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/theme/workbench_theme.dart'
    show ColorScheme, WorkbenchThemeService;
import 'package:baocode/theme/app_theme.dart' show AppFonts;

class _Themes implements IdeColorThemeController {
  @override
  String colorThemeId = 'dark';
  @override
  final colorThemes = <IdeColorThemeEntry>[
    const IdeColorThemeEntry(
      id: 'dark',
      label: 'Dark garden',
      type: ColorScheme.dark,
    ),
    const IdeColorThemeEntry(
      id: 'light',
      label: 'Light garden',
      type: ColorScheme.light,
    ),
    const IdeColorThemeEntry(
      id: 'contrast',
      label: 'High contrast',
      type: ColorScheme.highContrastDark,
    ),
  ];
  final saved = <String>[];
  @override
  Future<void> setColorTheme(String id, {bool preview = false}) async {
    colorThemeId = id;
    if (!preview) saved.add(id);
  }
}

Future<void> _open(
  WidgetTester tester,
  IdeColorThemeController themes, {
  Future<String?> Function()? importTheme,
  UserSettings? settings,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: GestureDetector(
            onTap: () => showIdeColorThemeGallery(
              context,
              themes,
              importTheme: importTheme,
              settings: settings,
            ),
            child: const Text('Open gallery'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open gallery'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => CodeFont.mapleFont.value = false);
  tearDown(() => CodeFont.mapleFont.value = false);
  testWidgets(
    'filters keep high-contrast themes and Escape rolls back preview',
    (tester) async {
      final themes = _Themes();
      await _open(tester, themes);
      expect(find.text('Select to preview'), findsNWidgets(3));
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('theme-card-light')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-card-dark')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('theme-card-light')));
      await tester.pumpAndSettle();
      expect(themes.colorThemeId, 'light');
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('theme-card-contrast')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(IdeColorThemeGallery), findsNothing);
      expect(themes.colorThemeId, 'dark');
      expect(themes.saved, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Apply saves chosen theme and reopening Cancel preserves it', (
    tester,
  ) async {
    final themes = _Themes();
    await _open(tester, themes);
    await tester.tap(find.byKey(const ValueKey('theme-card-light')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply theme'));
    await tester.pumpAndSettle();
    expect(themes.saved, ['light']);
    await tester.tap(find.text('Open gallery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-card-dark')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(themes.colorThemeId, 'light');
    expect(themes.saved, ['light']);
  });

  testWidgets('custom import is selected for preview without saving', (
    tester,
  ) async {
    final themes = _Themes();
    await _open(
      tester,
      themes,
      importTheme: () async {
        themes.colorThemes.add(
          const IdeColorThemeEntry(
            id: 'custom',
            label: 'My palette',
            type: ColorScheme.dark,
          ),
        );
        return 'custom';
      },
    );
    await tester.tap(find.text('＋ Import Pebrel JSON'));
    await tester.pumpAndSettle();
    expect(themes.colorThemeId, 'custom');
    expect(themes.saved, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(themes.colorThemeId, 'dark');
  });

  testWidgets('narrow layout scrolls instead of overflowing', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _open(tester, _Themes());
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('typography toggle previews and Escape restores original', (
    tester,
  ) async {
    final themes = _Themes();
    await _open(tester, themes);
    await tester.tap(find.byKey(const ValueKey('application-font-maple')));
    await tester.pumpAndSettle();
    expect(CodeFont.mapleFont.value, isTrue);
    expect(find.text('Maple Mono (bundled)'), findsOneWidget);
    expect(find.text('Maple Mono · all themes'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(CodeFont.mapleFont.value, isFalse);
    expect(themes.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typography Apply survives reopening and Cancel', (tester) async {
    final themes = _Themes();
    await _open(tester, themes);
    await tester.tap(find.byKey(const ValueKey('application-font-maple')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply theme'));
    await tester.pumpAndSettle();
    expect(CodeFont.mapleFont.value, isTrue);
    await tester.tap(find.text('Open gallery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('application-font-existing')));
    await tester.pumpAndSettle();
    expect(CodeFont.mapleFont.value, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(CodeFont.mapleFont.value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('global Maple preview uses existing sizes on ordinary themes', (
    tester,
  ) async {
    final original = WorkbenchThemeService.instance;
    final service = WorkbenchThemeService();
    WorkbenchThemeService.instance = service;
    final originalSize = CodeFont.size.value;
    final originalTerminal = CodeFont.terminalSize.value;
    final originalZoom = CodeFont.uiScale.value;
    CodeFont.size.value = 20;
    CodeFont.terminalSize.value = 18;
    CodeFont.uiScale.value = 125;
    addTearDown(() {
      WorkbenchThemeService.instance = original;
      CodeFont.size.value = originalSize;
      CodeFont.terminalSize.value = originalTerminal;
      CodeFont.uiScale.value = originalZoom;
      service.dispose();
    });
    await tester.runAsync(service.initialize);
    await _open(tester, service);
    await tester.tap(find.byKey(const ValueKey('application-font-maple')));
    await tester.pumpAndSettle();
    final title = tester.element(find.text('Make it your space'));
    expect(
      DefaultTextStyle.of(title).style.fontFamily,
      'Maple Mono Normal NF CN',
    );
    expect(AppFonts.codeStyle(13).fontSize, 20);
    expect(CodeFont.terminalSize.value, 18);
    expect(CodeFont.uiScale.value, 125);
    expect(find.textContaining('all themes'), findsWidgets);
    await tester.runAsync(
      () => service.setColorTheme('Bao Light', preview: true),
    );
    await tester.pumpAndSettle();
    expect(CodeFont.effectiveFamilies.first, 'Maple Mono Normal NF CN');
    expect(AppFonts.codeStyle(13).fontSize, 20);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(CodeFont.mapleFont.value, isFalse);
  });
  testWidgets('Apply existing fonts writes explicit false over legacy choice', (
    tester,
  ) async {
    CodeFont.pebrelPreset.value = true;
    final settings = _RecordingSettings();
    addTearDown(settings.dispose);
    await _open(tester, _Themes(), settings: settings);
    await tester.tap(find.byKey(const ValueKey('application-font-existing')));
    await tester.pumpAndSettle();
    expect(settings.written, isEmpty);
    await tester.tap(find.text('Apply theme'));
    await tester.pumpAndSettle();
    expect(settings.written, {CodeFont.mapleFontSettingKey: false});
    expect(CodeFont.mapleFont.value, isFalse);
  });
}

class _RecordingSettings extends UserSettings {
  _RecordingSettings() : super('/unused/settings.json');
  final written = <String, Object?>{};

  @override
  Future<void> update(String key, Object? value) async {
    written[key] = value;
  }
}
