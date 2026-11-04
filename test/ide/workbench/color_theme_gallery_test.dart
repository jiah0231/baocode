import 'package:flutter/material.dart' hide ColorScheme;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_color_theme_gallery.dart';
import 'package:baocode/ide/ide_color_theme_picker.dart';
import 'package:baocode/theme/workbench_theme.dart' show ColorScheme;

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
}
