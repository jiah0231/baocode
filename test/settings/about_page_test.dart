import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/ide/document/document_preview_notices.dart';
import 'package:baocode/settings/pages/about_page.dart';
import 'package:baocode/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: AboutSettingsPage()),
      ),
    );
    await tester.pump();
  }

  testWidgets('says what BaoCode is, which build, and where it is made', (
    tester,
  ) async {
    await show(tester, const Locale('zh'));
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('BaoCode'), findsOneWidget);
    expect(
      find.text(
        '版本 ${currentAppVersion.marketing}（${currentAppVersion.build}）',
      ),
      findsOneWidget,
    );
    expect(
      find.text('github.com/baocode-dev/baocode · 免费开源，GPL-3.0 许可证'),
      findsOneWidget,
    );
    expect(find.text('去 GitHub 点 Star'), findsOneWidget);
    expect(find.text('baocode.dev'), findsOneWidget);
    expect(find.text('更新日志'), findsOneWidget);
    expect(find.text('反馈问题'), findsOneWidget);
    expect(find.text('NoteBoard 内置预览器'), findsOneWidget);
    expect(find.text('预览器对应源码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('its links', () {
    expect(
      DocumentPreviewNotices.upstream.toString(),
      contains('/43be834d892541d3fda51cab6e5496371331e341/plugins'),
    );
    expect(DocumentPreviewNotices.source.host, 'github.com');
    expect(
      DocumentPreviewNotices.source.path,
      startsWith('/jiah0231/baocode/tree/'),
    );
    expect(
      AboutSettingsPage.issues,
      Uri.parse('https://github.com/baocode-dev/baocode/issues'),
    );
  });
}
