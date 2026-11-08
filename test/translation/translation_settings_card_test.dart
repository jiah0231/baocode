import 'package:baocode/settings/pages/settings_widgets.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/translation/translation_host.dart';
import 'package:baocode/translation/translation_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Windows selection and copy switches disclose risks without saving defaults',
    (tester) async {
      final settings = _MemorySettings();
      addTearDown(settings.dispose);
      final host = TranslationHost(supported: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TranslationSettingsCard(settings: settings, host: host),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(settings.values, isEmpty);
      expect(
        tester
            .widgetList<SettingsSwitchRow>(find.byType(SettingsSwitchRow))
            .map((row) => row.value),
        [true, true],
      );
      expect(
        find.textContaining(
          'clipboard managers or cloud sync may see the text',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Only Translate sends it to the model'),
        findsOneWidget,
      );
      final copy = find.text('Automatically copy selected text');
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(settings.values, {TranslationHost.clipboardFallbackKey: false});
      final selection = find.text('Show a translation button after selection');
      await tester.ensureVisible(selection);
      await tester.tap(selection);
      await tester.pumpAndSettle();
      expect(settings.values, {
        TranslationHost.clipboardFallbackKey: false,
        TranslationHost.selectionActionKey: false,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed selection hook registration offers a visible fallback', (
    tester,
  ) async {
    final host = TranslationHost(supported: true)..selectionActionTaken = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(child: TranslationSettingsCard(host: host)),
      ),
    );
    expect(
      find.textContaining('The selection button could not be enabled'),
      findsOneWidget,
    );
  });

  testWidgets('selection options cannot write without editable settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: TranslationSettingsCard(
            host: TranslationHost(supported: true),
          ),
        ),
      ),
    );
    expect(
      tester
          .widgetList<SettingsSwitchRow>(find.byType(SettingsSwitchRow))
          .map((row) => row.enabled),
      [false, false],
    );
  });
}

class _MemorySettings extends UserSettings {
  _MemorySettings() : super('unused-translation-settings.json');
  @override
  final Map<String, Object?> values = {};
  @override
  Future<void> update(String key, Object? value) async {
    values[key] = value;
    notifyListeners();
  }
}
