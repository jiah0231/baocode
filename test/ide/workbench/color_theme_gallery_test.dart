import 'package:flutter/material.dart' hide ColorScheme;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_color_theme_gallery.dart';
import 'package:baocode/ide/ide_color_theme_picker.dart';
import 'package:baocode/theme/code_font.dart';
import 'package:baocode/theme/workbench_theme.dart'
    show ColorScheme, WorkbenchThemeService;
import 'package:baocode/theme/pebrel_theme.dart';

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
  _Themes themes, {
  Future<String?> Function()? importTheme,
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
  setUp(() => CodeFont.pebrelPreset.value = false);
  tearDown(() => CodeFont.pebrelPreset.value = false);
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
    await tester.tap(find.byKey(const ValueKey('pebrel-typography-toggle')));
    await tester.pumpAndSettle();
    expect(CodeFont.pebrelPreset.value, isTrue);
    expect(find.text('Pebrel typography: On'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(CodeFont.pebrelPreset.value, isFalse);
    expect(themes.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typography Apply survives reopening and Cancel', (tester) async {
    final themes = _Themes();
    await _open(tester, themes);
    await tester.tap(find.byKey(const ValueKey('pebrel-typography-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply theme'));
    await tester.pumpAndSettle();
    expect(CodeFont.pebrelPreset.value, isTrue);
    await tester.tap(find.text('Open gallery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pebrel-typography-toggle')));
    await tester.pumpAndSettle();
    expect(CodeFont.pebrelPreset.value, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(CodeFont.pebrelPreset.value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery honors the UI font family fallback list', (
    tester,
  ) async {
    final original = WorkbenchThemeService.instance;
    final service = WorkbenchThemeService();
    WorkbenchThemeService.instance = service;
    addTearDown(() {
      WorkbenchThemeService.instance = original;
      service.dispose();
    });
    await tester.runAsync(() async {
      await service.initialize();
      final raw = service.pebrelTheme('Pebrel Nord')!.toJson();
      raw['typography'] = {
        'ui_font_family': 'Missing UI, Maple Mono Normal NF CN',
      };
      const id = 'Pebrel Custom 33333333333333333333333333333333';
      await service.setCustomPebrelThemes({
        id: PebrelThemeDefinition.fromJson(raw),
      });
      await service.setColorTheme(id, preview: true);
    });
    await _open(tester, _Themes());
    final title = tester.element(find.text('Make it your space'));
    final style = DefaultTextStyle.of(title).style;
    expect(style.fontFamily, 'Missing UI');
    expect(style.fontFamilyFallback, contains('Maple Mono Normal NF CN'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
