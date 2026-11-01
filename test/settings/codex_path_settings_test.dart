import 'package:baocode/kernel/codex/codex_path_setting.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/settings/pages/general_page.dart';
import 'package:baocode/settings/pages/settings_widgets.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends UserSettings {
  _Settings() : super('unused.json');
  final data = <String, Object?>{};
  @override
  Object? operator [](String key) => data[key];
  @override
  Future<void> update(String key, Object? value) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
    notifyListeners();
  }
}

void main() {
  testWidgets('Codex path is editable, clearable, and has a fresh status', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = _Settings();
    addTearDown(settings.dispose);
    var checks = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GeneralSettingsPage(
            settings: settings,
            codexStatus: () async {
              checks++;
              final path = settings[CodexPathSetting.settingKey] as String?;
              return path == null
                  ? const LocalCodexMissing()
                  : LocalCodexFound(path, 'codex-cli 1.2.3');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Codex'), findsOneWidget);
    expect(find.textContaining('Codex was not found'), findsOneWidget);
    final field = find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is SettingsTextField && widget.semanticLabel == 'Codex Path',
      ),
      matching: find.byType(TextField),
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, ' /opt/my-codex ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings[CodexPathSetting.settingKey], '/opt/my-codex');
    expect(
      find.text('In use: /opt/my-codex (codex-cli 1.2.3)'),
      findsOneWidget,
    );
    final before = checks;
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(checks, before + 1);
    await tester.enterText(field, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings[CodexPathSetting.settingKey], isNull);
    expect(find.textContaining('Codex was not found'), findsOneWidget);
  });

  testWidgets(
    'Codex status failures remain visible, without hiding the path field',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GeneralSettingsPage(
              codexStatus: () async =>
                  const LocalCodexFailed('The configured file is missing'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The configured file is missing'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SettingsTextField &&
              widget.semanticLabel == 'Codex Path',
        ),
        findsOneWidget,
      );
    },
  );
}
